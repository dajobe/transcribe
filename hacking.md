# transcribe internals

This document is for people changing `transcribe`. The README is the user guide;
this file explains how the executable is wired, where behavior lives, and which
tests/specs to update when a feature moves.

## Package Shape

The Swift package currently has one executable target:

- `Sources/transcribe/main.swift`: root command, version, default model, and
  top-level dispatch into `SourceCommandDispatcher`.
- `Sources/transcribe/CLICommands.swift`: root/global options, source-specific
  arguments, source help, and command dispatch.
- `Sources/transcribe/PipelineRunner.swift`: shared execution path after a
  source has been selected.
- `Sources/transcribe/InputResolver.swift`: file/directory discovery, metadata
  probing, sort order, filename time recovery, and directory session basenames.
- `Sources/transcribe/VoiceMemosImport.swift`: Voice Memos SQLite import,
  metadata extraction, path resolution, and Voice Memos basenames.
- `Sources/transcribe/SQLiteReader.swift`: small read-only SQLite wrapper
  (`ReadOnlyDatabase`, `Statement`) used by `VoiceMemosImport`. Built on `import
  SQLite3` from the macOS SDK; opens with `SQLITE_OPEN_READONLY`.
- `Sources/transcribe/SessionGrouper.swift`: pure gap-based grouping of ordered
  clips into sessions.
- `Sources/transcribe/TranscriptionPipeline.swift`: audio loading/preflight,
  model initialization, Whisper transcription, SpeakerKit diarization, and
  transcript assembly helpers.
- `Sources/transcribe/OutputWriter.swift`: output basenames, overwrite checks,
  renderers, and atomic writes.
- `Sources/transcribe/ProcessingStore.swift`: append-only idempotency ledger.
- `Sources/transcribe/HistoryCommand.swift`: `transcribe history` command and
  `HistoryFormatter` (relative-time and column rendering).
- `Sources/transcribe/TimingStore.swift`: append-only timing history used for
  ETA hints.
- `Sources/transcribe/ComputeOptions.swift`: compute-unit option parsing and
  preferred/fallback backend selection.
- `Sources/transcribe/Errors.swift`: user-facing errors and exit codes.

There is a planned future split into a library target described in
`specs/library-embedding.md`, but today tests and the executable compile against
the single target.

## CLI Flow

The root command owns all shared transcription options. Source-specific options
belong to the source argument types:

- `FileSourceArguments`: `<audio-file>`
- `DirSourceArguments`: `<directory>`, sort/filename recovery/basename options
- `VoiceMemosSourceArguments`: recordings directory and Voice Memos session gap

`Transcribe` captures the remaining command line with `.captureForPassthrough`
and hands it to `SourceCommandDispatcher`. This is intentional: Swift
ArgumentParser subcommands do not naturally pass root option values into
subcommand `run()` without duplicating option groups.

Dispatch rules:

- `file`: validate that the argument is a file and create a `.file` request.
- `dir`: validate that the argument is a directory and create a `.directory`
  request with `DirectoryInputOptions`.
- `voice-memos`: create a `.voiceMemos` request with `recordingsDir` and
  `sessionGap`.
- `history`: utility command (does not run the transcription pipeline). Reads
  the processing-history ledger and prints the most recent entries via
  `HistoryCommand.run(count:)`. Accepts `--count <n>` (default 10).
- Any other first token starting with `-` is reported as an unknown global
  option (ArgumentParser's `.captureForPassthrough` swallowed it). Otherwise it
  is treated as the root file/directory alias. Alias runs accept global options
  only; trailing source-specific arguments are rejected.

Source help is generated from the source `ParsableCommand` declarations. Avoid
large hand-written help strings; add help text to the declared arguments and
options instead.

## Planning Then Running

`PipelineRunner.run()` has two major phases.

1. Build a list of `PipelineSessionPlan` values from the selected source.
2. Run the common pipeline for each plan that is not skipped by processing
   history.

`PipelineSessionPlan` is the handoff between source-specific discovery and
shared execution. It carries:

- the ordered audio files in an `AudioSession`
- output basename
- source kind and stable source id
- display/output metadata such as Voice Memos title and recorded time

The shared pipeline then handles:

- validation of global option combinations
- source fingerprinting
- idempotency skip checks
- dry run output
- overwrite preflight
- cheap audio decode preflight before model loading
- model initialization
- transcription and diarization
- output rendering and atomic writes
- processing and timing ledger appends

This structure is meant to keep `file`, `dir`, and `voice-memos` behavior
consistent after source planning.

## Batch Sources And Session Gaps

Both `dir` and `voice-memos` are batch sources. They use gap-based session
grouping by default with `--session-gap 10`. `--session-gap 0` disables
splitting and treats the batch as one session.

Directory input goes through `InputResolver.resolve(...)`:

- filters top-level files by supported audio extension
- probes recorded time and duration
- applies the requested sort order
- optionally recovers recorded times from filename prefixes
- runs the recorded-date trust check
- groups clips with `SessionGrouper.groupIntoSessions(...)`
- derives output basenames

Voice Memos input goes through `VoiceMemosImport.loadRecordings(...)` and then
the same `SessionGrouper` logic. Voice Memos ordering comes from
`ZCLOUDRECORDING.ZDATE`, not exported M4A `creation_time`.

For concatenated sessions, `loadPreparedAudio(fromFiles:)` inserts 200 ms of
silence between clips to smooth Whisper VAD at clip boundaries.

## Voice Memos Import

The Voice Memos importer reads the local iCloud-synced store directly:

```text
~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/
```

It opens `CloudRecordings.db` read-only via the in-process `ReadOnlyDatabase`
wrapper in `SQLiteReader.swift` (built on the macOS SDK's `import SQLite3`,
`SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`) and queries `ZCLOUDRECORDING`.
Important mapping:

- identity: `ZUNIQUEID`, falling back to resolved audio path
- audio path: `ZPATH`, relative to the recordings directory when needed
- recorded time: `ZDATE`, converted from Apple reference date
- duration: `ZDURATION`, then `ZLOCALDURATION`, then later audio probing
- title: `ZCUSTOMLABEL`, then `ZENCRYPTEDTITLE`, then `New Recording`

If macOS denies the folder or database, surface a Full Disk Access hint. Missing
audio files are warnings and skipped rows, not fatal by themselves.

## Idempotency

Processing history is an append-only JSON Lines file named
`processing_history.jsonl`, located via `StatePaths.processingHistoryURL()` (see
"State Files" below for the resolved directory). Each record is one line of
canonical JSON; `ProcessingStore.append` writes under `flock(LOCK_EX)` on a
shared `O_APPEND` fd so concurrent `transcribe` processes serialize cleanly.

The ledger records completed source sessions and imported baselines. It stores:

- source kind and stable source id
- per-file SHA-256 fingerprint, byte size, and mtime for the source files
- settings signature (model, language, diarization on/off, speaker strategy,
  min/max speakers, formats, write-txt-to-stdout, transcribe version) for
  completed transcription runs; `null` for `--mark-imported` baselines
- output paths and `output_dir` / `basename`
- Voice Memos audit metadata when present (title, recorded-at, unique id, path)

Default skip behavior (in `PipelineRunner.shouldSkip` via `ProcessingStore`,
checked in this order):

1. **Imported-baseline match** (`shouldSkipImportedBaseline`): same `source_id`
   and same fingerprint, regardless of settings. Sticky across model/format
   changes by design.
2. **Strict completed match** (`shouldSkipCompleted`): same source kind,
   `source_id`, fingerprint, settings, **and** `output_paths`, with every listed
   output file still on disk.
3. **Content match** (`shouldSkipByContent`): the new fingerprint's SHA-256 set
   is a subset of some prior record's SHA-256 set, ignoring file paths and
   `source_kind`. This catches a moved file (`/a/x.m4a` → `/b/x.m4a`) and a
   single-file run that pulls one clip out of a prior `dir` / `voice-memos`
   session. Match conditions:
   - **completed prior**: settings must match AND prior `output_paths` must all
     still exist on disk
   - **baseline prior** (`--mark-imported`): match on content alone, settings
     ignored

`--redo` bypasses all three skip paths; `--stateless` bypasses both reads and
writes of the ledger.

`--mark-imported` is global. It builds the normal source plan for `file`, `dir`,
or `voice-memos`, fingerprints each planned session, and appends a baseline
record without transcribing or writing transcript outputs. The ledger
`source_kind` for the baseline depends on the original source:

- `voice-memos --mark-imported` writes `voice_memos_baseline`
- `file` and `dir` (and root path aliases) write `imported_baseline`

Pre-2.1.2 builds tagged every baseline as `imported_baseline` regardless of
source. `HistoryFormatter.displayKind` recovers the distinction for those old
records by matching the `voice_memos:` prefix on `source_id`, so old and new
ledgers render consistently in `transcribe history`.

Use `transcribe history` to inspect the most recent records (newest first,
relative timestamps within seven days, ISO 8601 beyond, original recording date
in its own column). The command does not mutate the ledger; treat it as a
read-only viewer over `processing_history.jsonl`.

## Outputs

`OutputWriter.swift` owns renderers and write behavior for `txt`, `json`, `srt`,
`vtt`, and `md`.

Important conventions:

- Overwrite protection runs early in `PipelineRunner` and again in
  `writeOutputs`; this is intentional. The first check fails before model work,
  and the second protects the actual write.
- Writes are atomic: content is written to a temp file in the output directory,
  then moved/replaced.
- JSON keeps `language` and `speakers_detected` keys even when nil for stable
  downstream shape.
- Directory sessions include `audio_files` metadata.
- Voice Memos output metadata includes source, recorded time, title, unique id
  when present, and source path when applicable.

## Models And Compute

`initializeWhisperKit` must configure `WhisperKitConfig.downloadBase`, not
`modelFolder`. `modelFolder` tells WhisperKit the models are already present and
breaks first-run downloads.

SpeakerKit uses `PyannoteConfig(downloadBase:)` and explicitly downloads/loads
models through `SpeakerKitModelManager`.

`RuntimeComputeOptions.resolve(...)` chooses preferred and fallback compute
backends. With default `auto`, the code favors the tuned backend mix for each
model component and falls back when a preferred GPU/Metal path fails.

## State Files

`StatePaths` follows XDG state conventions:

- timing history: `timing_history.jsonl`
- processing history: `processing_history.jsonl`

Both stores use append-only writes and file locking on Darwin. Timing records
feed the progress ETA median; processing records feed idempotency.

## Tests

Run everything with:

```bash
swift test
```

Main test groups:

- `CLITests`: command grammar, help, source validation, dry runs, invalid option
  placement, Voice Memos CLI fixtures
- `InputResolverTests`: directory sorting, trust check, filename recovery,
  session basenames
- `SessionGrouperTests`: pure gap grouping behavior
- `VoiceMemosImportTests`: SQLite schema compatibility, date conversion, title
  fallback, missing audio, basename collisions
- `ProcessingStoreTests`: fingerprints, completed-run skips, imported baseline
  skips
- `HistoryFormatterTests`: relative-time formatting, kind labels, label fallback
  order, column padding
- `OutputWriterTests`: renderers, metadata, overwrite checks, atomic writes
- `TimingStoreTests`: timing append/load and median calculations
- `TranscriptionPipelineTests`: cheap audio preflight failure path
- `ComputeOptionsTests` and `LiveProgressTests`: compute fallback and progress
  rendering behavior

When changing CLI grammar, also run the Folder Action smoke:

```bash
env TRANSCRIBE_BIN=/bin/echo \
  TRANSCRIBE_STABLE_SECS=1 \
  TRANSCRIBE_MAX_STABLE_WAIT=3 \
  TRANSCRIBE_OUTPUT_DIR=/tmp \
  TRANSCRIBE_FORMAT=md \
  TRANSCRIBE_EXTRA_ARGS="--transcript-only --language en" \
  bash scripts/folder-action-transcribe.sh /tmp/transcribe-folder-action-smoke.m4a
```

The command should print global options before `file`.

## Specs

Specs are still useful as design records:

- `specs/transcribe.md`: product contract and output shape
- `specs/directory-input.md`: directory sorting and session splitting
- `specs/filename-derived-metadata.md`: filename time recovery and session
  basename rules
- `specs/voice-memos-cli-cleanup.md`: 2.0 release-plan spec covering CLI, Voice
  Memos, idempotency, and automation changes
- `specs/folder-action-markdown.md`: Markdown output and Automator helper
- `specs/timing-history.md`: timing history schema and ETA behavior
- `specs/library-embedding.md`: future library split
- `specs/voice-memos-direct-sqlite.md`: in-process read-only SQLite for Voice
  Memos import (replaces the `/usr/bin/sqlite3` subprocess)

Update the relevant spec and README when behavior visible to users changes.

## Release Process

`Transcribe.version` lives in `Sources/transcribe/main.swift`. A version bump
must land with a matching annotated tag on the same commit.

Release checklist:

1. Update `Transcribe.version`.
2. Commit the release change.
3. Run `make tag` or `make release` to create `vX.Y.Z`.
4. Run `make verify-tag`.
5. Push the branch and tag only when ready.

Do not move on from a version-bump commit without the matching tag.
