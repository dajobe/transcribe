# Directory input, sort orders, and session splitting

## Overview

This document extends the core product contract in
[transcribe.md](transcribe.md). It specifies how `transcribe` handles a
directory of audio clips via the canonical `dir` source command, the available
ordering policies, and the gap-based splitting that turns a multi-clip directory
into one or more session transcripts.

It does not replace [transcribe.md](transcribe.md); single-file pipeline
behavior, output formats, and exit codes remain defined there.

## Motivation

Voice-memo workflows produce many short clips (e.g. macOS Voice Memos: `New
Recording.m4a`, `New Recording 2.m4a`, …) that the user thinks of as one long
recording or as several distinct sessions captured across a day. Per-file
invocations of `transcribe` lose cross-clip speaker continuity and force the
user to stitch transcripts manually. Pointing `transcribe dir` at the containing
directory is the natural UX.

Sequential clips a user records in one sitting should land in a single
transcript. Clips recorded hours apart almost always represent different
sessions and should produce separate transcripts. The CLI infers this from each
clip's embedded recording timestamp instead of asking the user to label
sessions.

## Command shape

Canonical directory input uses:

```bash
transcribe [global options] dir [dir options] <directory>
```

The root command also keeps a simple directory alias:

```bash
transcribe [global options] <directory>
```

The alias is for straightforward runs only. Directory-specific and batch options
such as `--sort`, `--session-gap`, and filename recovery flags require the
canonical `dir` command.

A relative input (including `.`) is resolved against the current working
directory and standardised, so the directory's last path component is always a
usable name (e.g. running `transcribe dir .` from
`~/voicenotes/2026-may-meeting/` derives the basename `2026-may-meeting`).

### Filtering

When the source argument is a directory, `transcribe`:

- Reads only the **top level** (no recursion into subdirectories).
- Includes files whose extension matches the [supported
  formats](transcribe.md#audio-input) (case-insensitive).
- Skips dotfiles (`.DS_Store`, `._*`).
- Skips entries that are not regular files (subdirectories, symlinks to
  directories).

If no supported audio files remain after filtering, the run fails with exit code
`3` and a clear stderr message.

## Sort order (`--sort` / `--input-sort`)

Directory contents are concatenated in the order produced by `--sort`, default
`recorded`. The older `--input-sort` spelling remains accepted as an alias.

| Mode       | Primary key                                           | Tiebreak                          |
|:-----------|:------------------------------------------------------|:----------------------------------|
| `recorded` | Embedded recording timestamp from the audio container | mtime, then natural-sort filename |
| `name`     | Natural-sort filename (numeric-aware)                 | —                                 |
| `mtime`    | File modification time                                | natural-sort filename             |

### Recorded timestamp source

`recorded` uses AVFoundation's `AVAsset.load(.creationDate)` async property. For
MPEG-4 / M4A this corresponds to the `creation_time` atom in the `mvhd` / `mdhd`
boxes.

When a clip's container has no creation date (or AVFoundation rejects the file),
the entry falls back to its mtime, then to natural-sort filename. This produces
a deterministic order even for mixed-format directories.

### Recorded-date trust check (Voice Memos export)

Apple's Voice Memos app rewrites the M4A `creation_time` atom to "now" when
files are exported via Files / iCloud Drive. The result is a directory of clips
with timestamps clustered within a few seconds — useless for ordering.

When `--sort=recorded` is in effect, `transcribe` runs a trust check before
sorting:

```
spread = max(recorded_at_i) - min(recorded_at_j)   # over clips with recorded_at set
if spread < max(duration_i over clips that have a duration):
    fall back to sort=name, disable session splitting, and emit a warning
```

The reasoning: for sequentially-recorded clips, the next clip's recorded-at must
start at least `duration_i` seconds after the current clip's recorded-at, so the
spread of all recorded-at values must be ≥ the longest clip's duration. A
smaller spread cannot reflect real recording starts.

When the trust check fails the same data also can't be trusted for
`--session-gap`, so session splitting is disabled and the directory is treated
as a single session.

Fallback orders by natural-sort filename instead and emits a warning to stderr
identifying the mismatch:

```text
Warning: Recorded timestamps span only 4s across 8 clips
(longest clip is 1m 27s). The container creation_time was likely
reset during export and does not reflect the original recording time.
Falling back to filename sort. Pass --sort name explicitly to
silence this warning.
```

The trust check only runs when the user requested `.recorded` (default).
Explicit `--sort name` or `--sort mtime` are honoured as-is.

### Stability

All three modes are stable across runs given the same input — there is no hidden
randomisation. `recorded` and `mtime` use the file's underlying metadata; `name`
uses the filename only.

## Session splitting (`--session-gap`)

Directory inputs are split into one or more sessions whenever adjacent clips
have a recorded-at gap larger than the configured threshold:

- `--session-gap N` (minutes, default `10`).
- `--session-gap 0` disables splitting (single session per directory).

### Gap calculation

For each adjacent clip pair `(clip_i, clip_{i+1})`:

```
end_i = recordedAt_i + duration_i
gap   = recordedAt_{i+1} - end_i
```

The pair starts a new session iff:

- `recordedAt_i` and `recordedAt_{i+1}` are both available, AND
- `duration_i` is available (probed via AVAsset.load(.duration)), AND
- `gap > sessionGapSeconds`.

If any of these is missing, the clip joins the previous session (conservative:
avoids spurious splits when metadata is unreliable). The `--session-gap` value
applies regardless of `--sort` mode — the split decision uses recorded-at
metadata rather than the chosen sort key.

### Output naming per session

For a directory input with N sessions and base name `B` (the directory's last
path component, or `--output-prefix` when set):

| N   | B usable                  | Basenames                               |
|:----|:--------------------------|:----------------------------------------|
| 1   | yes                       | `B`                                     |
| 1   | no (e.g. `.`, `/`, empty) | `Recording 1`                           |
| ≥ 2 | yes                       | `B - Recording 1`, …, `B - Recording N` |
| ≥ 2 | no                        | `Recording 1`, …, `Recording N`         |

Each session writes one set of output files (`txt`, `json`, etc.) per the
existing format rules. Existing-output checks run per session before any heavy
work.

### Pipeline reuse across sessions

WhisperKit and (when diarization is enabled) SpeakerKit are loaded once per
invocation. Each detected session is decoded, transcribed, and diarized
independently using those shared model instances. Speaker IDs within a session
are consistent across its clips; speaker IDs between sessions are independent.

### JSON metadata per session

Each session's JSON output sets:

- `audio_file`: the directory's basename for that session (e.g.
  `2026-may-meeting`).
- `audio_files`: an ordered array of the source filenames concatenated for that
  session. The field is omitted for single-file inputs.

### Markdown metadata per session

The Markdown `## Metadata` block gains a `**Sources:**` bullet listing the
source filenames in concat order, when the input was a directory.

### Inter-clip silence padding

Within a session, ~200 ms of digital silence is inserted between consecutive
clips to smooth Whisper's VAD chunking across abrupt joins. No padding is
inserted before the first or after the last clip of a session, and there is no
padding across session boundaries.

## Verbose logging

`--verbose` emits one line per clip showing the sort keys actually used,
followed by per-pair gap analysis, e.g.:

```text
sort=recorded: per-clip keys (in final order)
  sort key: New Recording.m4a recorded=2026-05-06T09:14:22Z mtime=2026-05-06T09:18:03Z
  sort key: New Recording 2.m4a recorded=2026-05-06T09:32:11Z mtime=2026-05-06T09:33:48Z
gap: New Recording.m4a -> New Recording 2.m4a = 13m 49s (>10m 0s threshold) -> new session
sessions: 2 (1, 1 clips each)
```

When the recorded timestamp is missing for a clip and the sort mode is
`recorded`, the per-clip line includes a `(fell back to mtime)` note. When
metadata is insufficient to compute a gap, the gap line shows `unknown (missing
metadata; same session)`.

## Timing records

Each session emits its own row in the timing JSONL (see
[timing-history.md](timing-history.md)). The convention:

- `input_basename` is the session's output basename (e.g. `2026-may-meeting -
  Recording 2`).
- `file_bytes` is the sum across that session's source files.
- `audio_duration_s` is the session's total decoded audio duration.
- `whisper_init_ms` and `speaker_init_ms` are charged to the **first** session
  of an invocation; subsequent sessions have those phases set to zero,
  reflecting the shared model load.

## Exit codes (additions)

No new exit codes. The directory path uses existing codes:

- `2` — invalid usage: `--session-gap` < 0.
- `3` — input file: directory does not exist, is not readable, or contains no
  supported audio files.

## Compatibility notes

- Single-file invocations use the `file` source command or the root file alias:
  same output filenames, same JSON shape (no `audio_files` key emitted), same
  timing record shape.
- The folder-action helper script (`scripts/folder-action-transcribe.sh`)
  remains a per-file trigger and is not a directory-aware wrapper.
- `--output-prefix` continues to override the basename. With multiple sessions,
  the prefix is the base and each session appends `" - Recording N"`.

## Code touchpoints

| File                                              | Role                                                                                                                                |
|:--------------------------------------------------|:------------------------------------------------------------------------------------------------------------------------------------|
| `Sources/transcribe/InputResolver.swift`          | resolves the positional argument, sorts and probes per-clip metadata, builds `[AudioSession]`, derives per-session basenames.       |
| `Sources/transcribe/SessionGrouper.swift`         | pure session-grouping logic: `groupIntoSessions(clips:maxGapSeconds:logger:)`.                                                      |
| `Sources/transcribe/TranscriptionPipeline.swift`  | `loadModels(...)` + `runSession(preparedAudio:audioLoadMs:models:...)` to share Whisper/SpeakerKit across sessions.                 |
| `Sources/transcribe/OutputWriter.swift`           | `outputBasename(directoryPath:)` standardises relative paths; `audio_files` JSON metadata; markdown `Sources` block.                |
| `Sources/transcribe/CLICommands.swift`            | Root/global option parsing, source-specific `dir` options (`--sort`, `--input-sort`, filename recovery), and batch `--session-gap`. |
| `Sources/transcribe/PipelineRunner.swift`         | Source planning, idempotency checks, dry-run handling, and per-session execution.                                                   |
| `Tests/transcribeTests/InputResolverTests.swift`  | resolver, sort, basenames.                                                                                                          |
| `Tests/transcribeTests/SessionGrouperTests.swift` | gap-grouping algorithm.                                                                                                             |
| `Tests/transcribeTests/CLITests.swift`            | `--sort` / `--input-sort` parsing, `--session-gap` validation, empty/non-audio dir exit codes.                                      |

## Versioning

| Version | Change                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
|:--------|:---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1.3.0   | Initial directory input: top-level audio files concatenated and transcribed as one transcript named after the directory; natural-sort filename order.                                                                                                                                                                                                                                                                                                                |
| 1.4.0   | `--input-sort` with `recorded` (default), `name`, `mtime`. AVAsset-based recorded-date probe with mtime/natural-sort fallback. `make install` target for `$HOME/bin`.                                                                                                                                                                                                                                                                                                |
| 1.5.0   | Verbose sort-key and gap-analysis logging. `--session-gap` (default 10 min) splits directory input into N session transcripts named `<base> - Recording N`. Pipeline refactored to share Whisper/SpeakerKit init across sessions. `outputBasename(directoryPath:)` standardises `.` / `..` so `transcribe .` no longer yields `..txt`. Recorded-date trust check auto-falls-back to filename sort for Voice Memos exports whose `creation_time` was reset on export. |

## Risks / notes

- AVAsset duration probing adds a small startup delay proportional to clip
  count; runs in parallel via `withTaskGroup`.
- Memory peaks per session, not per directory — strict improvement over loading
  the entire directory before transcription.
- Multi-session timing rows require any consumer of the timing history to handle
  multiple records per invocation.
- Speaker continuity across sessions is intentionally not preserved.
  Embedding-level merging across sessions is out of scope; the user expectation
  is that distinct sessions are distinct conversations.
- Whisper hallucinations at clip joins within a session are mitigated by the 200
  ms silence pad; not eliminated.
