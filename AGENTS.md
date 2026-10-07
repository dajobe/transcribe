# Agent instructions

## Non-obvious behaviors

* **WhisperKit model download:** `initializeWhisperKit` must use `downloadBase`
  (not `modelFolder`) in `WhisperKitConfig`. Using `modelFolder` tells
  WhisperKit the models are already present and skips the download, breaking
  first run.
* **Overwrite check runs twice:** Once early in `runPipeline` (fail fast before
  expensive transcription) and again inside `writeOutputs` (guard the actual
  write). This is intentional, not redundant code.
* **State lives in a SQLite database:** since 3.0.0, managed canonical
  transcripts, speaker profiles, and both ledgers live in `state.db` in the
  state directory (`StateDatabase`, schema in `StateDatabase.schemaV1`), not in
  JSON files; managed documents are addressed by ID, and only portable
  `.transcript.json` files are addressed by path. The first open of a directory
  holding 2.x JSON state migrates it one way and archives the originals under
  `migrated-v1/`. Tests must always point `XDG_STATE_HOME` at a fresh temporary
  directory, and experiments must use an isolated `XDG_STATE_HOME`: the real
  state directory is production data, and opening it with a development build
  can migrate or modify it.

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
  [`ConfigMerge.swift`](Sources/transcribe/ConfigMerge.swift)). `--stateless`
  also disables both, because it never opens the state database.
