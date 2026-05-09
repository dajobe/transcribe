# Transcribe 2.0 CLI, Voice Memos, Idempotency, and Automation

## Summary

Use source-specific subcommands as the canonical CLI, while keeping the existing
root positional form as a convenience alias:

```bash
transcribe file meeting.m4a
transcribe dir ~/recordings/
transcribe voice-memos
transcribe --no-diarize --format md,json file meeting.m4a
transcribe --dry-run voice-memos

transcribe meeting.m4a              # alias for file
transcribe --no-diarize meeting.m4a # alias for file
transcribe ~/recordings/            # alias for dir
```

This gives directory transcription its own home for filename, metadata, and
session options, and gives Voice Memos a distinct import source without a
special root-level mode flag.

This is the single 2.0 planning spec for the CLI cleanup, Voice Memos import,
global processing ledger, Markdown output, and Folder Action helper.

## Split Root and Source Options

Shared transcription options belong only to the root command. Source-specific
options belong only to their source commands.

Pros:

- `transcribe file --help` stays small and focused.
- Shared options have one visible home: `transcribe --help`.
- Source-specific help is genuinely source-specific.
- The CLI grammar is cleaner and easier to document.
- Hidden duplicate shared options on every subcommand are avoided.

Cons:

- Shared options must move before the subcommand.
- Examples such as `transcribe file meeting.m4a --format md` become invalid.
- Root directory alias no longer supports directory-specific flags; users must
  use `transcribe dir`.
- Implementation needs root-level dispatch because Swift ArgumentParser does
  not naturally pass root option values into subcommand `run()` without
  duplicating option groups.

## Command Grammar

Canonical forms:

```text
transcribe [global options] file <audio-file>
transcribe [global options] dir [dir options] <directory>
transcribe [global options] voice-memos [voice-memos options]
```

Root alias:

```text
transcribe [global options] <audio-file-or-directory>
```

Root alias behavior:

- If the path is a file, dispatch to the file planner.
- If the path is a directory, dispatch to the directory planner.
- Directory-specific options require `transcribe dir`; the root alias accepts
  global options only.
- Do not support Voice Memos through root flags.

## Option Scoping

Global options are owned by the root command and must appear before `file`,
`dir`, `voice-memos`, or the root path alias:

- `--model`, `--language`, `--model-dir`
- `--output-dir`, `--output-prefix`, `--format`, `--stdout`
- `--no-diarize`, `--min-speakers`, `--max-speakers`, `--speaker-strategy`
- `--overwrite`, `--redo`, `--no-processing-state`, `--mark-imported`,
  `--dry-run`
- timing, progress, and compute-unit options

Global options are intentionally not accepted after source commands. For
example, `transcribe file meeting.m4a --format md` is invalid; use
`transcribe --format md file meeting.m4a`.

`file` only:

- positional `<audio-file>`

`dir` only:

- positional `<directory>`
- `--sort recorded|name|mtime`
- `--input-sort recorded|name|mtime` as an alias for `--sort`
- `--filename-time-recovery` / `--no-filename-time-recovery`
- `--auto-session-basename` / `--no-auto-session-basename`

`dir` and `voice-memos` batch inputs:

- `--session-gap <minutes>` (default `10`, `0` disables splitting)

`voice-memos` only:

- `--recordings-dir <path>`, defaulting to
  `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`

Removed root-level options:

- `--voice-memos`
- `--voice-memos-dir`

## Validation Rules

- `file` rejects directory paths.
- `dir` rejects file paths.
- `voice-memos` rejects positional file or directory arguments.
- Shared/global options after `file`, `dir`, or `voice-memos` are invalid.
- Directory-specific options on the root path alias are invalid.
- `--mark-imported --redo` is invalid.
- `--mark-imported --no-processing-state` is invalid.
- `--stdout` requires `txt` to be one of the requested formats.
- Speaker bounds must be positive; `--min-speakers` must be less than or equal
  to `--max-speakers`.
- Speaker bounds are invalid with `--no-diarize`.
- `--session-gap` must be non-negative.
- `--overwrite` controls output replacement only. It does not imply
  reprocessing.
- `--redo` controls reprocessing and is valid for all input sources.
- `--no-processing-state` bypasses processing-history skip checks and ledger
  writes.

## Directory Metadata Behavior

Keep the existing behavior, but document and expose it under `dir`:

- `--sort recorded`: use embedded recorded date, with fallback chain and trust
  check.
- `--sort name`: use natural filename order.
- `--sort mtime`: use file modification time.
- Filename time recovery parses leading filename times when embedded metadata is
  missing or untrusted.
- Session splitting uses recovered or embedded recorded times when trusted.
- Common-prefix basename derivation stays enabled by default.

No new filename metadata modes are added in this pass.

## Processing Ledger

Add append-only `processing_history.jsonl` under `StatePaths`, using the same
file-locking style as `TimingStore`.

Record successful completed sessions for all source kinds:

- `file`
- `directory_session`
- `voice_memos`
- `imported_baseline`

Store:

- source kind and stable source id
- source fingerprint: SHA-256 of file bytes, or ordered per-file SHA-256s for
  directory sessions
- important settings signature: model, language, diarization, speaker strategy,
  speaker bounds, requested formats, stdout text behavior, and transcribe
  version
- output dir, basename, output paths, completion time, duration, warning count
- Voice Memos audit metadata when available

Default skip rule:

- Skip only when source fingerprint, important settings, and requested outputs
  match a completed ledger entry, and all requested output files exist.
- Reprocess when outputs are missing, source content changed, or important
  settings changed.
- `imported_baseline` records skip matching file, directory, or Voice Memos
  sessions even though transcript outputs do not exist.

`--redo` ignores matching ledger entries and appends a new completion record
after success.

## Voice Memos Import

`transcribe voice-memos` reads Apple Voice Memos that are already synced to disk.
It uses actual files under the recordings directory; there is no download, copy,
or conversion step.

Voice Memos are batch input. By default, adjacent memos are grouped with the
same session-gap logic used by `transcribe dir`: gaps larger than
`--session-gap` minutes (default `10`) start a new transcript session, while
closer memos are concatenated into one session. `--session-gap 0` disables
splitting and processes all usable memos as one session.

Read `CloudRecordings.db` read-only and query `ZCLOUDRECORDING`:

- identity: prefer `ZUNIQUEID`, fallback to `ZPATH`, keep `Z_PK` for diagnostics
- audio path: `ZPATH`, resolved relative to the recordings directory when needed
- recorded time: `ZDATE`, converted from Apple reference date
- duration: prefer `ZDURATION`, fallback to `ZLOCALDURATION`, fallback to
  AVFoundation duration
- title: prefer `ZCUSTOMLABEL`, then `ZENCRYPTEDTITLE`, then `New Recording`
- optional diagnostics: audio digest, flags, folder id

Output basename:

- `YYYY-MM-DD HHMM <sanitized title>`
- deterministic numeric suffixes for collisions

Output metadata for Voice Memos:

- `source: "voice_memos"`
- `recorded_at`
- `recording_title`
- `voice_memos_unique_id`
- `voice_memos_path`

If macOS denies the recordings directory or database, report that Full Disk
Access may be required.

## Baseline Import

`--mark-imported` is a global option. It builds the normal source plan for
`file`, `dir`, or `voice-memos` and writes `imported_baseline` ledger entries
without transcription or transcript output.

Future runs skip matching source sessions unless:

- `--redo` is passed
- the audio fingerprint changes
- the source no longer matches the baseline identity/fingerprint

Voice Memos baseline records include title, recorded date, `ZUNIQUEID`, `ZPATH`,
and fingerprint for auditability when those fields are available.

`transcribe --dry-run --mark-imported voice-memos` lists the baseline actions
without writing ledger entries.

## Markdown Output

`md` is a first-class output format. It writes `basename.md` in the chosen output
directory, following the same overwrite rules as other output formats.

Markdown structure:

- Title: a single `#` heading derived from the input basename, with `#`
  characters stripped. If nothing remains, use `# Transcript`.
- Metadata: a `## Metadata` section with source filename, duration, model,
  language when known, diarization state, speaker strategy when applicable,
  speakers detected when available, transcribe version, and creation time.
- Transcript: a `## Transcript` section, followed by merged transcript groups.
  Groups with speakers use `## **SPEAKER** - _HH:MM:SS - HH:MM:SS_`; groups
  without speakers use `## _HH:MM:SS - HH:MM:SS_`.

The Markdown transcript body follows the same merge and time-range logic as the
plain `txt` format. Markdown is always written to a file when requested; it is
not written to stdout.

`--format all` expands to `txt`, `json`, `srt`, `vtt`, and `md`.

## Folder Action Automation

`scripts/folder-action-transcribe.sh` supports macOS Automator Folder Actions
that run transcription when an audio file is added to a watched folder.

`scripts/folder-script.sh` is an optional wrapper that sets log/output paths,
`TRANSCRIBE_BIN`, and `TRANSCRIBE_LOCK_FILE`, then invokes
`folder-action-transcribe.sh` from the same directory as the wrapper. Edit the
paths inside for the local machine and `chmod +x` both scripts.

The helper accepts one POSIX path argument for the added file. Automator should
use a Folder Action workflow with **Run Shell Script**, shell `/bin/bash`, and
**Pass input: as arguments**.

Behavior:

- Wait for a stable file size before processing because Folder Actions can fire
  before a copy finishes. Defaults: `TRANSCRIBE_STABLE_SECS=2` and
  `TRANSCRIBE_MAX_STABLE_WAIT=3600`.
- Process only supported audio extensions: `mp3`, `wav`, `m4a`, `flac`, `aiff`,
  and `caf`.
- Skip hidden files and `.tmp` files.
- If `TRANSCRIBE_SKIP_IF_MD_EXISTS=1`, skip when `basename.md` already exists in
  the resolved output directory.
- Use `TRANSCRIBE_BIN` for the executable path, defaulting to `transcribe` on
  `PATH`.
- If `TRANSCRIBE_OUTPUT_DIR` is unset, pass `-o "$(dirname "$file")"` so outputs
  go next to the source file. If set, pass `-o "$TRANSCRIBE_OUTPUT_DIR"`.
- Use `TRANSCRIBE_FORMAT`, defaulting to `md`.
- Insert `TRANSCRIBE_EXTRA_ARGS` as additional global CLI flags before the
  `file` source command.
- If `TRANSCRIBE_LOCK_FILE` is set and `flock` exists, serialize runs under that
  lock.
- If `TRANSCRIBE_LOG` is set, append structured start/end lines with UTC
  timestamps, child exit code, duration, and skip/failure reason. Non-zero
  `transcribe` runs include mapped exit-code meaning and a stderr summary.

The constructed command shape is:

```bash
"$TRANSCRIBE_BIN" -o "$outdir" --format "$TRANSCRIBE_FORMAT" \
  $TRANSCRIBE_EXTRA_ARGS file "$file"
```

Folder Action exit behavior:

- `0`: skipped or `transcribe` succeeded.
- non-zero: `transcribe` failed; preserve the child exit code when possible.

## Execution Factoring

Implementation structure:

- Root command parsing owns global options and dispatches the first source token
  to `file`, `dir`, `voice-memos`, or the file/directory path alias.
- `FileSourceArguments`, `DirSourceArguments`, and `VoiceMemosSourceArguments`
  parse only source-specific arguments.
- Source planning builds `PipelineSessionPlan` values before shared pipeline
  execution.
- Shared execution handles model/settings resolution, fingerprinting,
  idempotency skip checks, dry run, overwrite checks, preflight, model loading,
  transcription, output writing, and processing/timing ledger writes.

## Test Plan

Root alias:

- file path dispatches to file planner
- directory path dispatches to dir planner
- missing path shows usage
- directory-specific options on the root alias are rejected

`file`:

- accepts audio file
- rejects directory path
- does not accept dir-only options

`dir`:

- accepts directory path
- rejects file path
- supports sort, session, filename recovery, and basename options
- preserves current directory grouping and basename behavior
- rejects global options placed after `dir`

`voice-memos`:

- `--dry-run` lists process/skip
- `--mark-imported` writes baseline records
- `--mark-imported --dry-run` writes nothing
- rejects positional file/directory arguments
- supports `--recordings-dir`
- supports `--session-gap` with the same default grouping behavior as `dir`
- rejects global options placed after `voice-memos`

Regression:

- processing ledger tests pass
- directory session ledger entries use ordered per-file hashes
- Voice Memos database fixture tests pass
- output metadata tests pass
- Markdown output tests pass
- Folder Action script smoke test emits global options before `file`
- full `swift test` passes

## Assumptions

- Backward compatibility for `--voice-memos` and `--voice-memos-dir` is not
  required.
- Backward compatibility for root file/directory positional use is preserved.
- `file`, `dir`, and `voice-memos` are the canonical source commands going
  forward.
