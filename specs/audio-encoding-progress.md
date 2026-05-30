# Phase Progress, Overall ETA, and Timing History V2 Plan

Status: implemented in this branch; retained as the design/spec record.

## Problem

`transcribe voice-memos` can sit silently for a long time after printing the
selected model:

```text
Auto-selected model: openai_whisper-large-v3_turbo
<long pause>
Transcription: encoding..., 8m 59s (~3m 15s left)
```

That silence is confusing because the machine is busy. In the reported case,
Activity Monitor / `top` showed active Neural Engine work, which points at the
WhisperKit audio encoder phase rather than idle time.

The current ETA system predicts the whole pipeline from prior total wall time and
only displays status for the currently visible transcription/diarization lines.
It does not keep separate predictors for the user-visible `encoding...` phase,
transcription decoding, or diarization. It also does not show a stable overall
countdown while individual phase lines change underneath it.

## Terminology

This plan keeps three similarly named phases separate:

- **Source audio load / conversion:** `AudioProcessor.loadAudioAsFloatArray`
  decodes the input file into 16 kHz mono `Float` samples. This is recorded
  today as `audio_load_ms`.
- **Whisper audio preprocessing:** WhisperKit pads/trims windows, computes
  log-mel features, and prepares model input. Upstream timings expose this as
  `audioProcessing` and `logmels`.
- **Whisper audio encoding:** WhisperKit runs `audioEncoder.encodeFeatures`.
  Upstream timings expose this as `encoding` and `totalEncodingRuns`. This is
  the phase currently shown to the user as `Transcription: encoding...`.

The plan below focuses on the third phase, while also preserving the existing
`audio_load_ms` history because source-file conversion can also be a visible
wait on large inputs.

## Goals

- Print an immediate progress marker before the first WhisperKit decoding
  callback, so a busy encoder does not look like a hang.
- Store separate historical timings for source load, Whisper preprocessing,
  Whisper encoding, Whisper decoding, and SpeakerKit diarization.
- Predict the current phase ETA from audio duration, model, and relevant backend
  history.
- Show an overall ETA/countdown line that remains visible while phase-specific
  lines update.
- Use the overall countdown as the fallback when phase-specific history is not
  available.
- Keep `--eta-hints off`, `TRANSCRIBE_ETA_HINTS=0`, and
  `TRANSCRIBE_TIMING_STATS=0` semantics unchanged.
- Keep old timing history rows readable.

## Non-goals

- Do not rewrite WhisperKit internals.
- Do not invent fake fractional progress inside a single encoder call.
- Do not make model download or first-time model specialization look like audio
  encoding. Those remain separate init costs.
- Do not replace diarization's existing `Progress.fractionCompleted` ETA.
- Do not sum transcription and diarization as if they were serial; they run in
  parallel in the diarization path.

## Current Hooks

The local pipeline already records coarse wall phases in
`PhaseTimings` / `RunTimingRecord`:

- `audio_load_ms`
- `whisper_init_ms`
- `speaker_init_ms`
- `parallel_ms`
- `transcribe_only_ms`
- `merge_ms`
- `write_outputs_ms`
- `total_ms`
- `decoding_windows`

WhisperKit also exposes finer transcription timings on
`TranscriptionResult.timings` and on progress callbacks:

- `audioProcessing`
- `logmels`
- `encoding`
- `decodingLoop`
- `totalAudioProcessingRuns`
- `totalLogmelRuns`
- `totalEncodingRuns`
- `totalDecodingWindows`

SpeakerKit exposes final Pyannote timing fields on
`DiarizationResult.timings` when the result is backed by
`PyannoteDiarizationTimings`:

- `segmenterTime`
- `embedderTime`
- `clusteringTime`
- `fullPipeline`
- chunk / embedding / speaker counters

Those fields are the source of truth for the phase history.

## Data Model

Extend the timing record with schema v2 fields:

| Field | Unit | Meaning |
|:------|:-----|:--------|
| `whisper_audio_processing_ms` | ms | WhisperKit sample window padding / preprocessing |
| `whisper_logmels_ms` | ms | WhisperKit log-mel feature generation |
| `whisper_encoding_ms` | ms | WhisperKit audio encoder model time |
| `whisper_decoding_loop_ms` | ms | WhisperKit decoder loop time |
| `whisper_total_audio_processing_runs` | count | Number of preprocessing windows |
| `whisper_total_logmel_runs` | count | Number of log-mel windows |
| `whisper_total_encoding_runs` | count | Number of encoder windows |
| `whisper_total_decoding_windows` | count | Number of decoded windows from WhisperKit timings |
| `whisper_first_progress_ms` | ms | Time from transcribe start until first progress callback, if measured |
| `speaker_diarization_ms` | ms | SpeakerKit diarization full pipeline time |
| `speaker_segmenter_ms` | ms | SpeakerKit segmenter model time |
| `speaker_embedder_ms` | ms | SpeakerKit embedder model time |
| `speaker_clustering_ms` | ms | Speaker clustering time |
| `speaker_total_chunks` | count | Segmenter chunk count |
| `speaker_total_embeddings` | count | Embedding count |

Implementation choice:

- Write new rows with `schema_version = 2`.
- Decode old v1 rows with default `0` for all new v2 fields.
- Provide a manual one-time JSONL migration script that rewrites old rows to
  schema v2 with zero-valued new fields; do not migrate automatically on normal
  CLI startup.
- Do not add these fields to processing history. They belong only in timing
  history.

## Migration Script

Add `scripts/migrate-timing-history-v2.swift`, runnable with:

```bash
swift scripts/migrate-timing-history-v2.swift
```

Script behavior:

- Resolve the default file the same way `StatePaths.timingHistoryURL()` does:
  `XDG_STATE_HOME/transcribe/timing_history.jsonl` when set, otherwise macOS
  Application Support.
- Support `--path <file>` and `--dry-run`.
- Read non-empty JSONL lines as JSON objects.
- Abort without rewriting if any non-empty line is not a JSON object, reporting
  the line number.
- Rewrite every row with `schema_version: 2`.
- Add all v2 timing fields with `0` when absent.
- Preserve existing fields and unknown fields.
- Write a timestamped backup next to the original, then atomically replace the
  original.
- Write the migrated file with `0600` permissions.

## History Predictors

Keep the existing total predictor:

```text
r_total = median((total_ms / 1000) / audio_duration_s)
```

Add phase predictors:

```text
r_audio_load = median((audio_load_ms / 1000) / audio_duration_s)
r_whisper_prep = median(((whisper_audio_processing_ms + whisper_logmels_ms) / 1000) / audio_duration_s)
r_encoding = median((whisper_encoding_ms / 1000) / audio_duration_s)
r_transcribe = median((whisper_decoding_loop_ms / 1000) / audio_duration_s)
r_diarize = median((speaker_diarization_ms / 1000) / audio_duration_s)
```

Filtering:

- Use only rows with positive `audio_duration_s`.
- Use only rows with positive phase timings for that predictor; migrated v1 rows
  with zero phase timings are ignored for phase predictors.
- Match at least `model`.
- Include the effective Whisper compute summary in the key if practical:
  `mel`, `encoder`, and `decoder`. The encoder predictor should at minimum key
  by `model` plus the resolved audio encoder compute unit, because ANE, GPU, and
  CPU-only behavior can differ sharply.
- `diarization_enabled` is useful for whole-pipeline ETA, but encoding itself is
  mostly independent of diarization. For `r_encoding`, prefer sharing rows across
  transcript-only and diarization runs once model and encoder compute match.
- For `r_diarize`, require `diarization_enabled == true`; match the SpeakerKit
  segmenter/embedder compute settings when they are recorded.

Robustness:

- Use median of recent rows, matching the existing timing store style.
- Ignore obvious first-run model download / specialization outliers for phase
  predictors. A simple first pass can skip rows where `whisper_init_ms` is above
  a high threshold or where no encoding timing exists.

## Overall ETA Model

Show a stable top line whose countdown is based on the estimated remaining work
for the whole current session. The top line should not simply mirror the active
phase line.

Serial parts:

```text
source_load_estimate = r_audio_load * audio_duration_s
transcription_path_estimate =
  (r_whisper_prep + r_encoding + r_transcribe) * audio_duration_s
diarization_path_estimate = r_diarize * audio_duration_s
output_estimate = median((merge_ms + write_outputs_ms) / 1000 / audio_duration_s) * audio_duration_s
```

Transcript-only total:

```text
estimated_total_remaining =
  remaining(source_load)
  + remaining(transcription_path)
  + remaining(output)
```

Diarization total:

```text
estimated_total_remaining =
  remaining(source_load)
  + max(remaining(transcription_path), remaining(diarization_path))
  + remaining(output)
```

During a live run:

- For phases not yet started, use the historical duration estimate.
- For the current serial phase, subtract elapsed time in that phase from its
  estimate.
- For transcription and diarization running in parallel, estimate each remaining
  side independently and use `max(...)`.
- When SpeakerKit reports a meaningful live fraction, prefer fraction-based
  diarization remaining over historical `r_diarize`.
- When a phase finishes, clamp its remaining time to zero.
- If there is not enough phase history, fall back to the existing `r_total`
  predictor for the top-line ETA.

## Progress Behavior

Introduce explicit progress phases:

- `checking audio...`
- `loading models...`
- `preparing audio...`
- `preprocessing audio...`
- `encoding audio...`
- `<N> windows`
- `diarizing...`
- `writing outputs...`
- `done`

`LiveProgressDisplay` redraws on a timer, not only when WhisperKit calls the
transcription progress callback. This is the key behavior change: the display
starts immediately after model selection, keeps elapsed time visible through
audio checking and model/audio setup, shows the decoded or estimated audio
duration as soon as it is known, shows the encoder phase before WhisperKit's
first progress callback, and keeps elapsed time moving while the encoder is
busy. The first redraw can contain only `Total` plus
`Input Check: checking audio`; additional phase rows appear as that work
starts. `Input Check` covers the cheap container validation before model
loading; `Audio` starts later and measures only the actual audio sample load.

TTY display redraws a fixed set of lines, with phase rows indented and labels
kept in a 16-character column:

- `▶ Total:          elapsed <elapsed>, ETA <remaining>, audio duration <duration>`
- `  ✓ Input Check:    elapsed <elapsed>`
- `  ✓ Model Loading:  <phase/status>`
- `  ✓ Audio:          elapsed <elapsed>`
- `  ▶ Encoding:       <phase/status>`
- `  ▶ Diarization:    <phase/status>` only when speaker labels are enabled
- `    Transcription:  <phase/status>`
- `  ▶ Output:         <phase/status>` once output writing is explicitly tracked

Rows are ordered by phase start order. When phases run in parallel, their lines
update independently and stay in their first-started order. When a phase is
running, its line uses `▶` and includes elapsed time plus an ETA. If a running
phase has no useful substatus yet, it shows only elapsed time and ETA rather
than filler text such as `starting`. When a phase has not started, its state icon
column is blank. When a phase is complete, its line uses `✓`, shows only the
final elapsed time, stops updating, and no longer counts toward the remaining
ETA. Phase rows are indented under `Total` so the overall countdown scans
separately from per-phase work. The top line uses the remaining critical path,
not a serial sum of parallel work. When the session finishes, the final TTY
snapshot remains visible instead of being cleared; the top line switches to `✓`
and shows total elapsed runtime plus audio duration. Durations omit zero-valued
higher units, so a four-second phase renders as `4s`, not `0m 4s`. Positive
sub-second durations render as `<1s`; `0s` is reserved for exactly zero.

Example:

```text
▶ Total:          elapsed 1m 12s, ETA ~3m 51s, audio duration 8m 59s
  ✓ Input Check:    elapsed <1s
  ✓ Model Loading:  elapsed 1s
  ✓ Audio:          elapsed <1s
  ▶ Encoding:       encoding audio, elapsed 1m 12s, ETA ~2m 5s
  ▶ Diarization:    segmenter 42%, elapsed 1m 12s, ETA ~3m 51s
    Transcription:  waiting
```

Final snapshot:

```text
✓ Total:          elapsed 4m 3s, audio duration 8m 59s
  ✓ Input Check:    elapsed <1s
  ✓ Model Loading:  elapsed 1s
  ✓ Audio:          elapsed <1s
  ✓ Encoding:       elapsed 44s
  ✓ Diarization:    elapsed 4m 1s
  ✓ Transcription:  12 windows, elapsed 3m 18s
```

Line-level ETAs mean time to finish that running phase. The top-line ETA means
time left in the current session.

Plain `--progress-log plain` should emit throttled snapshots with the same lines
without ANSI cursor control.

## Capturing Timings

Add a helper in `TranscriptionPipeline.swift`, for example:

```swift
func whisperPhaseTimings(from results: [TranscriptionResult]) -> WhisperPhaseTimings
```

The helper should sum `result.timings` fields across returned results, matching
WhisperKit's own merge behavior:

- `audioProcessing`
- `logmels`
- `encoding`
- `decodingLoop`
- run/window counters

Add a companion helper for `DiarizationResult.timings`:

```swift
func speakerPhaseTimings(from result: DiarizationResult) -> SpeakerPhaseTimings
```

Downcast to `PyannoteDiarizationTimings` when available and copy `fullPipeline`,
`segmenterTime`, `embedderTime`, `clusteringTime`, chunk count, and embedding
count. If the downcast fails, leave speaker phase fields at zero and keep using
the already-measured `parallel_ms` / total fallback.

Then copy Whisper and SpeakerKit values into `PhaseTimings`, and from there into
`RunTimingRecord`.

For live progress, track:

- transcribe call start
- first progress callback time
- last seen `progress.timings.totalEncodingRuns`
- last seen `progress.timings.totalDecodingWindows`
- last seen diarization `fractionCompleted`
- start / finish timestamps for source load, transcription path, diarization
  path, and output writing

The first progress callback may arrive only after the first encoded window has
already completed. That is fine: history gives the ETA before callbacks start,
and the callback gives the transition point into decoded-window progress.

## Code Touchpoints

- `Sources/transcribe/PhaseTimings.swift`
  - Add zero-default Whisper and SpeakerKit phase fields.
- `Sources/transcribe/RunTimingRecord.swift`
  - Add v2 JSON fields for Whisper and SpeakerKit phase timings and counters.
- `Sources/transcribe/TimingStore.swift`
  - Add median helpers for phase seconds per audio second and top-line ETA
    ingredients.
  - Allow old rows without phase fields.
- `Sources/transcribe/LiveProgress.swift`
  - Add progress phase states for encoding, transcription, diarization, and
    output.
  - Add timer-based redraws.
  - Add fixed-line TTY rendering with a `Total:` countdown line.
  - Add separate ETA ratios for total, audio-load, preprocessing, encoding,
    transcription decoding, diarization, merge, and output writing.
- `Sources/transcribe/TranscriptionPipeline.swift`
  - Extract final Whisper timings from `TranscriptionResult.timings`.
  - Extract final SpeakerKit timings from `DiarizationResult.timings`.
  - Capture first progress callback latency.
- `Sources/transcribe/PipelineRunner.swift`
  - Load total and phase history before work starts.
  - Pass historical phase ratios into `runSession`.
  - Keep the display start point close to `whisperKit.transcribe` so encoding
    progress appears before the first WhisperKit progress callback.
  - Future: mark output writing phase before `writeOutputs` if output ever
    becomes a visible wait.
- `Sources/transcribe/AudioLoader.swift`
  - Optionally add a cheap duration probe for single-file inputs so progress can
    show ETA before full PCM conversion.

## Duration Estimates

ETA needs audio duration before expensive work begins.

Use these sources, in order:

1. Voice Memos database duration (`ZDURATION` / `ZLOCALDURATION`), already loaded.
2. Directory resolver AVAsset duration, already probed during input resolution.
3. Cheap single-file duration probe via AudioToolbox or AVFoundation.
4. Actual decoded sample count once `PreparedAudio` exists.

For multi-clip sessions, sum known clip durations and add the existing
inter-clip padding duration.

If no duration estimate exists, still show the phase marker and elapsed time,
but omit the ETA suffix.

## Tests

Add focused tests:

- `TimingStoreTests`
  - Decodes old rows without new fields.
  - Computes median encoding seconds per audio second.
  - Computes overall ETA ingredients and uses `max(transcription, diarization)`
    for parallel work.
  - Ignores rows with missing or zero encoding duration.
- `LiveProgressTests`
  - Starting the display emits an immediate phase line without waiting for a
    progress callback.
  - Encoding phase uses encoding ETA when available.
  - Overall line remains present while input, transcription, and diarization
    lines change.
  - Diarization total ETA uses live fraction when available.
  - `finish()` stops timer redraws and remains idempotent.
- `TranscriptionPipelineTests`
  - Sums WhisperKit timing fields from synthetic `TranscriptionResult` values if
    those types are constructible in tests.
  - Extracts Pyannote diarization timing fields when available.
  - Otherwise isolates the summing helpers behind small local structs and tests
    those.
- `AudioLoaderTests`
  - Cheap duration probe returns a positive duration for fixture audio.
- `CLITests`
  - `--progress-log plain` emits a pre-callback phase line for a seeded timing
    history scenario without ANSI cursor codes.
- Script smoke tests
  - Dry-run reports counts without modifying the file.
  - Migration creates a backup and rewrites v1 rows to v2.
  - Invalid JSONL aborts cleanly and leaves the original untouched.

## Rollout Steps

1. Add schema-compatible timing fields and tests for reading old and new history.
2. Capture WhisperKit and SpeakerKit phase timings after transcription and
   diarization complete.
3. Add `TimingStore` phase predictors and total ETA ingredients.
4. Add timer-driven fixed-line progress rendering with a `Total:` line and
   aligned phase status lines.
5. Wire phase and overall ETAs into `PipelineRunner`.
6. Add the manual JSONL v2 migration script and smoke tests.
7. Run focused tests, then `swift test` and `git diff --check`.
8. Manually verify a `voice-memos` or large-file run with `--progress-log plain`
   so the pre-callback output is easy to inspect.

## Open Questions

- Should compute-unit values be added to timing records now, or should the first
  pass key encoding history only by model and accept some noise?
- Should failed runs append partial timing records with `error_stage`, especially
  when encoding starts but later decoding fails?
