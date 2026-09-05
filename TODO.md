# TODO

## Project review follow-up (2026-09-04)

Review baseline: `fdb7ed0`, with a clean worktree. The full Swift suite passed
251 tests using four workers, and `make shellcheck-scripts` passed. No
model-backed accuracy or performance benchmark was run. The timestamp and Voice
Memos naming bugs below were reproduced using isolated copies of the current
functions; other findings came from code inspection. Existing passing tests do
not cover all of these cases.

Suggested order: R1–R5 correctness fixes, R6–R8 recovery and history work, then
R9–R12 architecture, evaluation, and operations. R13–R15 can be handled
independently. These are pending tasks, not implemented behavior. Preserve
existing import-baseline semantics and unrelated user data during fixes.

### R1: Bound decoded memory across an entire session

- [ ] Fix the audio memory limit and multi-clip allocation behavior.

**Problem:** `AudioLoader.loadAudio` decodes the complete file through
`AudioProcessor.loadAudioAsFloatArray` before calling
`enforceUncompressedLimit`. `loadPreparedAudio(fromFiles:)` in
`Sources/transcribe/TranscriptionPipeline.swift` applies that limit separately
to each clip, retains all clip arrays, then allocates a combined array without
an aggregate check. Several individually acceptable clips can exceed the
configured limit, with both clip and combined buffers resident during assembly.

**Approach:** Define the limit as a decoded session budget, including inserted
silence. Enforce it before extending the combined buffer and release each clip
after appending it. Investigate bounded/chunked decoding so a single oversized
file can be rejected before its full allocation. Metadata estimates can provide
early rejection but must not replace checks against actual decoded samples. Use
overflow-safe byte/sample arithmetic for user-provided limits and totals.
Document that the audio budget does not cap model or total process memory.

**Acceptance:** Add tests for individually valid clips whose combined size
exceeds the budget, padding at the boundary, a single oversized file, and
`--max-audio-mb 0`. Measure peak memory on a representative multi-clip session.
An oversized session must fail with an input error before inference, and the
implementation must not retain all clip arrays alongside the combined buffer.

### R2: Prevent Voice Memos output-name collisions

- [ ] Make generated basenames unique across the complete output plan.

**Problem:** `VoiceMemosImport.uniqued` only counts original names; it does not
reserve generated suffixes. With the same date prefix, titles `Note`, `Note`,
and `Note - 2` produce `Note`, `Note - 2`, and `Note - 2`. A later session can
fail after expensive transcription or replace an earlier output when
`--overwrite` is enabled.

**Approach:** Share or adapt `InputResolver.uniquedSessionBasenames`, which
reserves original and generated names. Add a final collision check over all
planned output paths in `PipelineRunner` before model loading. Overwrite
permission must not authorize two sessions in one run to share an output path.

**Acceptance:** Cover existing suffixes, repeated titles, case-only differences,
and grouped Voice Memos. Verify deterministic names and distinct paths with both
overwrite settings. Preserve existing names when no collision exists.

### R3: Initialize unlabelled transcript blocks from their first segment

- [ ] Correct first-block timestamps in TXT and Markdown.

**Problem:** `renderTxt` and `renderMarkdown` in
`Sources/transcribe/OutputWriter.swift` initialize `currentSpeaker` to `nil` and
`blockStart` to zero. A first segment whose speaker is also `nil` follows the
append branch without assigning its start time. A segment starting at 12 seconds
and ending at 15 seconds renders as `[00:00:00 - 00:00:15]` in TXT; Markdown
uses the same faulty block initialization.

**Approach:** Start a new block when the block is empty as well as when the
speaker changes. Consider sharing the block-grouping logic between renderers so
timestamp and whitespace behavior cannot diverge.

**Acceptance:** Test leading silence, consecutive unlabelled segments,
transitions between labelled and unlabelled segments, and empty/whitespace-only
text. Both formats must retain the first actual segment start and final end.

### R4: Replace user configuration atomically

- [ ] Preserve the previous config on replacement failure.

**Problem:** `UserConfigFile.save` removes the existing config before moving the
temporary file to its destination. An interruption or failed move leaves the
user without the previous configuration. Permissions are applied only after
publication, and failure can leave a temporary file behind.

**Approach:** Write a same-directory temporary file with owner-only permissions,
then atomically replace the destination without first unlinking it. Clean up
temporary files on error. Decide and document concurrent-edit behavior rather
than assuming atomic replacement alone prevents lost updates.

**Acceptance:** Exercise first save, replacement, and injected write/replace
failures. Failed replacement must preserve the previous bytes; successful saves
must have mode `0600`. Verify temporary-file cleanup and that readers cannot
observe an intentionally missing destination between saves.

### R5: Preserve session order and repeated clips in deduplication

- [ ] Separate content import matching from exact session reuse.

**Problem:** `ProcessingStore.contentDecision` converts input hashes to sets and
accepts subset matches. This makes `[A, B]`, `[B, A]`, and `[A, A, B]`
indistinguishable even though their transcript timelines differ. The exact
source check can decide to process a changed session, then the content fallback
can skip it using the older transcript.

**Approach:** Define separate identities for imported recordings and completed
ordered sessions. Preserve hash order and multiplicity for session reuse. Retain
deliberate path-independent import matching and review the existing
single-file-from-session subset behavior explicitly before changing it. Include
timeline-affecting settings in the session identity; plan compatibility for
existing JSONL records without rewriting or discarding history implicitly.

**Acceptance:** Cover reordered clips, repeated clips, moved unchanged files,
single-file extraction from a previous session, missing outputs, and imported
baselines. Different timelines must not be skipped merely because their hash
sets match. Update the documented skip contract and history reasons.

### R6: Persist a canonical transcript and export without inference

- [ ] Separate inference results from requested presentation formats.

**Problem:** Formats are part of `ProcessingSettingsSignature`. Adding Markdown
or changing the format list can rerun inference even when the recognized speech
and speaker information have not changed. An output failure also lacks a durable
inference result from which to retry rendering.

**Approach:** Design a versioned canonical transcript artifact containing
segments, available words, speaker labels, source/timeline metadata, warnings,
and effective model/settings provenance. Split inference compatibility from
export compatibility and add an export command. Decide retention, location,
privacy permissions, and how existing JSON output relates to the internal
artifact. Preserve `--stateless` expectations explicitly.

**Acceptance:** Generate another format from a saved transcript with no model
load or download. Test schema validation, unsupported versions, missing
artifacts, and output-only retries. Preserve metadata and timing across exports.
Use this artifact as a recovery boundary for R7.

### R7: Define batch failure and recovery semantics

- [ ] Make interrupted or partially failed sessions recoverable.

**Problem:** `PipelineRunner.run` preflights every input before processing and
propagates individual session failures out of the batch. `writeOutputs`
publishes formats one at a time; the processing record is appended afterward. A
later write failure can leave partial exports, and a ledger failure can leave
complete exports without completion history. The next invocation can then fail
on overwrite protection rather than resume.

**Approach:** Introduce explicit session states and a recoverable completion
manifest coordinated with R6. Define what is committed when only some exports
exist, and how interrupted work is recognized. Add an opt-in continue-on-error
mode that isolates input/session failures while treating shared model failures
appropriately. Preserve fail-fast defaults unless deliberately changed.

**Acceptance:** Inject failure during decoding, inference, the second export,
and history append; test interruption between output publication and completion.
Recovery must avoid unnecessary inference and never overwrite unrelated files.
With continue-on-error, valid later sessions run and the final summary
identifies failures with an appropriate nonzero exit status. Previously
completed sessions remain reusable.

### R8: Index history once per run and control ledger growth

- [ ] Eliminate repeated complete history reads during planning.

**Problem:** `importedBaselineDecision`, `completionDecision`, and
`contentDecision` each call `loadRecords`. Planning N sessions can parse the
entire ledger up to three times per session. Duplicate checks also append skip
records, growing the input to future scans. `TimingStore.loadRecent` reads and
decodes the complete timing file before keeping its recent suffix.

**Approach:** Load a processing snapshot once, index it by source and content,
and pass it through planning. Distinguish completion state from skip audit
events. Add a retention/compaction design that preserves imported baselines and
usable completions; use measurements to decide whether SQLite is warranted.
Bound timing-history reads or retained working data. Coordinate concurrency
semantics with R12 rather than treating a snapshot as a lock.

**Acceptance:** Benchmark increasing session and ledger sizes. Verify one
snapshot load per planning run, equivalent decisions on existing fixtures, and
safe handling of malformed/truncated rows. Compaction must preserve skip
decisions and recover safely if interrupted; do not delete user history by
default.

### R9: Consolidate inference and introduce testable dependencies

- [ ] Unify the old and current transcription paths before adding backends.

**Problem:** `TranscriptionPipeline.swift` contains older
`runTranscriptionOnly`/`runTranscriptionWithDiarization` overloads alongside
`runSession`, including duplicated diarization orchestration. The CLI uses
`runSession`. `PipelineRunner` also combines planning, history, model setup,
execution, event rendering, and output publication. Concrete model dependencies
make orchestration failures difficult to test without real inference.

**Approach:** Inventory callers, consolidate behavior behind one session
implementation, and keep compatibility wrappers only where required. Introduce
injectable audio, model/inference, output, and history boundaries. Separate
model lifecycle, session execution, and transcript assembly. Use
`specs/library-embedding.md` as design context, but do not make a public library
API a prerequisite for these internal improvements. Keep process exit handling
at the CLI boundary.

**Acceptance:** Prove one model load per batch and test transcription-only,
short-audio fallback, empty diarization, merge behavior, inference failure, and
cancellation through injected dependencies. Preserve CLI behavior and effective
compute settings. Remove duplicate implementation only after caller checks.

### R10: Evaluate transcription and diarization quality

- [ ] Add a small reproducible model-backed evaluation corpus and runner.

**Gap:** Current tests strongly cover surrounding workflows, but
`TranscriptionPipelineTests` mostly tests cache detection, timing aggregation,
and preflight. Audio smoke scripts primarily check output existence and events;
they do not establish recognized-text or speaker-label accuracy.

**Approach:** Use licensed or purpose-recorded reference audio with transcripts
and speaker/timing annotations. Cover silence, short clips, overlapping
speakers, multiple speakers, long recordings, and concatenated clip boundaries.
Measure word error, speaker assignment, timestamp validity, runtime, and peak
memory. Record model identity, dependency versions, compute settings, and
hardware alongside results. Keep expensive evaluation separate from fast tests.

**Acceptance:** Define documented baselines and tolerances rather than exact
output equality for variable inference. Include a silence/hallucination check
and timestamp ordering/bounds checks. A model/dependency change must produce a
comparable report; fixtures must have documented provenance and no private
recordings. Make first-run download cost distinct from warmed inference cost.

### R11: Diagnose first-run and unattended execution failures

- [ ] Add a diagnostic command and finish model download visibility.

**Gap:** Cache misses are currently described through verbose logging inside
model initialization. Normal users need to distinguish downloading from loading
or a stalled run. Unattended jobs also need actionable environment checks.

**Approach:** Extend the existing model-download task below, verifying its older
API research against the checked-out dependency before implementation. Add a
read-only diagnostic command reporting resolved config/model paths, required
cache contents, requested compute settings, destination accessibility, and Voice
Memos access/schema problems. Clearly distinguish requested compute from the
effective backend selected only after loading. Downloads or model loading should
require an explicit diagnostic option rather than happen unexpectedly.

**Acceptance:** Test absent/partial caches, unavailable destinations, missing
Voice Memos databases, and permission errors. Download/load events must work in
TTY and plain modes without corrupting output or violating quiet settings. Do
not present file-count progress as exact downloaded bytes. Explain that audio
inference is on-device while model acquisition can use the network.

### R12: Coordinate overlapping processes

- [ ] Add native locking around conflicting transcription work.

**Problem:** `LockedAppendWriter` protects ledger appends, not the
check/process/write sequence. Two invocations can both decide work is new,
perform duplicate inference, and race on outputs. The Folder Action wrapper's
optional external `flock` command does not cover every CLI invocation.

**Approach:** Define an appropriate native lock scope for conflicting sessions
and output paths. Acquire it before the final skip/overwrite decision and
recheck state after acquiring it. Avoid unnecessarily serializing unrelated
work. Preserve both early and write-time overwrite checks; those are
intentional. Review publication so a no-overwrite run cannot replace a file
created by a competing writer after its check.

**Acceptance:** Run two real processes against the same session/destination.
Only one should infer/publish; the other should wait then reuse, or return a
clear busy result. Test process termination, lock release, path aliases, and
unrelated destinations. No external `flock` executable should be required.

### R13: Add a unified quality gate and macOS CI

- [ ] Make routine validation reproducible locally and in CI.

**Gap:** The repository has no checked-in CI workflow or unified quality target.
The Makefile exposes Swift tests and ShellCheck as separate commands.

**Approach:** Add a local check target and macOS CI running the Swift suite and
`make shellcheck-scripts`. Use four test workers and retain a log on failure.
Decide on Swift formatting/lint conventions before adding tools or generating
large formatting-only diffs. Document release-build and annotated-tag checks
separately from ordinary branch validation. Schedule or explicitly trigger R10
evaluation outside the fast gate.

**Acceptance:** The documented local command and CI perform the same fast
checks, fail on test/lint errors, and require neither personal Voice Memos
access nor model downloads. Document supported build tooling and how to run
expensive checks. Keep the existing version-bump/tag rules intact.

### R14: Reconcile privacy, security, and workflow documentation

- [ ] Audit documentation against the implemented boundaries and follow-up
  fixes.

**Gap:** The historical security notes previously claimed no databases and no
network access. Current code reads Voice Memos SQLite and downloads models.
Per-file atomic publication does not mean the complete output/history operation
is transactional, and the decoded audio check does not currently bound peak
session memory. Those claims are clarified below; the wider documentation still
needs a consistency pass as implementation changes land.

**Approach:** Review README, hacking notes, CLI help, TODO, and affected specs.
Explain local audio inference versus network model acquisition, read-only Voice
Memos access, persistent transcript/history data, current memory-limit scope,
skip identity, and failure/retry behavior. Label historical reviews and proposed
features as such. Reconcile each R1–R13 change with its user-facing contract.

**Acceptance:** All documented behavior must map to current code or an
explicitly pending task. Avoid claims of offline operation beyond what
cached-model tests prove. Run `format-markdown` on every edited Markdown file.

### R15: Consolidate format metadata and strengthen export integration tests

- [ ] Complete the smaller format-maintenance suggestions from the initial
  review.

**Gap:** Supported formats are repeated in `OutputFormats.swift`, extension
maps, CLI help, and validation errors. TSV tests specify expected output locally
but do not independently establish the upstream compatibility claim.

**Approach:** Define one ordered format registry and derive supported values,
`all` expansion, extensions, and help text from it. Add a fixture generated by a
documented, pinned WhisperX version; record intentional differences such as
newline sanitization. Add CLI coverage for TSV selection, `--format all`, and an
existing `.tsv` destination, without requiring live model downloads.

**Acceptance:** Preserve current format ordering and parsing behavior. Every
registered format must participate in output planning and overwrite protection.
Compatibility tests must compare against independent fixture bytes, and any
intentional divergence must be documented rather than described as
byte-identical.

## Model download progress

Report to the user before starting a large model download. Ideally show download
progress (bytes/total, speed, ETA). At minimum, print a message like
"Downloading model openai_whisper-large-v3-v20240930 (~3 GB)..." before the
download begins.

**Research (feasibility):**

- **Minimum (message before download):** Feasible. WhisperKit's download runs
  inside `WhisperKit(config)` → `setupModels()` → `Self.download(...)` and that
  call does not pass a `progressCallback`, so we can't hook in without changing
  flow. Approach: when cache is missing/empty, **pre-download** by calling
  `WhisperKit.download(variant:model, downloadBase:..., progressCallback: ...)`
  ourselves, then create WhisperKit with `modelFolder` set to the returned URL
  and `download: false`. We control the flow and can print our message before
  the call. Use a small hardcoded model-name → approximate-size table (e.g.
  large-v3 → ~3 GB) for the message.

- **Progress / speed / ETA:** Same pre-download flow. The callback receives
  Foundation `Progress`: `totalUnitCount` = number of files (not bytes),
  `completedUnitCount` advances per file, `fractionCompleted` is valid. Hub sets
  `progress.userInfo[.throughputKey]` to bytes/sec. So we can show file N/M,
  percentage, and speed (e.g. 2.1 MB/s). Total bytes are not reported by the Hub
  API; we can derive an approximate ETA from fraction + speed + our size table.

- **SpeakerKit:** `SpeakerKitModelManager.downloadModels(progressCallback:)`
  already accepts a callback. We currently use `SpeakerKit(config)` which
  doesn't expose it. To show SpeakerKit download progress, use the manager
  directly: create manager, call `downloadModels(progressCallback:)`, then
  `SpeakerKit(models: manager.models!)`.

## Security review (2026-03-22)

Full review of all 31 Swift sources under `Sources/transcribe/`, 14 Swift test
modules under `Tests/transcribeTests/`, configuration, and git history. No
critical or high-severity issues were reported in that historical review. The
current CLI has no network listeners or web interface, but it reads the local
Voice Memos SQLite database and can access the network to acquire models. Audio
inference runs on-device. The 2026-09-04 follow-up above is not a new exhaustive
security audit or a verification of the earlier git-history findings.

### [FIXED] Path traversal via --output-prefix (Low)

`OutputWriter.swift` uses the `--output-prefix` value directly as a filename
component without sanitizing directory separators. A value like `../../etc/foo`
would write files outside the intended output directory. Low impact since the
user controls their own invocation, but matters if the tool is ever called with
untrusted input.

**Fix:** Validate that `outputPrefix` contains no `/` or `..` components. (Fixed
2026-03-22)

### [FIXED] Predictable temp file name in writeAtomically (Low)

`OutputWriter.swift:42` constructs the temp file name using the PID, which is
predictable. On a shared system another process could pre-create a symlink at
that path to redirect the write.

**Fix:** Use a UUID or `mkstemp`-equivalent for temp file names. (Fixed
2026-03-22)

### [FIXED] Timing history file permissions (Informational)

`TimingStore.swift` and `ProcessingStore.swift` now create and tighten history
files to mode `0600` (owner-only) via `LockedAppendWriter`.

### [PARTIAL] Input size limit (Informational)

`AudioLoader.swift` warns before decoding files larger than 500 MB on disk and
checks decoded per-file size against `--max-audio-mb` (default 2048; `0`
disables). This check happens after full decoding and does not cap a
concatenated session or peak process memory. See R1 for the remaining work.

### Positive findings

- Per-file temporary-write-then-rename avoids publishing partially written
  transcript files; multiple exports plus history are not one transaction (R7)
- Overwrite protection by default (requires `--overwrite`)
- POSIX file locking (`flock`) for concurrent timing history writes
- No shell invocations from Swift (no command injection surface)
- Audio inference is local/on-device; model acquisition can require network
  access
- Input validation on CLI arguments (formats, speaker counts, combinations)
- No secrets in code or git history
- Dependencies pinned in `Package.resolved`

## Research

Voicebox "The open-source AI voice studio. Clone, dictate, create."

<https://github.com/jamiepine/voicebox>

### Parakeet v3

Parakeet MLX "An implementation of the Nvidia's Parakeet models for Apple
Silicon using MLX."

<https://github.com/senstella/parakeet-mlx>

Parakeet.cpp "Ultra fast and portable Parakeet implementation for on-device
inference in C++ using Axiom with MPS+Unified Memory"

<https://github.com/Frikallo/parakeet.cpp>

### Qwen3-ASR

No pointer yet
