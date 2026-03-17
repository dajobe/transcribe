# transcribe

A macOS command-line tool for local meeting transcription with speaker
diarization. Combines [WhisperKit](https://github.com/argmaxinc/WhisperKit)
for speech-to-text and SpeakerKit for speaker diarization into a single
pipeline that runs entirely on-device on Apple Silicon.

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

## Usage

```text
transcribe <audio-file> [options]
```

### Examples

```bash
# Transcribe with speaker diarization, output txt + json
transcribe meeting.mp3

# Constrain to two speakers, all output formats
transcribe meeting.mp3 --language en --min-speakers 2 --max-speakers 2 --format all

# Transcript only, no diarization, smaller model
transcribe lecture.m4a --no-diarize --model medium

# Transcript to stdout and JSON to disk
transcribe interview.wav --stdout --format txt,json -o ./transcripts
```

### Options

| Option                    | Description                                                                                |
|---------------------------|--------------------------------------------------------------------------------------------|
| `-m, --model <name>`      | Whisper model (default: `large-v3`)                                                        |
| `-l, --language <code>`   | Language code (default: auto-detect)                                                       |
| `-o, --output-dir <path>` | Output directory (default: `.`)                                                            |
| `-f, --format <fmt>`      | Output formats, comma-separated: `txt`, `json`, `srt`, `vtt`, `all` (default: `txt,json`) |
| `--stdout`                | Write transcript text to stdout instead of a file                                          |
| `--min-speakers <n>`      | Minimum speakers for diarization                                                           |
| `--max-speakers <n>`      | Maximum speakers for diarization                                                           |
| `--no-diarize`            | Disable speaker diarization                                                                |
| `--speaker-strategy <s>`  | Speaker merge strategy: `subsegment` or `segment` (default: `subsegment`)                  |
| `--model-dir <path>`      | Model cache directory (default: `~/.cache/transcribe`)                                     |
| `--overwrite`             | Replace existing output files                                                              |
| `--verbose`               | Print progress and timing to stderr                                                        |

### Supported Audio Formats

`mp3`, `wav`, `m4a`, `flac`

## Output

Given `meeting.mp3`, the tool writes:

- `meeting.txt` — human-readable transcript with speaker labels and
  timestamps
- `meeting.json` — machine-readable transcript preserving segment boundaries
- `meeting.srt` — SubRip subtitle format
- `meeting.vtt` — WebVTT subtitle format

Which files are written depends on `--format`.

### Text output

```text
SPEAKER_0 [00:00:00 - 00:00:12]
Welcome, thanks for joining. I wanted to start by talking about
the infrastructure migration timeline.

SPEAKER_1 [00:00:13 - 00:00:28]
Sure, happy to be here. We've been looking at the Q2 window for
the cutover, but there are some dependencies I want to flag.
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
    "transcribe_version": "0.1.0",
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
|------|------------------------------------------|
| 0    | Success                                  |
| 1    | Runtime failure                          |
| 2    | Invalid CLI usage                        |
| 3    | Input file problem                       |
| 4    | Model download or initialization failure |
| 5    | Output write failure                     |

## License

TBD
