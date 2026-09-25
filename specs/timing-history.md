# Timing history, storage, and better ETA

This document is the **design spec and notes** for timing history and ETA. The
**“Current behavior (baseline)”** section describes the pre-feature state (for
context). **“Implementation (as shipped)”** summarizes what landed in the tree
without replacing the spec text below.

## Current behavior (baseline)

- [`LiveProgress.swift`](../Sources/transcribe/LiveProgress.swift): Diarization
  line uses `Progress.fractionCompleted` with `formatETA` (elapsed / fraction).
  Transcription line only shows decoding **window count** and elapsed—**no
  ETA**, because there is no fraction wired from WhisperKit progress today.
- [`main.swift`](../Sources/transcribe/main.swift) `runPipeline()`: Single
  wall-clock total at the end (`Done. Total: …`). No per-phase timers.
- [`TranscriptionPipeline.swift`](../Sources/transcribe/TranscriptionPipeline.swift):
  Phases are implicit: `loadPreparedAudio`, `initializeWhisperKit`, optional
  `initializeSpeakerKit`, concurrent `transcribe` + `diarize`, merge, then
  `writeOutputs` in `main`.

## Implementation (as shipped)

- **Modules:** [`StatePaths.swift`](../Sources/transcribe/StatePaths.swift)
  (state dir + `timing_history.jsonl` URL),
  [`RunTimingRecord.swift`](../Sources/transcribe/RunTimingRecord.swift) +
  [`PhaseTimings.swift`](../Sources/transcribe/PhaseTimings.swift),
  [`TimingStore.swift`](../Sources/transcribe/TimingStore.swift) (append, load
  recent, median), [`WallClock.swift`](../Sources/transcribe/WallClock.swift)
  (timing helpers).
- **Pipeline:**
  [`TranscriptionPipeline.swift`](../Sources/transcribe/TranscriptionPipeline.swift)
  returns `(TranscriptionOutput, PhaseTimings)` and measures phases with wall
  ms; [`main.swift`](../Sources/transcribe/main.swift) measures
  `write_outputs_ms`, builds `RunTimingRecord`, appends after success.
- **TTY progress:**
  [`LiveProgress.swift`](../Sources/transcribe/LiveProgress.swift) takes
  `pipelineStartDate` (aligned with `runPipeline` start),
  `audioDurationSeconds`, and `HistoricalTimingRatios`; every running phase line
  and the total line show an `ETA`. Estimation lives in
  [`PhaseETA.swift`](../Sources/transcribe/PhaseETA.swift); see “ETA estimator
  (as shipped)” below.
- **History read:** Up to **50** most recent matching rows (`model` +
  `diarization_enabled`) for whole-run and processing-block ratios, and up to 50
  rows matching `model` only for the other phase predictors. Ratios are medians
  of `*_ms / 1000 / audio_duration_s` → **wall seconds per second of audio**
  (stored times are **milliseconds**).
- **Opt-out:** `--eta-hints off` or `TRANSCRIBE_ETA_HINTS=0` disables load,
  ETA-from-history, and append. Append failures are non-fatal (`try?`).
- **User docs:** [README.md](../README.md) “Timing statistics” links here.
- **Tests:**
  [TimingStoreTests.swift](../Tests/transcribeTests/TimingStoreTests.swift)
  (medians, XDG path, append/filter),
  [PhaseETATests.swift](../Tests/transcribeTests/PhaseETATests.swift) (estimator
  arithmetic), and live progress tests with an injected clock.

### ETA estimator (as shipped)

**Predictors from history** (`HistoricalTimingRatios`):

| Predictor                          | Source fields                            | Kind             |
|:-----------------------------------|:-----------------------------------------|:-----------------|
| `processingSecondsPerAudioSecond`  | `parallel_ms`, else `transcribe_only_ms` | ratio            |
| `diarizationSecondsPerAudioSecond` | `speaker_diarization_ms`                 | ratio            |
| `audioLoadSecondsPerAudioSecond`   | `audio_load_ms`                          | ratio            |
| `outputSecondsPerAudioSecond`      | `merge_ms + write_outputs_ms`            | ratio            |
| `firstProgressSeconds`             | `whisper_first_progress_ms`              | absolute seconds |
| `modelLoadSeconds`                 | `whisper_init_ms + speaker_init_ms`      | absolute seconds |
| `totalSecondsPerAudioSecond`       | `total_ms`                               | ratio (fallback) |

WhisperKit's `encoding` and `decodingLoop` timings are **not** predictors. With
`chunkingStrategy: .vad` WhisperKit decodes chunks on concurrent workers and
sums those timings across workers, so they run about 10x the wall time of the
block and produced ETAs an order of magnitude too long.

**Live signal.** WhisperKit's `Progress` counts one unit per VAD chunk and knows
the total as soon as chunking finishes. The display polls it on every progress
callback and redraw tick, renders `completed/total windows`, and records a pace
sample each time the count advances. WhisperKit decodes chunks in batches of
`concurrentWorkerCount` (16) that finish together, so only counts on a batch
boundary (or completion) are treated as throughput samples; a lone chunk
finishing mid-batch is ignored when history exists and used only as a
provisional pace on a cold start.

**Audio length before decoding.** The input check reads
`kAudioFilePropertyEstimatedDuration` from each container and seeds the shared
display with the session's total, so the total ETA includes the audio-scaled
phases during model loading. The decoded length replaces it on audio load.

**Per-phase remaining time** (`PhaseETA.remaining`):

- `history_total = ratio × audio_duration_s` (or the absolute median).
- `live_total = elapsed_at_sample / fraction_at_sample` for the most recent
  trusted sample. Sampling only at advances (and batch boundaries) makes the ETA
  count down smoothly between chunk completions instead of climbing and dropping
  with WhisperKit's batched completions.
- `total = (1 − w) × history_total + w × live_total`, with `w = min(1, fraction
  / 0.2)`, so live pace fully replaces history once 20% of the chunks are done.
- `remaining = total − elapsed`. When that reaches zero but the phase is still
  running, the estimate falls back to `elapsed / fraction − elapsed` so it keeps
  moving rather than sticking at “now”.

The transcription line measures elapsed from the start of the transcribe block
(the same interval `parallel_ms` records), so the encoding warm-up is not
double-counted. The diarization line uses the same estimator with SpeakerKit's
`fractionCompleted`.

**Total line.** Sum of the sequential phases still ahead: model load and audio
load (only on the shared display that starts before them), then
`max(transcription, diarization)` because those run concurrently, then output.
With no phase predictor at all it falls back to `totalSecondsPerAudioSecond`.

### Units (implementation detail)

| Quantity           | Unit                                                                     |
|:-------------------|:-------------------------------------------------------------------------|
| `*_ms` fields      | Wall-clock **milliseconds**                                              |
| `audio_duration_s` | **Seconds** of decoded audio                                             |
| Median ratio `r`   | **Seconds wall / second audio** = `(total_ms / 1000) / audio_duration_s` |

## Prior art

**WhisperKit (argmaxinc):** Public discussion and fixes center on **`Progress` /
`fractionCompleted`**, not on persisting past runs. Typical ETA is linear
extrapolation from fraction (same idea as this app’s diarization line).

- [Issue #202 – Progress bar for Swift
  CLI?](https://github.com/argmaxinc/argmax-oss-swift/issues/202) — Feature
  request; direction is to drive UI from WhisperKit’s **progress** object.
- [PR #179 – Fix progress when using VAD
  chunking](https://github.com/argmaxinc/argmax-oss-swift/pull/179) — Makes
  `fractionCompleted` **monotonic** across VAD chunks via weighted child
  progress (important for any fraction-based ETA).
- [PR #335 – WhisperKit CLI verbose / progress-style
  logging](https://github.com/argmaxinc/argmax-oss-swift/pull/335) — Upstream
  CLI improvements around progress and logging (still **live** signals, not a
  history file).

No common, documented pattern was found for **device-specific or history-based**
ETA (JSON/SQLite of prior timings) in WhisperKit; this plan’s **persistent
stats** complement upstream fraction-based progress rather than duplicate it.

**Broader Whisper:** [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and
[OpenAI Whisper](https://github.com/openai/whisper) expose **progress
callbacks**; ETA remains application-defined. **Hybrid approach here:** use
WhisperKit’s fraction/timings where available, and use **rolling history** for
cold start, parallel phases, and when fraction is missing or noisy.

**File bytes vs inference progress:** In this codebase, audio is loaded entirely
into memory ([`AudioLoader.swift`](../Sources/transcribe/AudioLoader.swift) →
`AudioProcessor.loadAudioAsFloatArray`) **before** `whisperKit.transcribe` runs;
transcription consumes **PCM samples**, not a streaming read of the source file.
WhisperKit does not expose “bytes read so far” as a proxy for how far through
the job you are. Compressed **file size** can correlate weakly with workload
when stored for **offline** regression (e.g. alongside duration), but it is
**not** a live progress meter during inference—use WhisperKit’s progress
callbacks and/or **audio duration** + historical wall-time ratios for ETA.

## What to record (each successful run)

| Field                                           | Purpose                                                                                                                                                                                           |
|:------------------------------------------------|:--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `ended_at` (ISO8601)                            | Ordering and decay of old runs                                                                                                                                                                    |
| `transcribe_version`                            | Detect schema / model changes across upgrades                                                                                                                                                     |
| `model`                                         | Separate regression per model                                                                                                                                                                     |
| `diarization_enabled`                           | Different phase mix                                                                                                                                                                               |
| `file_bytes`                                    | From `FileManager.attributesOfItem` on the input path                                                                                                                                             |
| `audio_duration_s`                              | Already computed in `PreparedAudio`                                                                                                                                                               |
| `segment_count`, `speakers_detected` (optional) | Correlates cost with output complexity. `segment_count` is **post-merge** transcript segments (same as written outputs), not the WhisperKit raw segment count shown in verbose logs before merge. |
| Phase durations (wall ms)                       | See breakdown below                                                                                                                                                                               |

**Phase breakdown (wall-clock, using `Date` or `ContinuousClock`):**

- `audio_load_ms` — inside `loadPreparedAudio` (or wrap `AudioLoader.loadAudio`)
- `whisper_init_ms` — `initializeWhisperKit` (includes first-time download;
  worth **flagging** in the record so averages can exclude outliers or use a
  separate bucket)
- `speaker_init_ms` — `initializeSpeakerKit` when diarization runs (0 or omit
  when `--transcript-only` / short-audio fallback)
- `parallel_ms` — for diarization path, time for the `async let` block where
  transcribe and diarize run together (dominant cost)
- `transcribe_only_ms` — for `--transcript-only` path, time inside
  `whisperKit.transcribe` only (after init)
- `merge_ms` — speaker merge + building segments (small but measurable)
- `write_outputs_ms` — `writeOutputs` in `main`
- `total_ms` — `runPipeline` start to end (sanity check). *Shipped:* interval
  ends after output writes complete (same instant used for `ended_at` / ratio).

Optional extras if cheap to capture: **decoding window count** (last value from
`TranscriptionProgress` in the live display path, or sum from results) for
correlation with work units.

**Privacy:** Persist **basename** of the input file (or a hash), not the full
path, unless you add an explicit opt-in later.

## Storage location (XDG + sensible macOS default)

- **Directory resolution (new small helper, e.g. `StatePaths.swift`):**
  - If `XDG_STATE_HOME` is set: `$XDG_STATE_HOME/transcribe/`
  - Else on **macOS**: follow Apple convention: `FileManager.default.urls(for:
    .applicationSupportDirectory, in: .userDomainMask)` + `transcribe/`
    (documented as primary default for this CLI on Darwin).
  - Else (non-macOS, if ever ported): `$HOME/.local/state/transcribe/` per [XDG
    Base
    Directory](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)
    state dir.

This matches “standard XDG” where env is set, while defaulting to
`**~/Library/Application Support/transcribe/`** on Mac when it is not—common for
native tools and easy to find in Finder.

## File format: JSON Lines vs SQLite

| Approach                                                 | Pros                                                          | Cons                                                      |
|:---------------------------------------------------------|:--------------------------------------------------------------|:----------------------------------------------------------|
| **JSON Lines** (`timing_history.jsonl`, 1 JSON per line) | Trivial append, human-readable, easy `tail`, no DB dependency | Rolling averages need reading last *N* lines or full scan |
| **SQLite**                                               | Indexed queries, rolling AVG, easy caps (e.g. last 500 runs)  | Slightly more code, migration story                       |

**Recommendation:** Start with **JSON Lines** for simplicity and transparency;
add a small in-memory aggregate (e.g. last 20–50 runs per `(model,
diarization_enabled)`) loaded at startup for ETA. *Shipped:* last **50** rows
matching model + diarization after scanning the JSONL file. If history grows
large, migrate to SQLite in a follow-up or add a periodic **compaction** job
(optional).

Schema: version field `schema_version: 1` inside each line for forward
compatibility.

## Using history to improve ETA

1. **On startup / first progress tick:** Load recent records (filter matching
   `model` + `diarization_enabled`), compute robust predictors:

- `r_total = median(total_ms / audio_duration_s)` (or trim mean). *Implemented:*
  `median((total_ms / 1000) / audio_duration_s)` so `r_total` is **wall-seconds
  per second of audio** (stored `total_ms` is milliseconds).
- Optionally separate `r_parallel` for the diarization path using stored
  `parallel_ms`. *Shipped:* `processingSecondsPerAudioSecond` is exactly this
  (`parallel_ms`, else `transcribe_only_ms`) and is the primary predictor;
  `r_total` is only a fallback.

1. **Live display updates:**

- **Diarization:** Keep fraction-based ETA where `fractionCompleted` is
  reliable; optionally **blend** with history-based ETA when fraction is noisy.
  *Shipped:* blended through `PhaseETA` (history until 20% done, then live
  pace).
- **Transcription:** With no native fraction, show ETA using **elapsed +
  predicted remaining**. *Shipped:* WhisperKit's `Progress` supplies
  completed/total chunks, so the line has a native fraction; history seeds the
  estimate and the live pace takes over. `elapsed` is measured from the start of
  the transcribe block, matching `parallel_ms`. No `file_bytes` regression yet.

1. **Cold start / first run:** No history → omit transcription ETA until the
   current run provides a pace. *Shipped:* the transcription ETA appears at the
   first completed chunk and the total ETA follows it.
2. **WhisperKit follow-up:** *Shipped:* `whisperKit.progress`
   (`completedUnitCount` / `totalUnitCount`) is polled during transcription; see
   “ETA estimator (as shipped)”.

## CLI / behavior

- **Default:** Record stats on successful completion (and optionally on failure
  with `error_stage` for debugging—can be phase 2). *Shipped:* successful path
  only; no failure records yet.
- **`--eta-hints off`** (or env `TRANSCRIBE_ETA_HINTS=0`; legacy
  `TRANSCRIBE_TIMING_STATS=0`): disable write and disable ETA-from-history for
  users who do not want persistence.
- Document path in [README.md](../README.md) under “Timing statistics” (links to
  this file).

## Code touchpoints

- **Added:** [`StatePaths.swift`](../Sources/transcribe/StatePaths.swift),
  [`RunTimingRecord.swift`](../Sources/transcribe/RunTimingRecord.swift)
  (Codable), [`PhaseTimings.swift`](../Sources/transcribe/PhaseTimings.swift),
  [`TimingStore.swift`](../Sources/transcribe/TimingStore.swift) (append + load
  recent + median).
- [`main.swift`](../Sources/transcribe/main.swift): instrument `runPipeline`;
  append after success; pass median ratio into pipeline / `LiveProgressDisplay`.
- [`TranscriptionPipeline.swift`](../Sources/transcribe/TranscriptionPipeline.swift):
  `async throws -> (TranscriptionOutput, PhaseTimings)` with
  `WallClock.measureMs` at boundaries.
- [`LiveProgress.swift`](../Sources/transcribe/LiveProgress.swift): historical
  ETA suffix on transcription line when ratio is non-nil.
- **Tests:**
  [TimingStoreTests.swift](../Tests/transcribeTests/TimingStoreTests.swift),
  [LiveProgressTests.swift](../Tests/transcribeTests/LiveProgressTests.swift)
  (captured output tests).

## Risks / notes

- **First-time model download** inflates `whisper_init_ms`; store a boolean
  `models_were_cached` if you can infer it (e.g. init time threshold) so
  aggregates can exclude outliers.
- **Parallel transcribe + diarize:** Wall times for the two are not independent;
  storing `parallel_ms` as one block matches user-perceived wait and is what ETA
  should predict.
