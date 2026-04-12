# Folder Action automation and Markdown output

## Overview

This document extends the core product contract in
[transcribe.md](transcribe.md). It specifies:

1. The **`md`** output format for the `transcribe` CLI.
2. The **`scripts/folder-action-transcribe.sh`** helper for macOS **Automator
   Folder Actions** (drop a file into a watched folder and run transcription in
   the background).

It does **not** replace [transcribe.md](transcribe.md); general goals, pipeline
behavior, and exit codes for the binary remain defined there.

## Markdown output format

### Filename

For input `basename.ext`, the Markdown file is **`basename.md`** in the chosen
output directory (see `-o` / `--output-dir`).

### Structure

1. **Title** — A single ATX heading `# …` derived from the input filename
   without extension. `#` characters in the basename are stripped so the heading
   remains valid. If nothing remains, the title is `# Transcript`.

2. **Metadata** — A `## Metadata` section with a bullet list including:
   - **Source:** backtick-wrapped original filename (last path component).
   - **Duration:** audio duration in seconds (one decimal place) with an `s`
     suffix.
   - **Model:** model identifier (backticks).
   - **Language:** present only when the pipeline detected or was given a
     language (backticks).
   - **Diarization:** `on` or `off`.
   - **Speaker strategy:** when diarization is on, `subsegment` or `segment`
     (backticks).
   - **Speakers detected:** when the pipeline provides a count.
   - **transcribe:** tool version (backticks).
   - **Created:** ISO 8601 UTC timestamp (same style as JSON metadata).

3. **Transcript** — A `## Transcript` section, then one block per merged segment
   group (same merge rules as plain **txt**: consecutive segments with the same
   speaker are merged):
   - **With speaker:** `## **SPEAKER** — _HH:MM:SS – HH:MM:SS_` (speaker label
     has `#` removed for heading safety; en dash between times).
   - **Without speaker:** `## _HH:MM:SS – HH:MM:SS_`
   - Blank line, then the paragraph text, then a blank line before the next
     heading.

Trailing newline at end of file matches other text outputs.

### Overwrite

Same as other formats: if `basename.md` exists and **`--overwrite`** is not
passed, the run fails with output write exit code (see
[transcribe.md](transcribe.md) / README exit table).

### Relationship to `txt`

The transcript **body** follows the same merging and time-range logic as
**txt**; Markdown adds headings, metadata, and inline emphasis for times.

## CLI

### `--format`

Valid tokens include **`md`**. Comma-separated lists behave as today
(deduplicated, order preserved).

### `all`

Expands to **`txt`**, **`json`**, **`srt`**, **`vtt`**, **`md`** (in that
order).

### `--stdout`

Only applies to **`txt`**. Markdown is always written as **`basename.md`** when
`md` is requested; it is never written to stdout.

## Folder Action script

**Path:** `scripts/folder-action-transcribe.sh`

**Optional wrapper:** `scripts/folder-script.sh` is an example Automator driver
that sets log/output paths, `TRANSCRIBE_BIN`, and `TRANSCRIBE_LOCK_FILE`, then
invokes `folder-action-transcribe.sh` from the **same directory** as the wrapper
(resolved via `BASH_SOURCE`). Edit the `root_dir` / paths inside for your
machine; `chmod +x` both scripts.

**Invocation:** A single argument: the POSIX path to the file that was added
(Automator “Folder Action receives files and folders added to …” should pass
each new item as an argument).

### Behavior

1. **Stable file wait** — Folder Actions can run before a copy finishes. The
   script polls file size (macOS `stat -f %z`) once per second. If the size is
   unchanged for **`TRANSCRIBE_STABLE_SECS`** consecutive seconds (default
   **2**), the file is treated as stable. If **`TRANSCRIBE_MAX_STABLE_WAIT`**
   seconds (default **3600**) elapse without stability, the script exits **0**
   without invoking `transcribe` (avoids infinite wait on streaming writes).

2. **Extension allowlist** — Process only files whose extension matches the
   supported set documented with the CLI (see
   [AudioLoader.supportedFormats](../Sources/transcribe/AudioLoader.swift)):
   **`mp3`**, **`wav`**, **`m4a`**, **`flac`**, **`aiff`**, **`caf`**
   (case-insensitive). Other extensions: exit **0** (skip).

3. **Ignores** — Skip if the basename starts with **`.`** (hidden), or ends with
   **`.tmp`**.

4. **Skip if output exists** — If **`TRANSCRIBE_SKIP_IF_MD_EXISTS`** is **`1`**
   and **`basename.md`** already exists in the resolved output directory, exit
   **0** without running `transcribe`.

5. **Binary** — **`TRANSCRIBE_BIN`** (default **`transcribe`**, resolved via
   `PATH`). Use an absolute path if Automator’s environment has no `PATH` to
   your install (e.g. `~/.local/bin/transcribe`).

6. **Output directory** — If **`TRANSCRIBE_OUTPUT_DIR`** is unset or empty, pass
   **`-o "$(dirname "$file")"`** (outputs next to the source file). If set, pass
   **`-o "$TRANSCRIBE_OUTPUT_DIR"`** (all transcripts go to that folder).

7. **Format** — **`TRANSCRIBE_FORMAT`** (default **`md`**). Passed to
   **`--format`**.

8. **Extra CLI arguments** — **`TRANSCRIBE_EXTRA_ARGS`**: optional
   space-separated extra flags appended after `--format` (e.g. `--no-diarize
   --language en`). Users must not pass a second `--format` unless they override
   intentionally.

9. **Serialization** — If **`flock`** is available **and**
   **`TRANSCRIBE_LOCK_FILE`** is non-empty, the script runs `transcribe` under
   **`flock "$TRANSCRIBE_LOCK_FILE"`** so concurrent drops do not overlap GPU
   work. If **`flock`** is missing, the script runs without locking and logs a
   warning to stderr once.

10. **Logging** — If **`TRANSCRIBE_LOG`** is set, append one line per invocation
    (timestamp, path, exit status).

### Exit codes

| Exit    | Meaning                                                                                          |
|:--------|:-------------------------------------------------------------------------------------------------|
| **0**   | Skipped (non-audio, hidden, unstable wait timeout, skip-if-md, etc.) or **transcribe** succeeded |
| **≠ 0** | **transcribe** failed (same exit code as the child process when possible)                        |

### Automator

- Workflow type: **Folder Action** in Automator.
- Action: **Run Shell Script**, shell **`/bin/bash`**, **Pass input:** as
  arguments (or “as arguments” depending on Automator version).
- Pass the script’s path or embed a call to the checked-in script.

Because copies may be incomplete on first trigger, **stable file wait** is
required; do not rely on a fixed `sleep` alone.

## Non-goals (this spec)

- A native macOS menu-bar app or **FSEvents** daemon (future work).
- App Store sandboxing and notarization details.

## Future work

- Splitting a **`TranscribeCore`** library target from the CLI for direct
  linking by a GUI (progress streams, cancellation, optional long-lived model
  session). See **[library-embedding.md](library-embedding.md)**;
  [transcribe.md](transcribe.md) non-goals still apply to the core shipping
  artifact until that work lands.
