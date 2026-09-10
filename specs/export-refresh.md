# Automatic export refresh after speaker changes

## Status and scope

Target release: 2.6.1. Builds on persistent speaker identities
(persistent-speaker-identities.md) and interactive speaker review
(interactive-speaker-review.md). No SDK or model changes; this is bookkeeping in
the canonical document plus a shared refresh routine called from the existing
speaker commands and the export command.

Today, confirming or clearing a speaker updates the canonical document but
leaves every previously rendered output (md, srt, vtt, txt, json) showing the
old `SPEAKER_n` labels, and the CLI merely prints "Export again to update
rendered files." This feature makes the speaker commands regenerate those files
automatically, on by default, with a user option to disable it.

Out of scope: propagating `speakers rename`/`delete` into other documents
(neither modifies canonical documents today, so nothing becomes refreshable),
watching output files for external changes, and any change to matching or
enrollment rules.

## User workflow

```bash
transcribe file meeting.m4a -f md,srt -o ./notes
transcribe speakers review          # confirm Bob and Alice interactively
# → Refreshed 2 exports for meeting (md, srt).

transcribe speakers confirm doc.transcript.json SPEAKER_0 --name "Dave"
# → Confirmed SPEAKER_0 as Dave (PROFILE_ID). Refreshed 2 exports.

transcribe speakers confirm doc.transcript.json SPEAKER_1 --name "Eve" \
    --no-refresh-exports            # opt out for one command

transcribe export doc.transcript.json --refresh   # manual: recorded set only
transcribe export --refresh                       # every saved transcript
```

Exports whose files were edited or deleted since transcribe wrote them are never
overwritten or resurrected; the refresh reports and skips them.

## Export records in the canonical document

The canonical document gains an optional top-level `exports` array. This is an
additive optional key within schema version 1: documents without it decode as
before, and older binaries ignore the unknown key. Each entry records one
rendered file:

| Key          | Meaning                                                    |
|:-------------|:-----------------------------------------------------------|
| `path`       | Absolute path of the written file                          |
| `format`     | Renderer format (`txt`, `json`, `md`, `srt`, `vtt`, `tsv`) |
| `sha256`     | SHA-256 of the bytes transcribe last wrote there           |
| `exportedAt` | ISO 8601 time of the last write                            |

Records are written by the two places that render outputs:

- The pipeline (`writeOutputs` callers in `PipelineRunner`), for stateful runs
  that saved a canonical document: after the output files are written, the
  managed document is updated with their records under the document lock.
  Failure to update records degrades to a warning, matching how ordinary runs
  treat canonical-save failures. `--no-outputs` and `--stateless` runs record
  nothing.
- The `export` command: after writing, it updates its input document in place
  under the document lock. Entries are keyed by path: re-exporting to the same
  destination replaces the entry, exporting to a new directory adds entries.

Records are per-machine bookkeeping, not portable provenance: a canonical
document copied to another machine carries absolute paths that will not resolve
there, and refresh treats them as deleted (below). Recorded hashes are change
detection for transcribe's own writes, not an integrity guarantee.

## Refresh triggers and option surface

Refresh runs after any command saves a canonical document with changed speaker
matches:

- `speakers confirm` and `speakers clear`, after the document save.
- `speakers review --apply`, after saving refreshed decisions.
- The interactive review session, per document, after its decisions are applied.
  Documents where the user only skipped are not refreshed.

Control, in precedence order:

- `--refresh-exports` / `--no-refresh-exports` flag on `speakers confirm`,
  `speakers clear`, and `speakers review`.
- `TRANSCRIBE_REFRESH_EXPORTS=0` environment variable, following the
  `TRANSCRIBE_ETA_HINTS` pattern in `ConfigMerge.swift`.
- `refreshExports` boolean in the user config file.
- Default: true.

A confirmation is never rolled back by a refresh problem: the speaker-change
save happens first and stands on its own; every refresh failure is a warning.

## Refresh algorithm

For one document, inside the existing `withDocumentLock` (rendering and writing
are fast; no human input occurs under the lock):

1. Load the document's `exports` records. If there are none, fall back to the
   legacy hint: look up the newest `ProcessingRecord` whose source fingerprint
   hashes match the document's `sourceHashes` and has non-empty `output_paths`,
   and print the exact `transcribe export ... --overwrite` command that would
   regenerate them. History records carry no content hashes, so pre-feature
   exports are never overwritten automatically; running that command once seeds
   records and makes the document self-refreshing.
2. For each record, render its format from the document's current
   `renderedOutput()` view (accepted names substituted, same renderer path as
   `export`):
   - File missing at `path`: drop the record with a note. A deleted or moved
     export was a deliberate act; refresh does not resurrect files.
   - On-disk SHA-256 differs from the recorded `sha256`: the user edited the
     file. Warn, skip the write, keep the record so a restored file refreshes
     again later.
   - Newly rendered bytes hash equal to the recorded `sha256`: already up to
     date (for example TSV, whose columns carry no speaker names); no write.
   - Otherwise write atomically over the file and update the record's `sha256`
     and `exportedAt`. The canonical-input guard from `export` is re-checked: a
     record naming the document itself (possible only in a hand-assembled
     document) is warned about and never written, consistent with every other
     refresh failure degrading to a warning.

3. If any record changed or was dropped, save the document once.
4. Print one summary line per document, colored by the existing `Terminal`
   conventions: `Refreshed 2 exports for meeting (md, srt); 1 skipped (locally
   modified: notes/meeting.txt).`

The `md` and `json` renderers previously stamped `created_at` with the render
time, which would make every re-render differ. Export and refresh now render
`created_at` from the document's own creation time, so a re-render with
unchanged names is byte-identical and detected as up to date.

`transcribe export <doc> --refresh` runs exactly this routine (`--format`, `-o`,
`--output-prefix`, and `--overwrite` are rejected alongside `--refresh`), giving
a scripted path when automatic refresh is disabled. With no document argument it
walks every readable file in `<state>/transcripts/`, like `speakers review`, and
is silent for documents that are fully up to date.

## Compatibility and safety

- Files transcribe did not write, or that changed since it wrote them, are never
  overwritten; the hash check enforces the existing promise that edited
  transcripts are not touched.
- Documents from earlier releases have no records; behavior for them is the
  actionable hint in step 1, no writes. One explicit export opts a document in.
- `--no-refresh-exports` restores the 2.6.0 behavior exactly, including the
  "Export again to update rendered files." hint.
- Scripted `speakers` invocations keep their output shape; the refresh summary
  is an additional line. The speaker commands have no structured `event=`
  reporter, so refresh emits none.
- The profile store, matching policy, and processing-history skip logic are
  unchanged. Refresh writes never append processing history.
- Refresh only writes through paths that are regular files whose extension
  matches the record's validated format; symlinks and special files at a
  recorded path are warned about and never replaced. Unreadable-but-present
  files keep their record; only a genuinely missing path drops it.
- Two races are accepted as limitations. The hash check and the atomic rename
  are two steps, so an editor save landing in the milliseconds between them is
  lost; POSIX offers no compare-and-swap rename, and the exposure matches a
  single user running one command. And the managed store's carry-forward on a
  deduplicating save reads the previous document outside the document lock
  (locking inside the store would deadlock callers already holding it), so a
  pipeline rerun racing a concurrent export can drop that export's record — the
  affected files simply refresh on the next explicit export.

## Test approach

1. Unit tests for the per-record decision table: missing file, locally modified,
   up to date, stale, and the record-keyed replace/add semantics of repeated
   exports.
2. Store and command tests with isolated `XDG_STATE_HOME` fixtures: `export`
   seeds records; `speakers confirm` rewrites a stale md/srt pair and leaves an
   edited txt untouched with a warning; `--no-refresh-exports`, the environment
   variable, and the config key each disable the rewrite; a record-less legacy
   document prints the seeding hint; interactive review refreshes only documents
   with applied decisions.
3. End-to-end CLI tests: `export --refresh` on one document and across all saved
   transcripts, rejection of `--refresh` combined with `--format`/`-o`, and the
   canonical-input overwrite guard.
