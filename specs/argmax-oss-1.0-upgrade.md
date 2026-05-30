# Argmax OSS 1.0 upgrade

## Summary

`transcribe` now targets Argmax Open-Source SDK 1.0.0, the renamed successor to
the original WhisperKit package. The repo continues to use the individual
`WhisperKit` and `SpeakerKit` products for local transcription and speaker
diarization.

This is also the release vehicle for `transcribe` 2.5.0.

## Current state

Before this migration, `Package.resolved` pinned:

- package identity: `whisperkit`
- package URL: `https://github.com/argmaxinc/WhisperKit.git`
- version: `0.17.0`

That release introduced SpeakerKit/Pyannote diarization support, which this CLI
uses to add anonymous speaker labels to transcripts.

## Target state

After this migration, SwiftPM should resolve:

- package identity: `argmax-oss-swift`
- package URL: `https://github.com/argmaxinc/argmax-oss-swift.git`
- version: `1.0.0`

The manifest should depend on the `WhisperKit` and `SpeakerKit` products from
the new package identity. The old package URL should no longer appear in
`Package.swift`.

## API migration

Argmax OSS 1.0.0 removes deprecated APIs from the older SpeakerKit lifecycle.
`transcribe` should no longer construct `SpeakerKitModelManager` directly or
initialize `SpeakerKit` with preloaded `PyannoteModels`.

`initializeSpeakerKit` should instead build a `PyannoteConfig` and pass that to
`SpeakerKit(config)`. The migration must preserve existing CLI behavior:

- `--model-dir` remains the shared cache root for WhisperKit and SpeakerKit.
- SpeakerKit downloads missing models on first use.
- SpeakerKit loads eagerly during initialization so setup failures are reported
  before transcription and diarization work begins.
- Preferred compute options are attempted first.
- Fallback compute options keep the existing retry/error behavior.
- Verbose mode still logs the selected SpeakerKit compute settings.

## Verification checklist

Before committing the release:

- Resolve packages and confirm `argmax-oss-swift` 1.0.0 is pinned.
- Build or run focused tests that compile the WhisperKit and SpeakerKit paths.
- Run focused CLI/config tests.
- Run the full Swift test suite.
- Run `git diff --check`.

After committing:

- Create annotated tag `v2.5.0` on the release commit with `make tag`.
- Run `make verify-tag` and treat any failure as a blocker.
