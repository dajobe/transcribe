# TODO

## Model download progress

Report to the user before starting a large model download. Ideally show
download progress (bytes/total, speed, ETA). At minimum, print a message
like "Downloading model openai_whisper-large-v3-v20240930 (~3 GB)..." before
the download begins.

**Research (feasibility):**

- **Minimum (message before download):** Feasible. WhisperKit’s download
  runs inside `WhisperKit(config)` → `setupModels()` → `Self.download(...)`
  and that call does not pass a `progressCallback`, so we can’t hook in
  without changing flow. Approach: when cache is missing/empty,
  **pre-download** by calling `WhisperKit.download(variant:model,
  downloadBase:..., progressCallback: ...)` ourselves, then create
  WhisperKit with `modelFolder` set to the returned URL and `download:
  false`. We control the flow and can print our message before the call. Use
  a small hardcoded model-name → approximate-size table (e.g. large-v3 → ~3
  GB) for the message.

- **Progress / speed / ETA:** Same pre-download flow. The callback receives
  Foundation `Progress`: `totalUnitCount` = number of files (not bytes),
  `completedUnitCount` advances per file, `fractionCompleted` is valid. Hub
  sets `progress.userInfo[.throughputKey]` to bytes/sec. So we can show file
  N/M, percentage, and speed (e.g. 2.1 MB/s). Total bytes are not reported
  by the Hub API; we can derive an approximate ETA from fraction + speed +
  our size table.

- **SpeakerKit:** `SpeakerKitModelManager.downloadModels(progressCallback:)`
  already accepts a callback. We currently use `SpeakerKit(config)` which
  doesn’t expose it. To show SpeakerKit download progress, use the manager
  directly: create manager, call `downloadModels(progressCallback:)`, then
  `SpeakerKit(models: manager.models!)`.

## Live transcription/diarization progress

Show live progress during transcription and diarization when stderr is a
TTY, so the user has a sense of when things will finish. Fall back to simple
log lines when not a TTY.

Because transcription and diarization run in **parallel** (separate tasks),
a single combined progress bar is not accurate. Instead, use **two lines**
that update in place via terminal cursor control:

- **Line 1:** Transcription progress (e.g. segments or windows done, % if
  derivable, elapsed).
- **Line 2:** Diarization progress (e.g. segmenter/embedder phase,
  fractionCompleted from the API).

On each callback from either task, move cursor up, redraw both lines (e.g.
`\r`, `\033[K` to clear to EOL, then `\033[A` to go up and redraw the other
line), and serialize updates (lock or actor) so output doesn’t interleave.
Only enable when `isatty(stderr)`; otherwise keep current verbose log lines.

**Research (feasibility):**

- **WhisperKit** exposes `transcribe(audioArray:decodeOptions:callback:)`
  with `TranscriptionCallback = ((TranscriptionProgress) -> Bool?)?`. We can
  pass a callback and get progress during decoding (e.g. tokens/text so far,
  timings). Use it to drive the “transcription” line.

- **SpeakerKit** exposes `diarize(audioArray:options:progressCallback:)`
  with `progressCallback: (Progress) -> Void`. The diarizer updates a single
  `Progress` (e.g. 0–100) across segmenter and embedder phases. Use it to
  drive the “diarization” line.

- **Two-line TTY updates** are standard: carriage return, ANSI escape codes
  (e.g. `\033[A` up, `\033[K` clear to end of line). Ensure updates are
  serialized so one callback doesn’t write between the other’s two line
  draws.

## Add TSV output format

WhisperX outputs a TSV format (tab-separated: start, end, text with times in
milliseconds). Consider adding `tsv` as a supported `--format` option for
compatibility with whisperx output. The format is simple:

    start end text
    229778 230399 Hi Dave.
    230899 231139 Hi.

This would make the supported formats: txt, json, srt, vtt, tsv.
