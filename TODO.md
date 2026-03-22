# TODO

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

## Security review (2026-03-22)

Full review of all 15 source files, 6 test files, configuration, and git
history. No critical or high-severity issues found. Attack surface is
narrow: local-only CLI with no network listeners, web interfaces, or
databases.

### [FIXED] Path traversal via --output-prefix (Low)

`OutputWriter.swift` uses the `--output-prefix` value directly as a filename
component without sanitizing directory separators. A value like
`../../etc/foo` would write files outside the intended output directory. Low
impact since the user controls their own invocation, but matters if the tool
is ever called with untrusted input.

**Fix:** Validate that `outputPrefix` contains no `/` or `..` components.
(Fixed 2026-03-22)

### [FIXED] Predictable temp file name in writeAtomically (Low)

`OutputWriter.swift:42` constructs the temp file name using the PID, which
is predictable. On a shared system another process could pre-create a
symlink at that path to redirect the write.

**Fix:** Use a UUID or `mkstemp`-equivalent for temp file names. (Fixed
2026-03-22)

### Timing history file permissions (Informational)

`TimingStore.swift:67` creates the timing history file with mode `0644`
(world-readable). The file contains input filenames and timing metadata,
which leaks what audio files were transcribed and when.

**Fix:** Use `0600` instead.

### No input size limit (Informational)

`AudioLoader.swift` loads the entire audio file into memory as `[Float]`
with no size check. An extremely large file could cause excessive memory
use. Low priority since the user chooses the input file.

### Positive findings

- Atomic file writes with temp-file-then-rename prevents partial output
- Overwrite protection by default (requires `--overwrite`)
- POSIX file locking (`flock`) for concurrent timing history writes
- No shell invocations from Swift (no command injection surface)
- No network access; all processing is local/on-device
- Input validation on CLI arguments (formats, speaker counts, combinations)
- No secrets in code or git history
- Dependencies pinned in `Package.resolved`
