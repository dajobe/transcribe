# Agent instructions

## Non-obvious behaviors

* **WhisperKit model download:** `initializeWhisperKit` must use `downloadBase`
  (not `modelFolder`) in `WhisperKitConfig`. Using `modelFolder` tells
  WhisperKit the models are already present and skips the download, breaking
  first run.
* **Overwrite check runs twice:** Once early in `runPipeline` (fail fast before
  expensive transcription) and again inside `writeOutputs` (guard the actual
  write). This is intentional, not redundant code.

## Versioning and releases

* **Bumping `Transcribe.version` requires creating an annotated tag.** When a
  commit changes `static let version` in `Sources/transcribe/main.swift`, the
  release tag (`vX.Y.Z`) for that version must be created on the same commit.
  Use `make tag` (or `make release`) immediately after the version-bump commit
  lands. Do not move on to the next change without tagging — past releases
  v1.2.0–v1.7.0 were tagged retroactively because this step was skipped.
* **`make verify-tag`** fails when the current version has no matching tag. Run
  it before pushing a branch that touches `Transcribe.version`, and treat a
  failure as a blocker.
* The model name default lives in `Transcribe.defaultModel`; reference that
  constant rather than the literal string when documenting or testing the
  default.

## Environment (CLI)

* **`TRANSCRIBE_ETA_HINTS=0`** disables writing timing history and
  ETA-from-history (same effect as `--eta-hints off`).
  **`TRANSCRIBE_TIMING_STATS=0`** is still honored as a legacy alias
  (`ResolvedSharedOptions.timingStatsEnabled` in
  [`ConfigMerge.swift`](Sources/transcribe/ConfigMerge.swift)).
