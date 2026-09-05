# Interactive speaker review and terminal color

## Status and scope

Target release: 2.6.0. Builds on the persistent speaker identities feature
(specs/persistent-speaker-identities.md) in the same release. No SDK, model, or
document schema changes; this is a CLI interaction layer over existing canonical
documents and the profile store.

`transcribe speakers review` becomes an interactive identification session by
default on a terminal. The parameterized subcommands (`confirm`, `clear`,
`rename`, `delete`) remain the scripted path for specific corrections. The
feature also introduces ANSI color for human-facing output across the CLI.

Out of scope: audio playback of sample spans, editing transcript text, curses
style full-screen UI, and any change to matching thresholds or enrollment rules.

## Motivation

Identifying speakers today requires the user to open rendered output, find
utterances for each `SPEAKER_n`, and hand-assemble `speakers confirm` commands
with document paths and profile IDs. The first utterance of a speaker is often a
useless fragment ("Me? Yeah."), so identification needs samples from across the
recording. The interactive session automates exactly this loop.

## User workflow

```bash
transcribe speakers review                 # all saved transcripts needing attention
transcribe speakers review result.transcript.json   # one document
transcribe speakers review --all           # also revisit confirmed speakers
```

For each document with speakers needing attention, the session shows a header
(basename, recording length, speaker count), then prompts one speaker at a time:

```text
meeting-2024-01-02 — 34m, 2 speakers, 1 unidentified

SPEAKER_1  (46 turns, 11m speaking)   suggested: Bob (distance 0.115)
  [00:03:56]  Yeah! Blah blah blah.
  [00:14:02]  I think the foo bar is wrong there because...
  [00:27:45]  Let's pick that up on Monday with the meeting.
Name [Bob], l list profiles, s skip, q quit:
```

Reply semantics:

- Empty input accepts the bracketed suggestion when one exists; with no
  suggestion it skips.
- Any other text is a name. A case-insensitive exact match against existing
  profile names confirms into that profile; otherwise a new profile is created.
  Names that differ only by case therefore cannot create duplicate profiles.
- `l` lists profiles as a numbered menu; entering a number confirms into that
  profile (for names that are ambiguous or hard to type).
- `s` skips this speaker, `q` ends the session. Both apply the decisions already
  made; a skipped or quit speaker is untouched and prompts again next session.

By default the session prompts unidentified, suggested, and automatic speakers;
confirming an automatic match upgrades a guess into a voice example. `--all`
also prompts speakers that are already confirmed, with the current name as the
default, so past mistakes can be corrected in place. Documents where nothing
needs attention are silently passed over (with `--all`, every document with
diarized speakers is visited).

## Command surface

`SpeakerReviewArguments` changes:

- `transcript` becomes optional. Absent, the session walks every readable
  document in `<state>/transcripts/`, newest first. Unreadable documents are
  reported in place and skipped, matching the `transcripts` listing.
- `--all` prompts confirmed speakers too (interactive), or lists them
  (non-interactive).
- `--apply` retains its 2.6.0 scripted meaning: non-interactive, save refreshed
  suggestions and strong automatic matches. `--apply` disables the interactive
  session.
- `--interactive` / `--no-interactive` force the mode. The default is
  interactive when stdin and stdout are both terminals and `--apply` is not
  given; otherwise the read-only table (now also available across all documents
  when `transcript` is absent).

`inspect` and the other `speakers` subcommands are unchanged.

## Sample selection

Shown samples must let a human identify the voice from text alone:

- Take the speaker's segments in transcript order and drop segments with fewer
  than 4 words; if that leaves nothing, fall back to all of the speaker's
  segments.
- Split the remaining list into three consecutive runs of equal length and take
  the longest segment (by word count) from each run, so samples come from the
  beginning, middle, and end of the recording rather than the first rows of the
  transcript.
- Render each sample with its start timestamp, truncated to one terminal line
  (control characters stripped, as elsewhere).

## Applying decisions and locking

Prompting must not hold locks: a session waits on human input for arbitrarily
long, and the document flock would block every concurrent speaker command. The
session therefore collects decisions per document and applies them only after
the last prompt for that document (or at `q`), inside the existing
`withDocumentLock` with the standard document-then-profile lock order:

1. Reload the document under the lock (it may have changed since the prompts
   were computed).
2. Skip any decision whose local speaker no longer has an embedding, with a
   warning.
3. Confirm each decision through `SpeakerProfileStore.confirm`, exactly as the
   `confirm` subcommand does, then save the document once.

Consequences: enrollment and independence rules are identical to explicit
`confirm`; a decision raced by a concurrent edit degrades to a warning, never a
lost write; and interactive review writes nothing unless the user confirmed at
least one speaker in that document.

## Terminal color

New `Terminal` support in `Sources/transcribe/Terminal.swift`:

- Color is enabled per stream when that stream is a terminal (`isatty`), `TERM`
  is set and not `dumb`, and `NO_COLOR` is unset (any value disables, per
  no-color.org). `CLICOLOR_FORCE=1` forces color onto a non-terminal stream,
  which is also how tests capture styled output through pipes.
- Styling is a small fixed set (bold, dim, red, green, yellow, cyan) applied
  through helpers that return the text unchanged when color is off. No cursor
  movement, no line rewriting.

Applied across existing human-facing output, consistently by meaning:

- Green: success confirmations (`Confirmed ... as`, `Exported ...`), confirmed
  status in review tables.
- Yellow: warnings (`Warning:` prefix and the `WARN` level token in log lines),
  suggested status.
- Cyan: automatic status; prompts and section headers use bold.
- Red: fatal error messages on stderr, the `ERROR` level token, unreadable and
  unidentified markers.
- Dim: file paths in listings, timestamps in sample lines.

Structured log lines (`event=` format) color only the level token, keeping
`grep`/`awk` field parsing stable. JSON and rendered transcript outputs are
never styled.

## Test approach

Three layers, no terminal emulation:

1. Unit tests for pure logic: sample selection (tercile spread, short-segment
   filter, fallbacks), reply parsing (empty/name/`l`/number/`s`/`q`), and the
   color gate (`NO_COLOR`, `TERM=dumb`, `CLICOLOR_FORCE`, non-TTY), with the
   environment injected rather than read from the process.
2. In-process session tests: the prompt loop reads and writes through an
   injected `InteractiveIO` (a pair of closures), so tests script an entire
   session — accept suggestion, type a new name, pick from the profile menu,
   skip, quit — and assert on decisions, profile store contents, and document
   matches without a subprocess.
3. End-to-end CLI tests: run the built binary with `--interactive`, piped stdin
   for replies, and `XDG_STATE_HOME` pointing at fixture documents (the existing
   `SpeakerCommandsTests` harness plus a `standardInput` pipe). Verifies
   argument routing, the non-TTY fallback to the table (no `--interactive`), and
   that `CLICOLOR_FORCE=1` yields ANSI sequences while piped output without it
   stays plain.

## Compatibility

- Scripts that ran `speakers review <doc>` with piped or redirected output see
  the same read-only table as 2.6.0, since non-TTY streams keep the
  non-interactive default; `--apply` behavior is unchanged.
- `speakers review` with no argument was previously an error; it becomes the
  all-documents session (or table), so no existing invocation changes meaning.
- No document schema or profile store format changes.
