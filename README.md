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
swift build -c release
cp .build/release/transcribe ~/.local/bin/
```

The optimized binary is written to `.build/release/transcribe`. Use the release
build for normal transcription runs; debug builds are primarily for development
and can be slower.

Ensure `~/.local/bin` is on your `PATH` if you use that install location.

## Testing

Run the test suite from the package root:

```bash
swift test
```

Tests cover CLI parsing, invalid option combinations, missing-file handling,
output rendering, atomic writes, and overwrite protection. For manual
benchmarking with a longer audio file, run without committing the file to the
repo (see [spec Test Plan](specs/transcribe.md)).

## Usage

```text
transcribe <audio-file> [options]
```

### Examples

```bash
# Run the optimized release build directly
.build/release/transcribe meeting.mp3

# Transcribe with speaker diarization, output txt + json
transcribe meeting.mp3

# Constrain to two speakers, all output formats
transcribe meeting.mp3 --language en --min-speakers 2 --max-speakers 2 --format all

# Transcript only, no diarization, smaller model
transcribe lecture.m4a --no-diarize --model medium

# Transcript to stdout and JSON to disk
transcribe interview.wav --stdout --format txt,json -o ./transcripts

# Markdown transcript (and JSON) for notes / publishing
transcribe meeting.m4a --format md,json -o ./notes

# Override compute units explicitly
transcribe meeting.mp3 \
  --audio-encoder-compute cpuAndGPU \
  --text-decoder-compute cpuAndGPU \
  --segmenter-compute cpuAndGPU \
  --embedder-compute cpuAndGPU
```

### Options

| Option                            | Description                                                                                      |
|:----------------------------------|:-------------------------------------------------------------------------------------------------|
| `-m, --model <name>`              | Whisper model (default: auto-select for device)                                                  |
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
| `--verbose`                       | Print progress and timing to stderr                                                              |
| `--debug-progress-log`            | Log progress/ETA as plain stderr lines (~1/s) without a TTY (e.g. capture to a file or pipe)     |
| `--no-timing-stats`               | Do not save timing history or use prior runs for ETA hints on the transcription line             |
| `--audio-encoder-compute <units>` | Whisper audio encoder compute units: `auto`, `all`, `cpuOnly`, `cpuAndGPU`, `cpuAndNeuralEngine` |
| `--text-decoder-compute <units>`  | Whisper text decoder compute units: `auto`, `all`, `cpuOnly`, `cpuAndGPU`, `cpuAndNeuralEngine`  |
| `--segmenter-compute <units>`     | SpeakerKit segmenter compute units: `auto`, `all`, `cpuOnly`, `cpuAndGPU`, `cpuAndNeuralEngine`  |
| `--embedder-compute <units>`      | SpeakerKit embedder compute units: `auto`, `all`, `cpuOnly`, `cpuAndGPU`, `cpuAndNeuralEngine`   |

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
**`scripts/folder-action-transcribe.sh`**.

1. Build and install the `transcribe` binary (see [Build and
   Install](#build-and-install)).
2. `chmod +x scripts/folder-action-transcribe.sh`
3. Open **Automator**, create **Folder Action**, choose the watched folder, add
   **Run Shell Script**, shell `/bin/bash`, and pass input **as arguments** to
   the script (path to the checked-in script or a copy).
4. Optionally set environment variables in the shell script step or a wrapper
   (see below).

Full behavior, stable-file wait, and exit codes:
**[specs/folder-action-markdown.md](specs/folder-action-markdown.md)**.

| Variable                       | Meaning                                                                 |
|:-------------------------------|:------------------------------------------------------------------------|
| `TRANSCRIBE_BIN`               | Path to `transcribe` (default: `transcribe` on `PATH`)                  |
| `TRANSCRIBE_OUTPUT_DIR`        | If set, `-o` for all runs; if unset, outputs go next to each input file |
| `TRANSCRIBE_FORMAT`            | `--format` value (default: `md`)                                        |
| `TRANSCRIBE_EXTRA_ARGS`        | Extra CLI flags (space-separated)                                       |
| `TRANSCRIBE_STABLE_SECS`       | Seconds of unchanged file size before running (default: `2`)            |
| `TRANSCRIBE_MAX_STABLE_WAIT`   | Max seconds to wait for a stable file (default: `3600`)                 |
| `TRANSCRIBE_LOCK_FILE`         | If set and `flock` exists, serialize concurrent runs                    |
| `TRANSCRIBE_SKIP_IF_MD_EXISTS` | If `1`, skip when `basename.md` already exists in the output dir        |
| `TRANSCRIBE_LOG`               | Append one log line per run to this file                                |

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

## Releasing

The version is defined in `Sources/transcribe/main.swift` and extracted by the
Makefile. To release a new version:

1. Update `static let version` in `Sources/transcribe/main.swift`
2. Commit the version bump
3. Run `make release` to build and create an annotated git tag
4. Push: `git push && git push origin vX.Y.Z`
5. Run `make changelog` to generate release notes from the commit log

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
