# TODO

## Review backlog (2026-03-20)

## Fix broken compute fallback behavior

`RuntimeComputeOptions.resolve` currently builds fallback compute settings
that are identical to the preferred settings, so `whisperFallback` /
`speakerFallback` are always `nil`. That means the retry/fallback paths in
`initializeWhisperKit` and `initializeSpeakerKit` never actually downgrade
to a safer backend when GPU/Metal selection fails.

Work:

- Define an explicit fallback policy for `auto` mode, likely preferring the
  library defaults first and then falling back to `cpuOnly` where needed.
- Keep explicit user-selected compute settings authoritative: if the user
  forced `cpuOnly`, `cpuAndGPU`, etc., don't silently override them.
- Add tests that prove a distinct fallback is produced for `auto` mode and
  that explicit selections still suppress fallback.

## Drain live progress updates before finishing output

Progress callbacks currently enqueue `Task { ... }` updates into the
`LiveProgressDisplay` actor, but `finish()` does not wait for those
unstructured tasks to complete. On a real run this can leave a race where
late updates redraw progress after the final newline/cleanup.

Work:

- Replace unstructured `Task { ... }` progress forwarding with a mechanism
  that preserves ordering and allows the pipeline to await all pending
  updates before `finish()`.
- Add a regression test that simulates late callback delivery and asserts
  that no progress output appears after `finish()`.

## Reject empty or degenerate `--format` values

`resolvedFormats` can currently become empty for values like `--format ""`
or `--format ,`, and the command then succeeds after doing the expensive
work while writing no outputs. That should be rejected as invalid CLI usage.

Work:

- Fail validation when the resolved format list is empty.
- Consider normalizing/deduplicating repeated formats while keeping output
  ordering stable.
- Add CLI tests for empty and duplicate format lists.

## Validate speaker counts as positive integers

`--min-speakers` and `--max-speakers` are only checked for ordering today.
Zero or negative values are accepted, which can flow into warnings or fixed
speaker-count hints that make no semantic sense.

Work:

- Reject non-positive speaker counts during CLI validation.
- Add tests for `0` and negative values for both options.

## Harden timing-history writes for concurrent runs

`TimingStore.append` does a seek-to-end and write without any file locking.
If multiple `transcribe` processes append concurrently, the JSONL history
file can be corrupted or lose records.

Work:

- Serialize appends with a file lock or replace the raw append flow with a
  safer write strategy.
- Add a focused concurrency test if feasible, or at least isolate the file
  append logic behind a testable abstraction.

## Model download progress

Report to the user before starting a large model download. Ideally show
download progress (bytes/total, speed, ETA). At minimum, print a message
like "Downloading model openai_whisper-large-v3-v20240930 (~3 GB)..." before
the download begins.

**Research (feasibility):**

- **Minimum (message before download):** Feasible. WhisperKit's download
  runs inside `WhisperKit(config)` → `setupModels()` → `Self.download(...)`
  and that call does not pass a `progressCallback`, so we can't hook in
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
  doesn't expose it. To show SpeakerKit download progress, use the manager
  directly: create manager, call `downloadModels(progressCallback:)`, then
  `SpeakerKit(models: manager.models!)`.

## Add TSV output format

WhisperX outputs a TSV format (tab-separated: start, end, text with times in
milliseconds). Consider adding `tsv` as a supported `--format` option for
compatibility with whisperx output. The format is simple:

    start end text
    229778 230399 Hi Dave.
    230899 231139 Hi.

This would make the supported formats: txt, json, srt, vtt, tsv.
