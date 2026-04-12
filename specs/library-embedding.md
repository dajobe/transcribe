# Library embedding and GUI integration (future work)

## Overview

This document describes **planned** directions for making `transcribe` usable as
a **Swift library** linked by a native GUI or other host process. It is **not**
a shipping contract: the [Package.swift](../Package.swift) layout today is a
**single executable target** only.

The core product spec [transcribe.md](transcribe.md) lists GUI and daemon as
**non-goals** for the CLI product itself; this spec records how that boundary
could evolve **without** duplicating pipeline logic in a second app.

## Motivation

- A **GUI** (menu bar, document window, or drop target) should call into
  transcription **in-process** for lower overhead than spawning the CLI for
  every file, and for **cancellation** and **fine-grained progress** that map
  naturally to SwiftUI or AppKit.
- **Shelling out** to `transcribe` remains valid (Folder Actions, scripts); the
  library path is an **additional** integration surface.

## Proposed package layout

| Target                          | Responsibility                                                                                                                                                                                                                                                                                                                                                                                                                 |
|:--------------------------------|:-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`TranscribeCore`** (name TBD) | **Library**: [`TranscriptionPipeline.swift`](../Sources/transcribe/TranscriptionPipeline.swift), [`OutputWriter.swift`](../Sources/transcribe/OutputWriter.swift), [`TranscriptModels.swift`](../Sources/transcribe/TranscriptModels.swift), [`AudioLoader.swift`](../Sources/transcribe/AudioLoader.swift), [`Errors.swift`](../Sources/transcribe/Errors.swift), compute/options helpers, timing store if still shared, etc. |
| **`transcribe`**                | **Thin executable**: [ArgumentParser](https://github.com/apple/swift-argument-parser) parses flags → builds a configuration value → calls the library → maps [`TranscribeError`](../Sources/transcribe/Errors.swift) to process exit codes and stderr strings.                                                                                                                                                                 |
| **`transcribeTests`**           | Depends on the **library** target so unit tests do not require the executable’s `main`.                                                                                                                                                                                                                                                                                                                                        |

Refactoring should move types and functions without changing observable CLI
behavior (same defaults, same output files, same exit codes).

## Public API shape (sketch)

- Expose a **single async entry point**, for example:

`runTranscription(configuration:) async throws -> TranscriptionOutput`

(or a richer result type that includes
[`PhaseTimings`](../Sources/transcribe/PhaseTimings.swift) and write timings),
where `configuration` carries paths, model name, language, diarization flags,
compute options, and output format list — mirroring what
[`runPipeline`](../Sources/transcribe/main.swift) assembles today.

- Surface failures as **`TranscribeError`** (or a small set of typed errors) so
  a GUI can show alerts without parsing stderr.

## Progress and logging

Today [`LiveProgress`](../Sources/transcribe/LiveProgress.swift) and
[`VerboseLogger`](../Sources/transcribe/VerboseLog.swift) assume a **TTY or
line-oriented stderr** consumer.

For a GUI library:

- Introduce a **progress channel** the pipeline can emit on: e.g.
  `AsyncStream<TranscriptionProgress>` or a small **protocol** (`phaseStarted`,
  `fractionComplete`, ETA fields) implemented by a view model.
- Allow **injecting a log handler** (`os_log`, file, or no-op) instead of
  hard-coding stderr.

## Cancellation

Long runs should respect **`Task.checkCancellation()`** (or an explicit
cancellation token) at well-defined await points inside the pipeline and
WhisperKit calls where supported, so a **Cancel** action can stop work cleanly
without leaving partial output inconsistent with
[`writeOutputs`](../Sources/transcribe/OutputWriter.swift) contracts (or
cancellation must be defined to abort before write).

## Model lifecycle (optional optimization)

The CLI **loads WhisperKit once per invocation**. A GUI may batch many files and
benefit from **one** loaded model instance:

- Expose an optional **session** or **service** type holding a `WhisperKit`
  instance with explicit **`warmup`** / **`release`** (or `deinit`), without
  complicating the default **one-shot** API used by the CLI.

## Documentation

When the library target exists:

- Add a short **“Embedding”** or **“Using as a library”** section in the README
  (or a dedicated doc) with public types and a minimal code sample.

## Non-goals (this spec)

- Defining a specific GUI framework (SwiftUI vs AppKit) or HIG.
- App Store sandboxing, notarization, or entitlement matrices.
- Replacing the CLI or Folder Action workflows; they remain first-class operator
  paths.

## References

- [transcribe.md](transcribe.md) — product goals and CLI contract.
- [folder-action-markdown.md](folder-action-markdown.md) — automation without a
  GUI.
