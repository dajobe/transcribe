# Filename-derived recording times and session basenames

## Overview

This document extends [directory-input.md](directory-input.md) and the core
product contract in [transcribe.md](transcribe.md). It specifies two automations
that let `transcribe` recover useful metadata from filenames when audio
containers do not carry trustworthy timestamps, and that pick meaningful output
basenames when an input directory's filenames share a common prefix.

It does not replace either document; embedded-metadata trust rules, session
grouping, output formats, and exit codes remain defined there.

## Motivation

Several audio export pipelines rewrite the M4A `creation_time` atom on export
(notably iOS Voice Memos when files leave the app via Files / iCloud Drive), so
a directory of clips arrives with its embedded recording timestamps clustered at
the export moment rather than the true recording moments. The 1.5.0 trust check
(see [directory-input.md](directory-input.md)) detects this case and falls back
to filename sort with session splitting disabled, but it cannot recover real
recording times — the user is left to either rewrite the metadata externally or
accept a single concatenated transcript.

Users routinely encode useful information in their filenames: a leading time
prefix (e.g. `09:48 …`), a sequence indicator (`part 1`, `part 2`), or a shared
label across clips that belong to the same recording. This document specifies
how `transcribe` should read that information so the common workflow needs no
audio-file mutation and produces meaningful output filenames automatically.

## Filename time-prefix recovery

### Recognised patterns

When the requested sort is `recorded` and the trust check fails (see
[directory-input.md → Recorded-date trust check](directory-input.md#recorded-date-trust-check-voice-memos-export)),
`transcribe` parses each clip's filename for a leading time prefix. Patterns
recognised at the start of the filename, after any leading whitespace,
case-insensitive:

| Example                 | Interpretation                    |
|:------------------------|:----------------------------------|
| `09:48 …`               | HH:MM, file's mtime date          |
| `09:48:00 …`            | HH:MM:SS, file's mtime date       |
| `09-48 …`               | HH-MM, filesystem-safe variant    |
| `09-48-00 …`            | HH-MM-SS, filesystem-safe variant |
| `0948_…`                | HHMM with underscore separator    |
| `094800_…`              | HHMMSS with underscore separator  |
| `2026-01-15 09:48 …`    | full date + HH:MM                 |
| `2026-01-15T09:48:00 …` | ISO-8601-like                     |

Time-only forms (no explicit date) are combined with the file's mtime date
interpreted in the file's local timezone. This is correct in the common case
where recordings are processed on the day they were captured, and is documented
as a known limitation for cross-day workflows. Users with cross-day collections
should use a date-prefixed form.

A parsed prefix is rejected (treated as no prefix) if any of the following hold:

- HH ∉ [0, 23]
- MM ∉ [0, 59]
- SS ∉ [0, 59]
- The character following the prefix is alphanumeric (so `1.50` does not parse
  as 01:50, and `2024-q3.m4a` does not match the date form).

### Recovery rule

`transcribe` performs recovery iff:

1. The requested sort is `recorded`.
2. Either (a) the 1.5.0 trust check on embedded `creation_time` returned a
   downgrade, OR (b) no clip in the directory has any embedded recorded-at
   value at all (a directory of files where the export pipeline didn't
   write `creation_time` reliably). Both cases mean the embedded data is
   not usable for ordering.
3. Every clip in the directory has a parseable filename time prefix.
4. `--no-filename-time-recovery` was not supplied.

When recovery applies, each clip's `recordedAt` is set to the filename-derived
value and the synthesized clip set is fed back through the trust check. On a
second pass-through that succeeds, `transcribe` proceeds with `recorded` sort
and gap-based session splitting using the recovered times. If recovery is
impossible — any clip lacks a parseable prefix — `transcribe` declines recovery
and falls back to the existing 1.5.0 behaviour (sort by filename, splitting
disabled). In both cases the verbose log records the decision and the per-clip
filename parse results, so the user can see exactly which files declined to
parse.

### Example

Imagine a directory `meetings/` containing four clips. Their embedded
`creation_time` atoms were reset by export and all read identical, but the
filenames carry the original recording times:

```text
meetings/
  09:00 morning standup.m4a
  09:15 design review part 1.m4a
  09:15 design review part 2.m4a
  10:30 customer call.m4a
```

With `transcribe meetings/ --verbose --input-sort=recorded`:

1. Embedded times fail the trust check.
2. All four filenames have a parseable `HH:MM` prefix.
3. Recovery activates; `recordedAt` is set to today's date at 09:00, 09:15,
   09:15, 10:30 in local time.
4. The trust check passes on the recovered set (spread = 1 h 30 min, longest
   clip ≪ 1 h 30 min).
5. Session splitting runs; the gap between 09:15-design-review (end) and
   10:30-customer-call exceeds the threshold, so two sessions result.

## Common-prefix session basename

When a session contains multiple clips whose filenames share a meaningful
prefix, `transcribe` derives the per-session output basename from that prefix
instead of the existing `<dir> - Recording N` pattern.

### Algorithm

For each session of *N* clips, where *N* ≥ 2:

1. Compute the longest common prefix of all clip basenames (filename minus
   extension).
2. Strip any trailing whitespace and common sequence-marker suffixes from the
   prefix's right side. Recognised markers (matched right-to-left, repeatedly):
   the literal word `part`, an opening parenthesis, hyphens, underscores, and a
   trailing zero (so `… part 0`, `… part`, `… (`, `… -`, `… _` all collapse).
3. Trim trailing whitespace and stray punctuation.
4. Accept the prefix iff at least 8 characters remain AND it represents ≥ 30 %
   of the shortest basename in the session. This rejects degenerate
   single-letter common prefixes.
5. If accepted, the prefix is the session basename. Otherwise fall back to the
   directory-derived basename + `" - Recording N"` (or `Recording N` when no
   usable directory name exists).

### Single-clip sessions

A multi-session directory may produce a session of just one clip. In that case
`transcribe` uses the clip's own basename (filename without extension), not the
directory name. This matches the single-file pipeline's behaviour.

### Override precedence

`--output-prefix <name>` continues to take precedence over both the
common-prefix derivation and the directory-derived fallback. With multiple
sessions and an explicit prefix the existing `"<prefix> - Recording N"` pattern
applies unchanged.

A `--no-auto-session-basename` opt-out is provided for users who want the
previous `"<dir> - Recording N"` behaviour.

### Examples

**Common prefix accepted.** A directory `talks/` containing:

```text
talks/
  morning keynote part 1.m4a
  morning keynote part 2.m4a
  morning keynote part 3.m4a
```

→ output basename `morning keynote` (single session; common prefix strips ` part
` suffix).

**Common prefix rejected.** A directory `office-day/` containing:

```text
office-day/
  Foo Cafe.m4a
  Bar Park.m4a
```

→ output basename `office-day` (no usable prefix; falls back to directory).

**Single-clip multi-session run.** A directory yielding two sessions, each one
clip:

```text
office-day/
  09:00 keynote.m4a
  14:30 q-and-a.m4a
```

→ output basenames `09:00 keynote` and `14:30 q-and-a` (each session's basename
is its single clip's filename).

**Override.** With `--output-prefix daily-notes` set on the same example,
basenames become `daily-notes - Recording 1` and `daily-notes - Recording 2`.

## Recommended naming convention

To get the most out of both automations, name audio clips so that:

1. **Each filename starts with a recording time prefix.** Use `HH:MM` (24-hour,
   colon, space) for same-day collections; use `YYYY-MM-DD HH:MM` when clips
   span multiple days. Two-digit hours are recommended (`09:00`, not `9:00`) so
   filenames sort correctly even if the user falls back to natural-sort. Both
   forms parse, but zero-padded hours are robust under all sort modes.
2. **Clips of one session share a stable label after the time prefix.** When a
   recording is broken into parts, use the same label across parts and add `part
   1`, `part 2`, … as a suffix. The common-prefix derivation strips `part N`
   markers automatically.
3. **All clips in a directory follow the same convention.** Recovery declines
   when even one clip lacks a parseable time prefix, so a single un-renamed file
   blocks recovery for the whole directory.

### Good

```text
office-day/
  09:00 keynote.m4a
  09:30 design review part 1.m4a
  09:30 design review part 2.m4a
  09:30 design review part 3.m4a
  11:00 customer call.m4a
```

Result: three sessions, basenames `09:00 keynote`, `09:30 design review`, `11:00
customer call`. No metadata rewrite needed.

### Acceptable, less ideal

```text
office-day/
  9:00 keynote.m4a              # parses fine, but sorts after `10:00 …`
                                # if recovery later declines
```

Two-digit hours are safer.

### Avoid

```text
office-day/
  09:00 keynote.m4a
  random_thoughts.m4a           # un-prefixed; blocks recovery for the whole dir
  morning standup.m4a           # ditto
```

```text
office-day/
  Recording 1.m4a               # default Voice Memos default; no prefix
  Recording 2.m4a
```

```text
office-day/
  1.50 talk.m4a                 # `.` separator in non-time context;
                                # rejected by the validity check, but
                                # confusing for humans — prefer `09:30`
```

For Voice Memos users specifically: after exporting, rename each clip with the
time shown in the iOS app's "All Recordings" list. The app displays HH:MM next
to each recording; copy that as the filename prefix and keep the rest of the
auto-generated label (or replace with your own). Both batches of automation then
handle the rest.

## CLI surface

Two opt-out flags:

| Option                        | Effect                                                                                                                              |
|:------------------------------|:------------------------------------------------------------------------------------------------------------------------------------|
| `--no-filename-time-recovery` | Disable filename time-prefix recovery; fall back to the 1.5.0 behaviour (sort=name, splitting disabled) when the trust check fails. |
| `--no-auto-session-basename`  | Disable common-prefix basenames; always use `<dir> - Recording N` (or `Recording N`).                                               |

Both default to off (i.e. recovery and auto-basenames are enabled).

## Verbose logging

When recovery activates, `--verbose` adds lines like:

```text
filename time recovery: parsed 4/4 clips, using sort=recorded
  parsed: 09:00 morning standup.m4a -> 2026-01-15T09:00:00-08:00
  parsed: 09:15 design review part 1.m4a -> 2026-01-15T09:15:00-08:00
  ...
```

When recovery declines for mixed input, `--verbose` enumerates the clips that
failed to parse:

```text
filename time recovery: 3/4 clips parsed; recovery declines (mixed)
  unparsed: random_recording.m4a
```

When the auto-session-basename derives a name, `--verbose` notes the choice:

```text
session 1/2 basename: derived 'morning keynote' from 3 clips' common prefix
session 2/2 basename: directory fallback 'meetings - Recording 2'
```

## Exit codes

No new exit codes. Filename-recovery failures are non-fatal — the run continues
with the existing 1.5.0 fallback.

## Compatibility notes

- **Single-file invocations** are unchanged.
- **Directories with no filename time prefixes** behave exactly as in 1.5.0:
  trust check fails, sort demotes to `name`, splitting disabled.
- **Directories with filename time prefixes that already pass the trust check
  via embedded metadata** see no change — recovery only runs after the trust
  check fails.
- **Common-prefix basename** only kicks in when at least two clips in a session
  share a meaningful (≥ 8 char, ≥ 30 %) prefix. Most existing workflows whose
  filenames are diverse see the existing `<dir> - Recording N` behaviour.

## Code touchpoints

| File                                             | Role                                                                                                                                               |
|:-------------------------------------------------|:---------------------------------------------------------------------------------------------------------------------------------------------------|
| `Sources/transcribe/InputResolver.swift`         | New `parseFilenameRecordedAt(filename:fileMtime:)`; recovery hook in `resolve(...)`; updated `sessionBasenames(...)` for common-prefix derivation. |
| `Sources/transcribe/main.swift`                  | `--no-filename-time-recovery` and `--no-auto-session-basename` flags; plumbed through to `InputResolver`.                                          |
| `Tests/transcribeTests/InputResolverTests.swift` | Filename-parser unit tests; recovery integration tests; common-prefix basename tests.                                                              |
| `Tests/transcribeTests/CLITests.swift`           | Argument-parsing tests for both new flags.                                                                                                         |

## Versioning

| Version | Change                                                                                                                                                                                                                                                                             |
|:--------|:-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1.6.0   | Filename time-prefix recovery layered on top of the 1.5.0 trust check; common-prefix session basenames replace `<dir> - Recording N` when a session's clips share a meaningful prefix. Both behaviours opt-out via `--no-filename-time-recovery` and `--no-auto-session-basename`. |

## Risks / notes

- **Date inference from mtime.** Time-only filename prefixes attach the file's
  mtime date in local timezone. For recordings processed on a later day, the
  absolute date in JSON metadata will be the processing day rather than the
  recording day. Relative ordering and session gaps within the day are correct.
- **Common-prefix false positives.** The 8-character / 30 % thresholds reject
  most degenerate cases (e.g. `New` matching across unrelated Voice Memos
  defaults). The opt-out flag is the escape hatch.
- **Mixed-prefix directories.** Recovery declines when even one clip fails to
  parse. This avoids ordering disasters but means a single unrenamed file blocks
  recovery for the whole directory. Verbose log names the offender.
- **Backwards compatibility.** Single-file invocations and no-filename-prefix
  directories are unchanged. Existing users see new behaviour only when their
  filenames already carry the time prefix or the shared-prefix pattern this spec
  describes.
