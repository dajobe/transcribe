# transcribe: On-Device Meeting Transcription with Speaker Diarization

## Overview

`transcribe` is a macOS command-line tool that combines
[WhisperKit](https://github.com/argmaxinc/WhisperKit) for speech-to-text and
SpeakerKit for speaker diarization into a single local pipeline.

Given an audio file, the tool produces a timestamped transcript with optional
speaker labels. All processing runs on-device on Apple Silicon. The tool must
not require cloud APIs, API keys, Python, or HuggingFace authentication.

## Motivation

Current transcription plus diarization options on macOS are either operationally
heavy or incomplete:

- `whisperx` provides good features but depends on a non-trivial Python
  environment and gated pyannote assets.
- `whisper.cpp` is fast but does not provide built-in diarization.
- `whisperkit-cli` provides strong CoreML-accelerated transcription but does not
  expose diarization as a first-class CLI workflow.

WhisperKit and SpeakerKit already exist in the same Swift package. The missing
piece is a production-quality CLI that wires them together with sensible
defaults and stable output contracts.

## Goals

1. Provide a single binary for batch transcription with optional diarization.
2. Use CoreML acceleration on Apple Silicon.
3. Produce output that is useful for both humans and downstream tooling.
4. Require minimal configuration for the common case of recorded meetings and
   interviews.
5. Keep execution fully local with no cloud dependency surface.

## Non-Goals

- Real-time or streaming transcription.
- A GUI, menu bar app, or background daemon.
- Speaker identification against known voices; only diarization is in scope.
- Cross-platform support.
- Replacing Argmax commercial SDK offerings.
- Summarization, action-item extraction, or any other LLM post-processing.

## Platform and Dependencies

### Runtime Requirements

- macOS 14.0 or later
- Apple Silicon (M1 or later)

### Build Requirements

- Xcode 16.0 or later
- Swift 6 toolchain

### Package Dependencies

Dependencies are vendored through Swift Package Manager:

- `WhisperKit`
- `SpeakerKit`
- `swift-argument-parser`

The runtime must not depend on Python, ffmpeg, Homebrew packages, or external
services.

## User Stories

- As a user, I can run `transcribe meeting.m4a` and receive a transcript plus
  machine-readable JSON.
- As a user, I can force the language or let it auto-detect.
- As a user, I can disable diarization when I only want transcription.
- As a user, I can constrain diarization with minimum and maximum speaker
  counts.
- As a user, I can script the tool in shell pipelines without log noise
  contaminating stdout.
- As a user, I can re-run the tool without re-downloading models on every
  invocation.

## CLI Contract

```text
USAGE: transcribe <audio-file> [options]

ARGUMENTS:
  <audio-file>              Path to the input audio file

OPTIONS:
  -m, --model <name>        Whisper model to use (default: large-v3)
  -l, --language <code>     Language code such as "en"; default is auto-detect
  -o, --output-dir <path>   Directory for output files (default: current directory)
  -f, --format <fmt>        Output formats, comma-separated (default: txt,json)
                            Supported: txt, json, srt, vtt, md, all
  --stdout                  Write the primary transcript to stdout instead of a text file
  --min-speakers <n>        Minimum number of speakers for diarization
  --max-speakers <n>        Maximum number of speakers for diarization
  --no-diarize              Disable diarization and produce transcript-only output
  --speaker-strategy <s>    Speaker merge strategy: subsegment or segment
                            Default: subsegment
  --model-dir <path>        Directory used for downloaded model caches
                            Default: ~/.cache/transcribe
  --overwrite               Replace existing output files
  --verbose                 Print progress, timing, and cache details to stderr
  --version                 Print version and exit
  -h, --help                Show help
```

### Supported Input Formats

At minimum, the tool should accept formats supported by WhisperKit's audio
loading path, expected to include:

- `mp3`
- `wav`
- `m4a`
- `flac`

If support differs in practice, the implementation must reflect actual supported
formats in `--help` output and error messages.

### Argument Semantics

- `--format all` expands to `txt,json,srt,vtt`.
- `--stdout` is only valid when `txt` is requested, either explicitly or through
  `all`.
- `--stdout` writes transcript text to stdout and suppresses the `.txt` file.
- Logs and diagnostics must always go to stderr.
- `--min-speakers` and `--max-speakers` are only valid when diarization is
  enabled.
- If both `--min-speakers` and `--max-speakers` are provided, `min <= max` is
  required.
- If both `--min-speakers` and `--max-speakers` are provided and equal, the tool
  passes a fixed speaker-count hint to SpeakerKit.
- If only one bound is provided, or if `min < max`, the tool runs diarization
  without a fixed count hint and warns when the detected speaker count falls
  outside the requested range.
- If `--max-speakers` is omitted, no upper bound is applied.
- If output files already exist and `--overwrite` is not set, the command must
  fail before starting expensive work.

### Exit Codes

The tool should use stable process exit codes:

- `0`: success
- `1`: runtime failure
- `2`: invalid CLI usage or invalid combination of options
- `3`: input file problem
- `4`: model download or model initialization failure
- `5`: output write failure

## Examples

```bash
# Default behavior: diarize if possible, write txt + json
transcribe meeting.mp3

# Constrain diarization to two speakers and write all output formats
transcribe meeting.mp3 --language en --min-speakers 2 --max-speakers 2 --format all

# Transcript only, smaller model
transcribe lecture.m4a --no-diarize --model medium

# Emit human-readable transcript to stdout and JSON to disk
transcribe interview.wav --stdout --format txt,json -o ./transcripts
```

## Output Contract

### Output File Naming

Given an input file `meeting.mp3` and output directory `./out`, generated files
are:

- `./out/meeting.txt`
- `./out/meeting.json`
- `./out/meeting.srt`
- `./out/meeting.vtt`

The basename is derived from the input filename without its extension.

Writes should be atomic where practical: write to a temporary file in the target
directory, then rename into place.

### Plain Text (`.txt`)

Plain text is intended for humans. Consecutive transcript spans with the same
speaker label should be merged into a single paragraph block for readability.

If diarization is disabled or unavailable, speaker headings should be omitted.

Example with diarization:

```text
SPEAKER_0 [00:00:00 - 00:00:12]
Welcome, thanks for joining. I wanted to start by talking about
the infrastructure migration timeline.

SPEAKER_1 [00:00:13 - 00:00:28]
Sure, happy to be here. We've been looking at the Q2 window for
the cutover, but there are some dependencies I want to flag.
```

Example without diarization:

```text
[00:00:00 - 00:00:12]
Welcome, thanks for joining. I wanted to start by talking about
the infrastructure migration timeline.
```

### JSON (`.json`)

JSON is the stable machine-readable contract and must preserve original segment
boundaries.

Rules:

- Timestamps are floating-point seconds.
- `metadata.created_at` is UTC ISO 8601.
- `speaker` is nullable.
- `words` is optional.
- `warnings` captures non-fatal degradations such as skipped diarization.

Example:

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
      "text": "Welcome, thanks for joining. I wanted to start by talking about the infrastructure migration timeline.",
      "words": [
        { "word": "Welcome,", "start": 0.0, "end": 0.6 },
        { "word": "thanks", "start": 0.7, "end": 1.0 }
      ]
    },
    {
      "speaker": "SPEAKER_1",
      "start": 13.1,
      "end": 28.3,
      "text": "Sure, happy to be here. We've been looking at the Q2 window for the cutover, but there are some dependencies I want to flag."
    }
  ]
}
```

### SRT (`.srt`)

SRT output should prefix each cue with the speaker label when present.

```text
1
00:00:00,000 --> 00:00:12,400
[SPEAKER_0] Welcome, thanks for joining. I wanted to start
by talking about the infrastructure migration timeline.
```

### WebVTT (`.vtt`)

WebVTT output should use speaker voice tags when a speaker label is present.

```text
WEBVTT

00:00:00.000 --> 00:00:12.400
<v SPEAKER_0>Welcome, thanks for joining. I wanted to start
by talking about the infrastructure migration timeline.
```

## Runtime Behavior

### Default Behavior

- The tool attempts diarization unless `--no-diarize` is set.
- The default output formats are `txt,json`.
- The default speaker merge strategy is `subsegment`.
- The default model is `large-v3`.

### Degraded Behavior

The tool should prefer partial success over hard failure when transcription can
still be delivered.

| Condition                                                                                     | Required behavior                                                             |
|:----------------------------------------------------------------------------------------------|:------------------------------------------------------------------------------|
| Audio too short for diarization                                                               | Warn to stderr, skip diarization, continue with transcription-only output     |
| Diarization returns no speakers                                                               | Continue with transcript-only output, set `speaker` to `null`, record warning |
| Diarization returns fewer than `--min-speakers`                                               | Continue with detected count, warn to stderr, record warning                  |
| Diarization returns more than `--max-speakers` when no fixed speaker-count hint was available | Continue with detected count, warn to stderr, record warning                  |
| No speech detected                                                                            | Produce valid empty output files and warn to stderr                           |
| Requested diarization but SpeakerKit unavailable after init failure                           | Fail with exit code `4`                                                       |

### Failure Behavior

| Condition                                        | Required behavior                                                           |
|:-------------------------------------------------|:----------------------------------------------------------------------------|
| Input file does not exist or is unreadable       | Fail with exit code `3` before model initialization                         |
| Unsupported or undecodable audio                 | Fail with exit code `3` and list supported formats if known                 |
| Model download fails                             | Retry once, then fail with exit code `4`                                    |
| Output file already exists without `--overwrite` | Fail with exit code `5` before expensive processing                         |
| Disk full or partial write                       | Fail with exit code `5`; do not leave truncated final output files in place |

## Performance and Caching

### Concurrency

When diarization is enabled, transcription and diarization should run
concurrently because both operate on the same prepared audio but do not depend
on each other.

Use Swift structured concurrency via `async let` or a task group.

### Caching

- Whisper and diarization model assets should be downloaded once and reused.
- `--model-dir` controls the cache root for both model families.
- Subsequent runs should not trigger re-download if the required assets are
  already present.

### Performance Target

The tool should aim for materially faster-than-real-time throughput on typical
Apple Silicon hardware for common meeting recordings, while treating correctness
and operational simplicity as higher priority than benchmark optimization.

The spec does not require a hard benchmark, but verbose output should include
enough timing data to measure real-world performance.

## Logging and Diagnostics

When `--verbose` is set, the tool should emit progress messages to stderr only.

Example:

```text
[00:00] Loading audio: meeting.mp3 (30:47, 16kHz mono)
[00:01] Using model cache: ~/.cache/transcribe
[00:01] Starting transcription...
[00:01] Starting diarization...
[03:42] Transcription complete (213 segments, 4847 words)
[03:48] Diarization complete (2 speakers detected)
[03:48] Merging speaker labels with strategy=subsegment
[03:48] Writing outputs: meeting.txt, meeting.json
[03:48] Done. Total: 3m 48s
```

Suggested diagnostics to include when available:

- audio duration
- detected language
- speaker count
- cache hit vs download
- total processing time
- realtime factor

## High-Level Architecture

```text
Audio File
    |
    v
+---------------------+
| Audio Preparation   |  Load, decode, normalize, resample
| WhisperKit path     |
+----------+----------+
           |
     +-----+-----+
     v           v
+----------+  +----------+
| Whisper  |  | Speaker  |
| text     |  | diarize  |
+-----+----+  +-----+----+
      |             |
      +------+------+ 
             |
             v
+---------------------+
| Merge speaker info  |
| into transcript     |
+----------+----------+
           |
           v
+---------------------+
| Render outputs      |
| txt/json/srt/vtt    |
+---------------------+
```

### Design Decisions

**Single audio load path.** Audio should be decoded once and reused by both
transcription and diarization to avoid redundant work.

**Machine-readable JSON as the source of truth.** Human-readable outputs may
merge or reflow text, but JSON should preserve transcript structure as closely
as possible.

**Graceful degradation.** If diarization is unavailable or weak, transcription
should still succeed whenever possible.

**Readable defaults.** Text output should optimize for meeting-readability,
while JSON optimizes for downstream processing.

## Implementation Notes

The implementation must validate actual WhisperKit and SpeakerKit APIs at build
time. The following sketch is illustrative only.

```swift
import ArgumentParser
import SpeakerKit
import WhisperKit

@main
struct Transcribe: AsyncParsableCommand {
    @Argument(help: "Path to an audio file")
    var audioFile: String

    @Option(name: .shortAndLong)
    var model: String = "large-v3"

    @Option(name: .shortAndLong)
    var language: String?

    @Option
    var minSpeakers: Int?

    @Option
    var maxSpeakers: Int?

    @Flag
    var noDiarize = false

    func run() async throws {
        let audio = try loadAudio(at: audioFile)

        let whisper = try await WhisperKit(
            .init(
                model: model
            )
        )

        if noDiarize {
            let transcript = try await whisper.transcribe(audioArray: audio)
            try writeOutputs(transcript: transcript, diarized: nil)
            return
        }

        let speakerKit = try await SpeakerKit(.init())

        async let transcriptTask = whisper.transcribe(audioArray: audio)
        async let diarizationTask = speakerKit.diarize(
            audioArray: audio,
            minSpeakers: minSpeakers,
            maxSpeakers: maxSpeakers
        )

        let transcript = try await transcriptTask
        let diarization = try await diarizationTask
        let diarized = try diarization.addSpeakerInfo(
            to: transcript,
            strategy: .subsegment
        )

        try writeOutputs(transcript: transcript, diarized: diarized)
    }
}
```

## Packaging and Installation

### Build

```bash
swift build -c release
```

### Install

```bash
cp .build/release/transcribe ~/.local/bin/
```

Support for Homebrew packaging is desirable but out of scope for the first
implementation.

### Package Definition Sketch

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "transcribe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.17.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "transcribe",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
```

## Test Plan

At minimum, the project should cover:

- CLI parsing and invalid option combinations
- Output file naming and overwrite protection
- JSON schema stability
- No-diarize mode
- Diarization fallback behavior
- Empty or no-speech audio
- Short audio where diarization is skipped
- Golden-file tests for txt, json, srt, and vtt output

If fixture size is a concern, short deterministic audio clips should be checked
into the repository and larger manual benchmark files kept out of git.

## Open Questions

- Should `--stdout` emit text only, or should a future version support `json` to
  stdout as well?
- Should the default model remain `large-v3`, or should a smaller default be
  used for startup latency and disk footprint?
- Does WhisperKit expose enough control over model cache location for both
  transcription and diarization assets, or is extra cache management needed?
- Are word timestamps always available for the selected model family, or only
  for some configurations?

## Implementation Readiness

### Implementation Notes

- **Speaker strategies:** The spec names `subsegment` and `segment` but does not
  define their semantics; behavior comes from whatever SpeakerKit exposes.
  Document the chosen strategy behavior in code or README once known.
- **JSON schema:** The JSON example and test plan ("JSON schema stability")
  define the canonical shape. No formal JSON Schema document is required for
  implementation; tests can assert structure.
- **Illustrative sketch:** The Swift code in Implementation Notes is
  intentionally illustrative. Do not assume API names or signatures; validate
  against the actual WhisperKit and SpeakerKit packages.

### Pre-Implementation Spike

Before coding the main implementation, complete the following research and
confirm or update the spec accordingly.

| Spike item                | Goal                                                                                                                                                                                                 | How to verify                                                                                                                                   |
|:--------------------------|:-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|:------------------------------------------------------------------------------------------------------------------------------------------------|
| **Package layout**        | Confirm SpeakerKit is part of the WhisperKit repo and learn exact SPM product/library names.                                                                                                         | Clone WhisperKit, inspect `Package.swift` for targets and products; confirm `SpeakerKit` (or equivalent) exists and is consumable.              |
| **WhisperKit API**        | Learn actual entry points for loading audio, initializing the pipeline, and transcribing.                                                                                                            | Build a minimal Swift app or test that loads audio, creates WhisperKit, runs transcription; note types for audio in/out and segment structure.  |
| **SpeakerKit API**        | Learn diarization entry points, min/max speaker params, and how results are returned (e.g. labels per segment or per time range).                                                                    | Same minimal app: call diarization on the same audio; confirm how speaker labels map to time ranges or segments.                                |
| **Merge / strategy**      | Confirm whether "merge speaker info into transcript" is provided by the library (e.g. `addSpeakerInfo(to:strategy:)`) or must be implemented by aligning segment timestamps with diarization output. | Check WhisperKit/SpeakerKit docs and APIs for any built-in merge; if none, design alignment logic and document in spec or Implementation Notes. |
| **Supported formats**     | List formats WhisperKit actually accepts for its audio loading path.                                                                                                                                 | Run or read WhisperKit code for audio loading (e.g. AVFoundation path); update "Supported Input Formats" and `--help` text to match.            |
| **Model cache location**  | Confirm whether both Whisper and diarization models can be stored under `--model-dir` or if separate or vendor-specific paths apply.                                                                 | Check WhisperKit/SpeakerKit init options and docs for cache/config paths; resolve Open Question on cache and document default.                  |
| **Word-level timestamps** | Determine if word timestamps are always available for the default model (and others) or only in certain configs.                                                                                     | Run transcription with default model; inspect result type for optional `words`; check docs. Update JSON contract or warnings if conditional.    |

Spike deliverables: short notes or a spike doc (in repo or spec) recording
actual types, method names, and any spec or Package.swift updates (e.g.
dependency versions, product names).

## References

- [WhisperKit GitHub](https://github.com/argmaxinc/WhisperKit)
- [Argmax SpeakerKit announcement](https://www.argmaxinc.com/blog/speakerkit)
- [WhisperKit CoreML models](https://huggingface.co/argmaxinc/whisperkit-coreml)
- [swift-argument-parser](https://github.com/apple/swift-argument-parser)
