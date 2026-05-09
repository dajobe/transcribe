# transcribe

A macOS command-line tool for local meeting transcription with speaker
diarization. Combines [WhisperKit](https://github.com/argmaxinc/WhisperKit) for
speech-to-text and SpeakerKit for speaker diarization into a single pipeline
that runs entirely on-device on Apple Silicon.

No cloud APIs, API keys, Python, or HuggingFace authentication required.

## Requirements

- macOS 14.0 or later
- Apple Silicon (M1 or later)
- Xcode 16.0 or later (build only)

## Build and Install

```bash
make install                       # builds release and installs to $HOME/bin
make install BINDIR=/usr/local/bin # or pick another directory
```

That builds `.build/release/transcribe` and copies it to `$HOME/bin/transcribe`
(override the destination with `BINDIR=...`). To build only:

```bash
make build      # or: swift build -c release
```

Use the release build for normal transcription runs; debug builds are primarily
for development and can be slower. Ensure the install directory is on your
`PATH`.

## Usage

```text
transcribe [global-options] file <audio-file>
transcribe [global-options] dir [dir-options] <directory>
transcribe [global-options] voice-memos [voice-memos-options]

# Convenience aliases:
transcribe [global-options] <audio-file>
transcribe [global-options] <directory>
```

Use `file`, `dir`, or `voice-memos` as the canonical source commands. The root
positional form remains as a convenience alias: if the path is a file it
dispatches to `file`, and if the path is a directory it dispatches to `dir`.
Global options must appear before the source command or path. Source-specific
options appear after their source command.

Directory input is for sequential clips. The top-level audio files are ordered
by recording time and split into one or more sessions whenever there is a
multi-minute gap between consecutive clips (`--session-gap`, default 10 min).
Each session is transcribed independently and produces its own transcript named
after the directory (e.g. `~/voicenotes/2026-may-meeting/` →
`2026-may-meeting.txt`, or `2026-may-meeting - Recording 1.txt` and `... -
Recording 2.txt` when split).

### Examples

```bash
# Run the optimized release build directly
.build/release/transcribe file meeting.mp3

# Transcribe with speaker diarization, output txt + json
transcribe file meeting.mp3

# Constrain to two speakers, all output formats
transcribe --language en --min-speakers 2 --max-speakers 2 --format all file meeting.mp3

# Transcript only, no diarization, smaller model
transcribe --no-diarize --model medium file lecture.m4a

# Transcript to stdout and JSON to disk
transcribe --stdout --format txt,json -o ./transcripts file interview.wav

# Markdown transcript (and JSON) for notes / publishing
transcribe --format md,json -o ./notes file meeting.m4a

# A directory of sequential voice notes treated as one recording.
# Output basename comes from the directory: 2026-may-meeting.{txt,json}
transcribe dir ~/voicenotes/2026-may-meeting/

# The old root positional shape is still accepted as an alias.
transcribe meeting.mp3
transcribe ~/voicenotes/2026-may-meeting/

# Import synced Apple Voice Memos directly from the local iCloud-backed store.
transcribe -o ./voice-memo-transcripts --format md,json voice-memos

# Preview which synced Voice Memos would process or skip.
transcribe --dry-run voice-memos

# Mark all currently synced Voice Memos as already imported without transcribing.
transcribe --mark-imported voice-memos

# Override compute units explicitly
transcribe \
  --audio-encoder-compute cpuAndGPU \
  --text-decoder-compute cpuAndGPU \
  --segmenter-compute cpuAndGPU \
  --embedder-compute cpuAndGPU \
  file meeting.mp3
```

### Directory input

Use `transcribe dir <directory>` for directories of sequential audio clips. The
root alias `transcribe <directory>` accepts global options only; use
`transcribe dir` for directory-specific options.
`transcribe` orders the directory's top-level audio files, splits them into one
or more sessions at gaps over the threshold, and runs the pipeline once per
session.

- **Sort order:** by default clips are ordered by their embedded recording
  timestamp (the M4A `creation_time` atom). Files without that metadata fall
  back to file modification time, then to natural-sort filename, so order stays
  deterministic for mixed directories. Use `--sort name` to force
  natural-sort filename ordering (handles `Note 1.m4a, …, Note 10.m4a`) or
  `--sort mtime` to use file modification time only. The previous
  `--input-sort` spelling is still accepted as an alias.
- **Session splitting:** if adjacent clips have a recorded-at gap larger than
  `--session-gap` minutes (default `10`), the directory is split into separate
  transcripts — one per detected session. Set `--session-gap 0` to disable
  splitting and concatenate everything into one transcript. Splitting is skipped
  when adjacent clips lack the metadata needed to compute a gap.
- **Filtering:** files are filtered by extension (case-insensitive) against the
  supported formats. Hidden files (`.DS_Store`, `._*`) and subdirectories are
  skipped; subdirectories are not recursed into.
- **Padding:** ~200 ms of silence is inserted between consecutive clips within a
  session to smooth Whisper's VAD chunking.
- **Diarization:** runs once per session, so a speaker who appears in multiple
  clips of one session lands on a single `SPEAKER_n` label.
- **Output basename:** the directory's last path component, with no extension
  stripping (preserves names like `2026.04.notes`). When the directory yields
  multiple sessions, outputs are named `<basename> - Recording 1`, `<basename> -
  Recording 2`, … When the directory has no usable name (e.g. the input was `.`
  or `/`), outputs fall back to `Recording 1`, `Recording 2`, …. Override the
  base with `--output-prefix`.
- **JSON metadata:** an `audio_files` array lists the source filenames for that
  session in concat order; the field is omitted for single-file input.
- **Empty / no-audio directories:** exit code `3` with a clear message on
  stderr.
- **Verbose mode** prints the per-clip sort keys (recorded date and mtime) and
  per-pair gap analysis, e.g.:

  ```text
  sort=recorded: per-clip keys (in final order)
    sort key: New Recording.m4a recorded=2026-05-06T09:14:22Z mtime=2026-05-06T09:18:03Z
    sort key: New Recording 2.m4a recorded=2026-05-06T09:32:11Z mtime=2026-05-06T09:33:48Z
  gap: New Recording.m4a -> New Recording 2.m4a = 13m 49s (>10m 0s threshold) -> new session
  sessions: 2 (1, 1 clips each)
  ```

**Voice Memos caveat.** Apple's Voice Memos app rewrites the M4A `creation_time`
atom to "now" when files are exported via Files / iCloud Drive, so the embedded
date no longer reflects when you actually recorded. `transcribe` detects this
automatically: when the spread of recorded timestamps across clips is smaller
than the longest clip's duration, the timestamps cannot represent real
sequential recording starts, and the run falls back to filename ordering with a
warning on stderr. Pass `--sort name` to silence the warning.

### Recommended naming convention for directory input

When the embedded `creation_time` is unreliable (most Voice Memos exports), the
filename is your most reliable signal. Naming clips so `transcribe` can recover
ordering, session splitting, and meaningful output basenames:

1. **Start each filename with a recording time prefix.** Use `HH:MM` (24-hour,
   colon, space) for same-day batches, e.g. `09:00 morning standup.m4a`. For
   recordings spanning multiple days use `YYYY-MM-DD HH:MM`. Two-digit hours
   sort correctly under all sort modes.
2. **Share a stable label across clips of one session.** When a single recording
   arrives in parts, keep the prefix and label identical and add `part 1`, `part
   2`, … as a suffix:

   ```text
   meetings/
     09:00 morning standup.m4a
     09:30 design review part 1.m4a
     09:30 design review part 2.m4a
     11:00 customer call.m4a
   ```

3. **Apply the convention to every file in the directory.** A single un-prefixed
   file blocks automatic recovery for the whole directory.

For the full naming spec — recognised time-prefix patterns, common-prefix
session basename rules, and verbose-log examples — see
[`specs/filename-derived-metadata.md`](specs/filename-derived-metadata.md).

### Options

Global options are accepted before `file`, `dir`, `voice-memos`, and the root
file/directory alias. Run `transcribe --help` to see these options.

| Option                            | Description                                                                                      |
|:----------------------------------|:-------------------------------------------------------------------------------------------------|
| `-m, --model <name>`              | Whisper model (default: `openai_whisper-large-v3_turbo`; ~1.5 GB on first run)                   |
| `-l, --language <code>`           | Language code (default: auto-detect)                                                             |
| `-o, --output-dir <path>`         | Output directory (default: `.`); `~` is your home directory (not `/tmp`)                         |
| `-f, --format <fmt>`              | Output formats, comma-separated: `txt`, `json`, `srt`, `vtt`, `md`, `all` (default: `txt,json`)  |
| `--stdout`                        | Write transcript text to stdout instead of a file                                                |
| `--min-speakers <n>`              | Minimum speakers for diarization                                                                 |
| `--max-speakers <n>`              | Maximum speakers for diarization                                                                 |
| `--no-diarize`                    | Disable speaker diarization                                                                      |
| `--speaker-strategy <s>`          | Speaker merge strategy: `subsegment` or `segment` (default: `subsegment`)                        |
| `--model-dir <path>`              | Model cache directory (default: `~/.cache/transcribe`)                                           |
| `--overwrite`                     | Replace existing output files                                                                    |
| `--redo`                          | Reprocess inputs even when processing history says they already completed                         |
| `--no-processing-state`           | Do not consult or write idempotent processing history                                             |
| `--mark-imported`                 | Mark planned inputs as already imported without transcribing                                      |
| `--dry-run`                       | Show what would process or skip without loading models, writing outputs, or updating history      |
| `--verbose`                       | Print progress and timing to stderr                                                              |
| `--debug-progress-log`            | Log progress/ETA as plain stderr lines (~1/s) without a TTY (e.g. capture to a file or pipe)     |
| `--no-timing-stats`               | Do not save timing history or use prior runs for ETA hints on the transcription line             |
| `--audio-encoder-compute <units>` | Whisper audio encoder compute units: `auto`, `all`, `cpuOnly`, `cpuAndGPU`, `cpuAndNeuralEngine` |
| `--text-decoder-compute <units>`  | Whisper text decoder compute units: `auto`, `all`, `cpuOnly`, `cpuAndGPU`, `cpuAndNeuralEngine`  |
| `--segmenter-compute <units>`     | SpeakerKit segmenter compute units: `auto`, `all`, `cpuOnly`, `cpuAndGPU`, `cpuAndNeuralEngine`  |
| `--embedder-compute <units>`      | SpeakerKit embedder compute units: `auto`, `all`, `cpuOnly`, `cpuAndGPU`, `cpuAndNeuralEngine`   |

Directory-only options for `transcribe dir`:

| Option                                              | Description                                                                       |
|:----------------------------------------------------|:----------------------------------------------------------------------------------|
| `--sort <mode>` / `--input-sort <mode>`             | Order directory input: `recorded` (default), `name`, `mtime`                      |
| `--filename-time-recovery` / `--no-filename-time-recovery` | Recover leading filename times when embedded dates are missing or untrusted |
| `--auto-session-basename` / `--no-auto-session-basename` | Derive session output basenames from common filename prefixes                |

Batch session option for `transcribe dir` and `transcribe voice-memos`:

| Option                    | Description                                                                       |
|:--------------------------|:----------------------------------------------------------------------------------|
| `--session-gap <min>`     | Split batch input at gaps > N minutes between clips (0 disables; default: 10)     |

Voice Memos-only options for `transcribe voice-memos`:

| Option                     | Description                                                                           |
|:---------------------------|:--------------------------------------------------------------------------------------|
| `--recordings-dir <path>`  | Voice Memos recordings directory (default: Apple’s synced recordings group container) |

When SpeakerKit can accept an exact speaker count hint, `transcribe` passes it
only when `--min-speakers` and `--max-speakers` are both set to the same value.
Otherwise diarization runs unconstrained and warns if the detected count falls
outside the requested bounds.

By default, `auto` uses the recommended backend mix for each WhisperKit and
SpeakerKit model. On Apple Silicon this typically means a combination of GPU,
Neural Engine, and CPU rather than forcing every component onto the GPU. Use
`--verbose` to print the selected compute backend for WhisperKit and SpeakerKit.

### Timing statistics

Successful runs can append timing records for ETA hints on the **transcription**
progress line. Disable with `--no-timing-stats` or `TRANSCRIBE_TIMING_STATS=0`.

Full schema, paths, and ETA behavior:
**[specs/timing-history.md](specs/timing-history.md)**.

### Processing history and idempotency

Successful transcription sessions are recorded in a processing history file so
rerunning the same command can skip work that is already complete. The history
tracks the input source, SHA-256 audio fingerprint, important transcription
settings, requested output files, and completion metadata.

- **Default behavior:** if the source audio, important settings, and requested
  output files match a previous completed run, and all requested outputs still
  exist, the session is skipped before audio preflight or model loading.
- **Changed input/settings:** changed audio bytes, model, language,
  diarization settings, speaker options, formats, or transcribe version cause a
  new run.
- **Missing outputs:** if history says a session completed but the requested
  output files are missing, the session is processed again.
- **Redo:** pass `--redo` to ignore processing history and process matching
  inputs again. Existing output files still require `--overwrite`.
- **Opt out:** pass `--no-processing-state` to neither consult nor write
  processing history.
- **Dry run:** pass `--dry-run` to scan inputs, compute fingerprints, and show
  what would process or skip without preflighting audio, loading models,
  writing outputs, or updating processing history.

The processing history lives next to the timing history under the transcribe
state directory as `processing_history.jsonl`.

### Voice Memos import

`transcribe voice-memos` reads Apple Voice Memos that are already synced to
disk. It uses the Core Data SQLite index and sibling audio files under:

```text
~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/
```

The importer reads `CloudRecordings.db` read-only and transcribes the `.m4a`
files in place. There is no download, copy, or conversion step.

- **Metadata:** recording date comes from `ZDATE`; title comes from
  `ZCUSTOMLABEL`, then `ZENCRYPTEDTITLE`, then `New Recording`. The stable
  identity prefers `ZUNIQUEID` and falls back to the audio path.
- **Output names:** Voice Memos use `YYYY-MM-DD HHMM <title>`, with unsafe
  filename characters stripped and numeric suffixes added for collisions.
- **Output metadata:** JSON and Markdown include `source: voice_memos`,
  recorded time, recording title, Voice Memos unique ID when present, and the
  source path.
- **Session grouping:** Voice Memos use the same `--session-gap` default as
  directory input. Adjacent memos recorded within the gap are processed as one
  transcript session; gaps larger than the threshold start a new transcript.
  Use `--session-gap 0` to process all synced memos as one session.
- **Baseline import:** `transcribe --mark-imported voice-memos` records the
  planned Voice Memo sessions as imported without writing transcript outputs.
  The same global `--mark-imported` option works for `file` and `dir` inputs.
  Future runs skip matching inputs unless their audio fingerprint changes or
  `--redo` is used.
- **Dry run:** `transcribe --dry-run voice-memos` lists recordings that would
  process or skip. `transcribe --dry-run --mark-imported voice-memos` lists
  recordings that would be marked imported without writing the baseline.
- **Permissions:** if macOS denies the Voice Memos container, grant Full Disk
  Access to the app or shell running `transcribe`.

Use `--recordings-dir <path>` to point at a fixture or alternate recordings
directory containing `CloudRecordings.db`.

### Performance

- Use `.build/release/transcribe` for normal transcription runs. Debug builds
are intended for development and can be slower.
- The default `auto` mode is tuned for the fastest backend mix the models
support, which may use a combination of GPU, Neural Engine, and CPU.
- Use `--verbose` to print the selected WhisperKit and SpeakerKit compute
backends at startup.

### Supported Audio Formats

`mp3`, `wav`, `m4a`, `flac`, `aiff`, `caf`

### Folder Action (drop folder)

To transcribe files automatically when they are added to a folder, use macOS
**Automator** with a **Folder Action** workflow that runs
`**scripts/folder-action-transcribe.sh`**. An optional **example wrapper** that
sets log/output paths and `TRANSCRIBE_BIN` is `**scripts/folder-script.sh`**
(edit the `root_dir` and paths inside to match your layout; it invokes
`folder-action-transcribe.sh` from the same directory).

1. Build and install the `transcribe` binary (see [Build and
Install](#build-and-install)).
2. `chmod +x scripts/folder-action-transcribe.sh` (and `folder-script.sh` if you
   use it)
3. Open **Automator**, create **Folder Action**, choose the watched folder, add
**Run Shell Script**, shell `/bin/bash`, and pass input **as arguments** to the
script (path to the checked-in script or a copy).
4. Optionally set environment variables in the shell script step or a wrapper
(see below).

Full behavior, stable-file wait, and exit codes:
**[specs/folder-action-markdown.md](specs/folder-action-markdown.md)**.

| Variable                       | Meaning                                                                                         |
|:-------------------------------|:------------------------------------------------------------------------------------------------|
| `TRANSCRIBE_BIN`               | Path to `transcribe` (default: `transcribe` on `PATH`)                                          |
| `TRANSCRIBE_OUTPUT_DIR`        | If set, `-o` for all runs; if unset, outputs go next to each input file                         |
| `TRANSCRIBE_FORMAT`            | `--format` value (default: `md`)                                                                |
| `TRANSCRIBE_EXTRA_ARGS`        | Extra global CLI flags inserted before `file` (space-separated)                                  |
| `TRANSCRIBE_STABLE_SECS`       | Seconds of unchanged file size before running (default: `2`)                                    |
| `TRANSCRIBE_MAX_STABLE_WAIT`   | Max seconds to wait for a stable file (default: `3600`)                                         |
| `TRANSCRIBE_LOCK_FILE`         | If set and `flock` exists, serialize concurrent runs                                            |
| `TRANSCRIBE_SKIP_IF_MD_EXISTS` | If `1`, skip when `basename.md` already exists in the output dir                                |
| `TRANSCRIBE_LOG`               | Structured events (`event=start` / `event=end`, etc.); see the spec                             |
| `TRANSCRIBE_STDERR_LOG`        | Full `transcribe` stderr on failure (default: `transcribe.stderr.log` next to `TRANSCRIBE_LOG`) |
| `TRANSCRIBE_SCRIPT_DIR`        | Directory containing `folder-action-transcribe.sh` (if the wrapper cannot resolve it)           |
| `TRANSCRIBE_SMOKE_LOG`         | If set, append debug lines (argc, `script_dir`, helper present) to this path                    |

**Troubleshooting**

- **Nothing runs, no log:** Set **Pass input** to **as arguments** (not “to
  stdin”). If `argc=0` in a smoke log, that was the issue.
- **Smoke log (`argc=1` but still no transcription):** The wrapper must find
  **`folder-action-transcribe.sh`** next to itself. If you **paste** the script
  into Automator, `script_dir` is wrong — set **`TRANSCRIBE_SCRIPT_DIR`** to the
  directory that contains both scripts (e.g. `export
  TRANSCRIBE_SCRIPT_DIR=$HOME/bin` in the shell block), or use **File → Open**
  and run the script file by path instead of pasting. Enable
  **`TRANSCRIBE_SMOKE_LOG=/tmp/folder-action-smoke.log`** to log `script_dir`
  and whether the helper exists.
- **Extensions:** Allowed audio types only; see the log for `skip-non-audio` if
  needed.
- **`event=end` with `exit=4` / `reason=transcribe-failed`:** Model download or
  load failed. Check the same log for **`transcribe-exit=`**,
  **`meaning=model`**, and **`transcribe-stderr:`** (and
  **`transcribe.stderr.log`** next to your main log for the full stderr block).
  Run **`transcribe`** on that file in Terminal for the same message.

## Output

Given `meeting.mp3`, the tool writes:

- `meeting.txt` — human-readable transcript with speaker labels and timestamps
- `meeting.json` — machine-readable transcript preserving segment boundaries
- `meeting.srt` — SubRip subtitle format
- `meeting.vtt` — WebVTT subtitle format
- `meeting.md` — Markdown transcript with metadata and headings

Which files are written depends on `--format`. Markdown details:
**[specs/folder-action-markdown.md](specs/folder-action-markdown.md)**.

### Text output

```text
SPEAKER_0 [00:00:00 - 00:00:12]
Welcome, thanks for joining. I wanted to start by talking about
the infrastructure migration timeline.

SPEAKER_1 [00:00:13 - 00:00:28]
Sure, happy to be here. We've been looking at the Q2 window for
the cutover, but there are some dependencies I want to flag.
```

Without diarization, speaker labels are omitted but time ranges remain:

```text
[00:00:00 - 00:00:12]
Welcome, thanks for joining. I wanted to start by talking about
the infrastructure migration timeline.
```

### JSON output

```json
{
  "metadata": {
    "audio_file": "meeting.mp3",
    "duration_seconds": 1847.3,
    "model": "large-v3",
    "language": "en",
    "diarization_enabled": true,
    "speaker_strategy": "subsegment",
    "speakers_detected": 2,
    "transcribe_version": "X.Y.Z",
    "created_at": "2026-03-16T19:30:00Z"
  },
  "warnings": [],
  "segments": [
    {
      "speaker": "SPEAKER_0",
      "start": 0.0,
      "end": 12.4,
      "text": "Welcome, thanks for joining."
    }
  ]
}
```

## Exit Codes

| Code | Meaning                                  |
|:-----|:-----------------------------------------|
| 0    | Success                                  |
| 1    | Runtime failure                          |
| 2    | Invalid CLI usage                        |
| 3    | Input file problem                       |
| 4    | Model download or initialization failure |
| 5    | Output write failure                     |

## Development

For the code map, pipeline flow, state files, tests, and release checklist, see
[hacking.md](hacking.md).

## License

This project is licensed under the [MIT License](LICENSE).

### Dependency licenses

| Dependency                                                              | License    |
|:------------------------------------------------------------------------|:-----------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit)                   | MIT        |
| [SpeakerKit](https://github.com/argmaxinc/WhisperKit)                   | MIT        |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache 2.0 |

Speaker diarization uses [pyannote](https://github.com/pyannote/pyannote-audio)
community models licensed under
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). Attribution:

> Plaquet, A., & Bredin, H. (2023). Powering speaker diarization by
> multi-scale neural embeddings and non-autoregressive clustering.
> *IEEE ICASSP 2023*.
