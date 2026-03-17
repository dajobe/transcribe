# Agent instructions

## Non-obvious behaviors

* **WhisperKit model download:** `initializeWhisperKit` must use
  `downloadBase` (not `modelFolder`) in `WhisperKitConfig`. Using
  `modelFolder` tells WhisperKit the models are already present and skips
  the download, breaking first run.
* **Overwrite check runs twice:** Once early in `runPipeline` (fail fast
  before expensive transcription) and again inside `writeOutputs` (guard the
  actual write). This is intentional, not redundant code.
