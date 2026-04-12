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
  `audioDurationSeconds`, and optional `historicalWallSecondsPerAudioSecond`;
  the transcription line appends a **(~Xm Ys left)** suffix when history
  provides a median ratio.
- **History read:** Up to **50** most recent matching rows (`model` +
  `diarization_enabled`), then median of `total_ms / 1000 / audio_duration_s` →
  **wall seconds per second of audio** (not microseconds; stored times are
  **milliseconds**).
- **Opt-out:** `--no-timing-stats` or `TRANSCRIBE_TIMING_STATS=0` disables load,
  ETA-from-history, and append. Append failures are non-fatal (`try?`).
- **User docs:** [README.md](../README.md) “Timing statistics” links here.
- **Tests:**
  [TimingStoreTests.swift](../Tests/transcribeTests/TimingStoreTests.swift)
  (median, XDG path, append/filter); live progress tests cover `finish()` return
  value.

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
  CLI?](https://github.com/argmaxinc/WhisperKit/issues/202) — Feature request;
  direction is to drive UI from WhisperKit’s **progress** object.
- [PR #179 – Fix progress when using VAD
  chunking](https://github.com/argmaxinc/WhisperKit/pull/179) — Makes
  `fractionCompleted` **monotonic** across VAD chunks via weighted child
  progress (important for any fraction-based ETA).
- [PR #335 – WhisperKit CLI verbose / progress-style
  logging](https://github.com/argmaxinc/WhisperKit/pull/335) — Upstream CLI
  improvements around progress and logging (still **live** signals, not a
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
  when `--no-diarize` / short-audio fallback)
- `parallel_ms` — for diarization path, time for the `async let` block where
  transcribe and diarize run together (dominant cost)
- `transcribe_only_ms` — for `--no-diarize` path, time inside
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
  `parallel_ms` (not implemented separately yet; ETA uses full-run `total_ms`
  only).

1. **Live display updates:**

- **Diarization:** Keep fraction-based ETA where `fractionCompleted` is
  reliable; optionally **blend** with history-based ETA when fraction is noisy
  (e.g. weight 0.5 / 0.5). *Shipped:* diarization line is still fraction-based
  only (no blend).
- **Transcription:** With no native fraction, show ETA using **elapsed +
  predicted remaining**:
  - `predicted_total = r_total * audio_duration_s` (tune with optional
    `file_bytes` term later: `a * duration + b * bytes`). *Shipped:* history
    term only; no `file_bytes` regression in the ETA path yet.
  - `remaining = max(0, predicted_total - elapsed)` — expose on the
    transcription line when `r_total` is available (after at least one prior
    run, or use a conservative default). *Shipped:* `elapsed` is from the shared
    **`pipelineStartDate`** (full pipeline, not “since transcribe started”).

1. **Cold start / first run:** No history → omit transcription ETA or show “…”
   until enough elapsed to estimate from **current** run (e.g. after first 5–10%
   of predicted duration from a rough default ratio). *Shipped:* no rough in-run
   extrapolation yet—history-based suffix appears only after prior matching runs
   exist; otherwise the transcription line has elapsed but no ETA suffix.
2. **WhisperKit follow-up (optional):** Inspect `TranscriptionProgress` /
   timings in WhisperKit for a **fraction or completed/total windows** to
   combine with historical ETA (hybrid is usually best).

## CLI / behavior

- **Default:** Record stats on successful completion (and optionally on failure
  with `error_stage` for debugging—can be phase 2). *Shipped:* successful path
  only; no failure records yet.
- **`--no-timing-stats`** (or env `TRANSCRIBE_TIMING_STATS=0`): disable write
  and disable ETA-from-history for users who do not want persistence.
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
  (stderr pipe tests).

## Risks / notes

- **First-time model download** inflates `whisper_init_ms`; store a boolean
  `models_were_cached` if you can infer it (e.g. init time threshold) so
  aggregates can exclude outliers.
- **Parallel transcribe + diarize:** Wall times for the two are not independent;
  storing `parallel_ms` as one block matches user-perceived wait and is what ETA
  should predict.
