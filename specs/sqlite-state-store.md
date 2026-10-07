# SQLite state store

## Status and scope

Approved 2026-10-07, not yet implemented. Replaces the JSON-file state store in
the transcribe state directory with a single SQLite database while keeping
`.transcript.json` as the portable interchange format. Covers canonical
transcripts, speaker profiles, processing history, and timing history; does not
change output formats, the pipeline, or `--stateless` behavior.

**Ships as transcribe 3.0.0.** This is a major version bump: the state layout,
internal APIs, and the CLI output that referenced managed file paths all change,
and the release does not pretend otherwise. Breaking changes are documented in
the release notes rather than papered over with compatibility shims; what must
not break is user data (migration is non-destructive) and the portable
`.transcript.json` format.

Notation: `<state>` below means the transcribe state directory itself —
`$XDG_STATE_HOME/transcribe` or `~/Library/Application Support/transcribe`
(`StatePaths.stateDirectoryURL()` already includes the trailing `transcribe`
component).

Relation to [TODO](../TODO.md): this is the storage half of R8 (index history
once, control ledger growth) and R12 (native locking), and gives R6/R7 (session
states, recoverable completion) and R5 (ordered session identity) a place to put
their records. Those behaviors remain separate tasks; this spec only ensures the
schema does not block them.

## Problem

Each store hurts in a different way:

- **Whole-file decode for partial reads.** Listing transcripts, the duplicate
  scan in `CanonicalTranscriptStore.existingManagedFile`, and `speakers review`
  across all documents each open every `.transcript.json` file. Partial
  `Decodable` structs (`EvidenceListing`, `TranscriptListing`) limit the damage
  but still read and parse every byte of 1+ MB files whose bulk is segments and
  words (≈917 KB of a 1.7 MB file; embeddings are only ≈37 KB).
- **Whole-file rewrite for small writes.** Confirming one speaker rewrites the
  complete pretty-printed document and the complete profile store. The 524 KB
  profile file is rewritten on every confirmation.
- **Repeated ledger scans.** `ProcessingStore` calls `loadRecords` up to three
  times per planned session (import-baseline, completion, content decisions),
  re-reading and re-decoding the full JSONL ledger each time; skip records grow
  the file that future scans parse (R8). `staleExportHint` adds another full
  ledger load per document during `export --refresh`.
- **Sidecar lock files.** Every document carries a `.lock` neighbor, and the
  profile store its own; lock order (document then profile) is a convention
  spread across call sites, and the locks cover file replacement, not the wider
  check/process/write races R12 describes.
- **No queries.** "Which documents mention this profile", "most recent runs for
  this model", or future transcript search all require scanning every file.

Pretty-printed JSON also roughly doubles bytes on disk, and Float arrays encoded
as JSON numbers are ~5× their binary size.

## Goals

- One state database with indexed access: listing, duplicate checks, and review
  planning read only the columns they need, never megabytes of segment text.
- Small writes stay small: confirming a speaker touches a few rows, not a
  megabyte of JSON.
- Native concurrency: SQLite transactions and WAL replace the managed store's
  per-file `flock` sidecars for state, with one obvious place to put R12's wider
  session locking. (One narrow advisory lock remains for export refresh; see
  Concurrency.)
- Durability no weaker than today's fsync-then-rename writes
  (`writePrivateAtomically`).
- No new dependencies: macOS ships SQLite, and the project already links
  `SQLite3` for Voice Memos reads.
- `.transcript.json` remains the portable, human-readable interchange format;
  nothing a user can see or share gets locked inside a database.
- A user can inspect their own data with the stock `sqlite3` CLI, including
  `json_extract` over segment text.

Non-goals: changing output formats or export schemas, full-text search (enabled
later by this design, not shipped with it), cloud sync, multi-user access.

## Backend choice

| Option                          | Pros                                                                                                                  | Cons                                                                                       |
|:--------------------------------|:----------------------------------------------------------------------------------------------------------------------|:-------------------------------------------------------------------------------------------|
| **System SQLite, thin wrapper** | Already linked (`SQLiteReader`); zero new dependencies; WAL concurrency; `sqlite3` CLI inspection; stable file format | More hand-written binding code; SQL in strings                                             |
| GRDB.swift                      | Mature Swift API, migrations, Codable rows                                                                            | New third-party dependency to pin and review; most value is in features this CLI skips     |
| Core Data / SwiftData           | Apple-supported ORM                                                                                                   | Schema opacity, migration ceremony, poor fit for a CLI; SwiftData churn across OS releases |
| LMDB / LevelDB                  | Fast KV                                                                                                               | New C dependency; no SQL queries, which are half the point                                 |
| Keep JSON, add an index file    | Small change                                                                                                          | Cache-invalidation problems; rewrite amplification and locking remain                      |

**Why not the Apple-native frameworks, in a Swift app?** Core Data and SwiftData
are the Apple-native options, and both are object-graph layers on top of SQLite,
not databases. Their value — faulting, change tracking, undo,
SwiftUI/Observation integration — is UI-app machinery this CLI would never
touch. Their costs land exactly where this tool lives: the on-disk schema is a
private Core Data artifact (`Z`-prefixed tables), which kills the
inspect-with-`sqlite3` goal and makes the stored format Apple's contract rather
than ours; migrations go through versioned model objects instead of SQL we
control; and concurrent access from separate short-lived processes (parallel CLI
invocations, Folder Actions) is not the pattern either framework is built for —
transaction boundaries and busy handling are hidden behind context semantics.
SwiftData adds OS-release churn on top. The honest statement is that SQLite *is*
the Apple-native data layer: Apple ships and maintains `libsqlite3` in the OS,
builds Core Data on it, and uses it directly for its own system stores —
including the Voice Memos database this tool already reads through its existing
SQLite wrapper.

**Decision: system SQLite through a small internal wrapper.** Extend the pattern
of `ReadOnlyDatabase` (`SQLiteReader.swift`) with a writable counterpart owning
prepared statements, transactions, and migrations — roughly a few hundred lines,
consistent with this codebase's no-third-party-dependencies posture. Budget
explicitly for the hard parts: transaction kinds, `SQLITE_BUSY_SNAPSHOT`, and
statement lifetime. GRDB is the fallback if the wrapper grows beyond that; the
schema below works unchanged under either.

## Database layout

One database, `<state>/state.db`, in WAL mode. The database file is pre-created
at mode `0600` before SQLite opens it (SQLite itself creates files at 0644
masked by umask); `-wal` and `-shm` inherit its mode. All live in the existing
`0700` state directory. Connections set `PRAGMA foreign_keys = ON`, a generous
`PRAGMA busy_timeout` (30 s), and `PRAGMA synchronous = FULL`. FULL, not NORMAL:
the current writers call `FileHandle.synchronize` (fsync) on the file and fsync
the directory before publishing (`writePrivateAtomically` in
`OutputWriter.swift`), so an acknowledged write survives an OS crash today, and
this store must not weaken that. This is fsync parity: the current code does not
use `F_FULLFSYNC`, and `PRAGMA fullfsync` stays off to match. Write volume here
is interactive-command scale; FULL's cost is irrelevant.

A single database rather than one per store: cross-store writes (confirm =
document rows + profile rows) become one transaction, removing today's two-lock
ordering rule for managed documents entirely.

### Schema v1

The database schema version lives in `PRAGMA user_version` (and `meta` for human
readers). A binary refuses a database whose version is newer than it
understands, with a message naming the newer-binary requirement — the same
contract `unsupportedSchema` enforces for portable documents today.

```sql
CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);  -- 'schema_version' = '1', 'created_by' = transcribe version,
    -- migration markers (see Migration)

CREATE TABLE documents (
  id                  TEXT PRIMARY KEY,     -- internal document UUID, lowercased
  evidence_id         TEXT NOT NULL UNIQUE, -- sha256:…
  source_hashes       TEXT NOT NULL,        -- JSON array, sorted unique
  created_at          TEXT NOT NULL,        -- ISO 8601, whole seconds
  model               TEXT NOT NULL,
  transcribe_version  TEXT NOT NULL,
  audio_path          TEXT NOT NULL,
  audio_files         TEXT,                 -- JSON array or NULL
  basename            TEXT NOT NULL,
  source_metadata     TEXT,                 -- JSON object or NULL
  embedding_model_id  TEXT NOT NULL,
  language            TEXT,
  duration_seconds    REAL NOT NULL,
  diarization_enabled INTEGER NOT NULL,
  speakers_detected   INTEGER,
  speaker_strategy    TEXT NOT NULL,
  warnings            TEXT NOT NULL,        -- JSON array
  segment_count       INTEGER NOT NULL,     -- lifted so inspect/review
  segment_speakers    TEXT NOT NULL,        -- never read the payload
  exports_recorded    INTEGER NOT NULL,     -- 0 = today's nil exports
  updated_at          TEXT NOT NULL         -- bumped by EVERY mutation
);

-- The heavy payload, separated so metadata queries never touch it.
CREATE TABLE document_segments (
  document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
  encoding    TEXT NOT NULL,              -- 'json' initially
  payload     BLOB NOT NULL               -- segments array incl. words
);

CREATE TABLE document_embeddings (
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  speaker_id  TEXT NOT NULL,              -- SPEAKER_n
  vector      BLOB NOT NULL,              -- float32 little-endian
  PRIMARY KEY (document_id, speaker_id)
);

CREATE TABLE speaker_matches (
  document_id   TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  speaker_id    TEXT NOT NULL,
  profile_id    TEXT NOT NULL,            -- no FK: name snapshots survive
  name          TEXT NOT NULL,            -- speakers delete, as today
  distance      REAL NOT NULL,
  margin        REAL,
  example_count INTEGER NOT NULL,
  status        TEXT NOT NULL,            -- suggested|automatic|confirmed
  PRIMARY KEY (document_id, speaker_id)
);

CREATE TABLE dismissed_speakers (
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  speaker_id  TEXT NOT NULL,
  PRIMARY KEY (document_id, speaker_id)
);

CREATE TABLE exports (
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  position    INTEGER NOT NULL,           -- preserves array order
  path        TEXT NOT NULL,
  format      TEXT NOT NULL,
  sha256      TEXT NOT NULL,
  exported_at TEXT NOT NULL,
  PRIMARY KEY (document_id, path)
);

CREATE TABLE profiles (
  id   TEXT PRIMARY KEY,
  name TEXT NOT NULL
);

CREATE TABLE profile_examples (
  profile_id    TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  transcript_id TEXT NOT NULL,            -- evidence ID, as today
  speaker_id    TEXT NOT NULL,
  model_id      TEXT NOT NULL,
  vector        BLOB NOT NULL,            -- float32 little-endian
  source_hashes TEXT NOT NULL,            -- JSON array
  PRIMARY KEY (profile_id, transcript_id, speaker_id)
);
-- One voice, one person: the current store validates example identity
-- globally and confirmation MOVES evidence between profiles.
CREATE UNIQUE INDEX profile_examples_identity
  ON profile_examples(transcript_id, speaker_id);

CREATE TABLE processing_history (
  rowid        INTEGER PRIMARY KEY,
  completed_at TEXT NOT NULL,             -- the record's own recorded_at
  source_kind  TEXT NOT NULL,             -- names the recording date
  source_id    TEXT NOT NULL,
  record       TEXT NOT NULL              -- VERBATIM JSONL line
);
-- Completion and baseline decisions scan newest-first per source.
CREATE INDEX processing_history_source
  ON processing_history(source_kind, source_id, rowid);

CREATE TABLE timing_history (
  rowid       INTEGER PRIMARY KEY,
  recorded_at TEXT NOT NULL,
  model       TEXT NOT NULL,
  diarization INTEGER NOT NULL,
  record      TEXT NOT NULL               -- VERBATIM JSONL line
);
CREATE INDEX timing_history_key ON timing_history(model, diarization, rowid);

CREATE TABLE migration_sources (          -- see Migration
  source_path   TEXT PRIMARY KEY,
  status        TEXT NOT NULL,            -- imported|skipped|conflict
  detail        TEXT,                     -- skip/conflict reason
  planned_path  TEXT,                     -- written BEFORE the rename
  archived_path TEXT                      -- confirmed after the rename
);
```

Design notes:

- **Every persisted field has a home.** The `documents` columns cover every
  field of `CanonicalTranscript` and the scalar fields of `TranscriptionOutput`
  (`language`, `durationSeconds`, `diarizationEnabled`, `speakersDetected`,
  `speakerStrategy`, `warnings`), with segments and embeddings in their own
  tables. `speakerStrategy` and `warnings` are easy to forget because exports
  consume them (`OutputWriter.swift`); acceptance requires an exhaustive
  round-trip test so a future field added to the document or output structs
  fails a test rather than silently dropping data. `segment_count` and
  `segment_speakers` (the distinct segment speaker labels, a JSON array) are
  lifted because `inspect` prints the count and the read-only review table
  builds its speaker set from segments ∪ embeddings
  (`SpeakerCommands.printReview`); without them those commands would read the
  payload and defeat the performance goal.
- **Dates are whole seconds.** Timestamps are stored as the same whole-second
  ISO 8601 strings `.iso8601` coding produces today, so a document round-trips
  bit-identically through portable JSON.
- **`updated_at` is the ordering contract.** The all-documents review visits
  newest-first by file mtime today; every database mutation — including
  export-record updates, which also bump mtime today — sets `updated_at`.
  Migration seeds it from the source file's mtime, not `created_at`. The
  `transcripts` listing orders by `id`, matching today's path sort of UUID-named
  files.
- **Exports keep array semantics.** The current `exports` value is an optional
  ordered array, and the distinction matters: a managed re-save carries previous
  exports forward only when the incoming value is nil
  (`CanonicalTranscriptStore.save`). `exports_recorded` preserves
  absent-versus-empty and `position` preserves order, so the decoded-value round
  trip is exact. Migration of a file with duplicate export paths (accepted by
  today's validation, not produced by today's writer) keeps the last record per
  path and notes it in `migration_sources.detail`.
- **Segments stay one blob, stored as plain JSON.** Every current reader wants
  the whole segment array or none of it, so normalizing ~1,500 segment and
  ~10,000 word rows per document buys nothing today and makes migration and
  validation much larger. The payload is uncompressed JSON text in v1: at ~18 MB
  total the space saving from zlib is not worth giving up
  `sqlite3`/`json_extract` inspectability, and the performance win comes from
  not reading the payload, not from shrinking it. The `encoding` column ('json')
  lets a later change (compression, normalized rows, FTS) happen per document
  without a schema break.
- **Embeddings become binary.** Float32 blobs are ~5× smaller than JSON number
  arrays and round-trip exactly; the cosine-distance code already works on
  `[Float]`. Encoding is little-endian float32, dimension implied by blob
  length. The profile store's semantic checks move unchanged: vectors only
  compare under equal `model_id`, per-model dimensions must agree, vectors must
  be finite and non-zero.
- **Ledger rows are verbatim.** The `record` column holds the exact JSONL line
  text, never a decode/re-encode, because rows legally carry fields this binary
  does not know (`MigrationScriptTests` pins an `"unknown_field"` surviving).
  The lifted columns — `(source_kind, source_id)` for processing, `(model,
  diarization)` for timing — are extracted leniently at insert; a row they
  cannot be extracted from still imports with placeholder keys rather than being
  dropped. Decisions keep R8's model: one snapshot per planning run, now one
  indexed `SELECT` instead of three file parses (plus `staleExportHint`'s). R8's
  compaction becomes `DELETE`s instead of a file-rewrite design.
- **Validation moves with the store.** The checks in
  `CanonicalTranscriptStore.validate` run on load and before save exactly as
  now; the database adds referential integrity (every match, dismissal, and
  embedding row must reference a document) but does not replace semantic
  validation. `speaker_matches.profile_id` deliberately has no foreign key: name
  snapshots must survive `speakers delete`, as today.

## Document references

Managed documents no longer have a backing file; 3.0.0 drops the file-URL
plumbing rather than emulating it. A new value type threads through the
speaker/export call chain:

```swift
enum TranscriptRef { case managed(id: UUID); case portable(URL) }
```

`transcriptURL(_:)` becomes `transcriptRef(_:)`; `withDocumentLock(at:)`,
`CanonicalTranscriptStore.save/load`, `SpeakerReview.Session.run`,
`ExportRefresh.run`, and `updateExportRecords` take the ref. Portable refs keep
the JSON file code path end to end.

User-visible output changes, enumerated for the 3.0.0 release notes and the test
updates that go with them:

- The `transcripts` listing's path column becomes the document ID column only
  (the ID column already exists); no path is printed for managed documents.
- Non-interactive `speakers review` headers and `(unreadable)` rows name the ID,
  not a path.
- `review --apply` prints "Saved assignments for <id>." instead of a path.
- The `canonical_saved` event keeps its `path` field for portable saves and adds
  `id`; for managed saves `path` is omitted. README's event documentation
  updates accordingly.
- `staleExportHint` suggests `transcribe export <id>` instead of a path.
- `history` with no records names the database, not `processing_history.jsonl`.

## Concurrency and locking

- **One connection per process, never used concurrently.** The wrapper owns a
  single connection; callers must not use it from two tasks at once. (The
  pipeline is async and hops threads, but state access is serialized today; the
  wrapper asserts this rather than assuming "one thread".)
- **Transactions join, never nest — and declare their kind.** Confirm, clear,
  and review paths today call profile-store methods from inside
  `withDocumentLock`; naively turning both wrappers into `BEGIN` fails on the
  second `BEGIN`. The wrapper exposes `inTransaction(_ kind: .read | .write)`:
  the outermost call issues `BEGIN DEFERRED` or `BEGIN IMMEDIATE` and owns
  commit/rollback; nested calls join. A `.write` joining an active `.read` is a
  programmer error (precondition), because a mid-transaction lock upgrade can
  fail with `SQLITE_BUSY_SNAPSHOT`, which `busy_timeout` does not retry.
  Savepoints are not needed in v1.
- **Joined transactions change error-path semantics, deliberately.** Today a
  confirm whose document save fails leaves the profile example committed and
  says "Retry confirmation with --profile <id>". For managed documents the whole
  confirm is now atomic: that partial state cannot occur and the message goes
  away (portable documents keep it — they remain two stores).
  `SpeakerReview.apply` buffers its per-decision "Confirmed X as Y" lines and
  prints them after commit, so a failure mid-batch cannot print confirmations
  that were rolled back.
- **Transactions cover state, not rendering — with one advisory lock kept.** A
  mutation transaction covers reads and row writes only; export files are
  written outside any transaction. But the current document lock deliberately
  spans render-to-record ("so a concurrent speaker change cannot slip between
  the render and the record merge", `SpeakerCommands.export`), and
  `ExportRefresh` both replaces the whole record array and treats any hash
  mismatch as "locally modified, never refresh again" — so two unserialized
  refreshes can permanently orphan a file from future refreshes. Managed
  documents therefore keep one advisory flock, `<state>/locks/<id>.lock`, held
  around render + record-commit (export, `export --refresh`, `ExportRefresh.run`
  after confirm). This is one lock directory instead of today's per-document
  sidecars beside user files, it nests outside the database transaction, and
  plain state mutations (confirm/clear/dismiss without refresh) do not take it.
- **Busy behavior is bounded waiting, not flock equivalence.** Today's `flock`
  blocks indefinitely; `busy_timeout` does not — it fails with `SQLITE_BUSY`
  after the interval. With transaction scopes reduced as above, 30 s is far
  beyond any expected writer; if it still trips, the command fails with an
  explicit "another transcribe is writing; retry" error rather than hanging
  forever. Acceptance includes a deliberately slow-writer test exercising both
  the successful wait and the error path.
- **Reads are transactions too.** Materializing a document (metadata + segments
  - embeddings + matches + dismissals + exports) or a profile with its examples
spans several `SELECT`s; each logical load runs inside a `.read` transaction so
a concurrent writer committing between queries cannot produce a mixed-generation
object. Today's single-file read gets this for free; the spec makes it explicit
here.
- **Portable documents keep their file locks.** External `.transcript.json`
  files are edited in place by review/confirm/clear and are not in any database
  — two processes (even with different `XDG_STATE_HOME` databases) can race on
  the same file. `withDocumentLock` therefore remains for portable refs exactly
  as today, acquired before any database transaction begins (file lock outer,
  transaction inner), and a portable-file write plus profile update stays two
  stores without a joint transaction — the same non-atomicity the current
  confirm command already has and messages for. Only managed-store sidecar locks
  disappear; migration deletes the leftover `.lock` files it archives alongside.
- R12's wider ambition (locking the whole check/transcribe/write sequence) is
  out of scope, but the natural implementation — a session claims a row, held
  across the pipeline — now has a home. This spec only commits to
  transaction-per-mutation.

## Portable documents and compatibility

- **`.transcript.json` is the interchange format, not the store.** The existing
  explicit-destination save (a portable copy the caller placed) continues to
  write schema v1 JSON, and any command that accepts a transcript path continues
  to read one. New subcommands make the boundary explicit:
  - `transcribe transcripts export-document <id> <path>` — write the portable
    JSON for a stored document.
  - `transcribe transcripts import <path>` — load a portable JSON document into
    the store (same evidence-ID replacement semantics as a managed save today).
    This is also the retry path for files migration skipped.
  - `transcribe transcripts export-legacy <directory>` — write the complete
    state as legacy-format JSON files (per-document `.transcript.json`,
    `speaker_profiles.json`, both JSONL ledgers) into an empty directory. This
    is a dump, not an in-place un-migrate; its output formats are frozen at the
    2.x shapes, and the command errors on any future state it cannot represent
    in them rather than silently dropping it. It exists for lossless rollback
    and doubles as the migration test harness: migrate, export, and compare
    decoded values against the sources.
- Commands that take "ID or path" keep both meanings: an ID (or any unique
  prefix) resolves against `documents.id` in the database; a path to an existing
  `.transcript.json` file is read as a portable document and operated on in
  place, without importing it.
- **Legacy managed paths are a documented break, not a fallback.** Scripts and
  shell history hold absolute paths like `…/transcripts/<uuid>.transcript.json`
  that the pipeline and `transcripts` listing printed; after migration those
  files are archived and the paths dangle. 3.0.0 does not special-case them: the
  existing "no transcript at <path>" error gains one sentence pointing at
  `transcribe transcripts` and the ID form, and the release notes say managed
  documents are now addressed by ID. (Resolution today matches the filename
  stem, which can differ from the internal `id` for hand-copied files; 3.0.0
  resolves by internal `id` only, and migration records any stem≠id cases in the
  manifest so `migration-status` can explain a lost handle.)
- The JSON schema version (currently 1) remains the compatibility contract for
  portable files and is unaffected by database schema versions.
- `--stateless` continues to touch no state at all — it must not open the
  database or take `init.lock`. `XDG_STATE_HOME` continues to select the state
  directory, so tests and experiments keep their isolation and get a fresh
  database per test directory.
- **Any state-opening command migrates**, including read-only ones
  (`transcripts`, `history`, `--dry-run` planning): they cannot read JSON state
  the database has superseded, and migration is non-destructive (the sources are
  archived, not deleted). This is stated so nobody is surprised that a listing
  triggered the one-way step.

## Migration

Migration is guarded, phased, and recorded per source file in
`migration_sources`. Release notes and the migration message say: **stop every
transcribe process, including Folder Action invocations, before first running
the new version.**

**Initialization guard.** Before any state access, a process takes an exclusive
`flock` on `<state>/init.lock` (created `0600`). Under that lock it checks the
database: absent → create and migrate; present without the `import_complete`
marker → a previous migration was interrupted before commit, so delete the
database files and migrate again (safe: source files are only moved in the
archive phase, which starts after `import_complete`); present with
`import_complete` but not `archive_complete` → resume the archive phase, still
under the lock; present with both markers → check for reappeared legacy files
(below), then proceed. The guard closes the two-process first-run race, covers
both phases, and prevents one process rebuilding a database another is
importing. The lock is bootstrap-only; normal operation uses database
transactions.

**Phase 1 — import** (one transaction):

1. Create the schema.
2. Preflight the `transcripts/` directory. Identity is the document's internal
   `id` (what `inspect` prints), which is also the filename stem for files this
   store named — but resolution today goes by stem alone and a file can carry a
   stem that differs from its internal `id`. Policy: UUID-named files are
   visited first in sorted path order, then foreign-named files; the first file
   per internal `id` and per evidence ID wins (UUID-named precedence strengthens
   today's collapse rule in `existingManagedFile`, which only ever considered
   UUID-named files). A winning file whose stem differs from its internal `id`
   is noted in the manifest detail — its stem handle stops working in 3.0.0, and
   `migration-status` explains why. Later files with a duplicate internal `id`
   or evidence ID are recorded as `conflict`, not imported, and never archived,
   so the user can inspect and `transcripts import` them deliberately.
3. Import every readable transcript and the profile store. An unreadable
   individual transcript is recorded as `skipped` with its reason and left in
   place, matching how the listing reports unreadable files today. An unreadable
   `speaker_profiles.json` **aborts** migration — its loader is the one store
   that fails loudly today rather than starting empty, and importing half the
   shared profile state would be worse than importing none.
4. Import both ledgers line by line, storing each line verbatim with leniently
   extracted key columns. Undecodable or truncated lines do **not** abort —
   today's loaders silently skip them, and `LockedAppendWriter` never fsyncs so
   a torn final line after a crash is normal. A skipped line is counted in the
   manifest detail for the ledger file; its bytes survive in the archived file.
5. Commit, write the `import_complete` marker, and checkpoint (`PRAGMA
   wal_checkpoint(TRUNCATE)`) so the marker is durable on disk.

**Phase 2 — archive** (resumable, under the init lock):

1. Archive preserves layout: `<state>/migrated-v1/transcripts/<name>`,
   `<state>/migrated-v1/speaker_profiles.json`, etc. The `migrated-v1/`
   directory is created `0700` — it holds voice embeddings.
2. For each `imported` row: commit `planned_path` first, then rename the source
   to it (same-volume), then commit `archived_path`, then delete the source's
   `.lock` sidecar. On resume, "source absent and planned destination present"
   counts as completed and is recorded; write-ahead means a crash between rename
   and record cannot lose track of a file. A pre-existing file at a planned
   destination gets a numeric suffix chosen at planning time.
3. Write `<state>/migrated-v1/MANIFEST.tsv` — a plain-text copy of the manifest
   (source path, status, archived path) — so rollback does not depend on reading
   the database. The `archive_complete` marker commits last.

**Reappeared legacy files.** An older binary that keeps running (a long batch or
Folder Action straddling the upgrade) recreates `processing_history.jsonl`,
`transcripts/` files, or the profile store with `O_CREAT`; once markers are set,
a naive new binary would ignore them forever, silently splitting state. The init
guard therefore stats the four legacy locations on every startup (cheap).
Findings are handled per store: reappeared ledger files are imported verbatim
(they contain only rows written after migration — the originals were archived)
and then archived with a new manifest row; reappeared transcript files are
listed by `migration-status` for `transcripts import`; a reappeared profile
store is never auto-merged — the command warns loudly and names it, because
merging divergent profile stores needs a human.

**Rollback** is lossless via `export-legacy`: stop every transcribe process, run
`transcribe transcripts export-legacy <dir>`, replace the state directory's
legacy files with that output, and delete `state.db*`. Everything done after
migration — transcriptions, confirmations, dismissals, ledger appends —
survives, because ledger rows are verbatim and every store has a legacy writer.
The snapshot restore (move the `migrated-v1/` files back **using
`MANIFEST.tsv`**, then delete `state.db*`) remains as the fallback when the 3.x
binary itself cannot run; it loses post-migration changes and says so. There is
no dual-write period either way.

`transcribe transcripts migration-status` prints the manifest: imported, skipped
(with reasons), conflict rows, and any reappeared legacy files, so a user can
see exactly what moved and retry skipped files after repairing them.

## Code touchpoints

- New: `StateDatabase` (writable wrapper: open/init guard, prepared statements,
  `inTransaction(kind:)`, blob/f32 helpers, schema migrations), `StateMigration`
  (phased JSON import + manifest), `TranscriptRef`, and the legacy-format
  writers behind `export-legacy` (shared with the migration tests).
- `CanonicalTranscriptStore`: `save`/`load` take `TranscriptRef`;
  `existingManagedFile` logic becomes a `SELECT`; a documents-listing query
  serves `transcripts` and review planning so they stop decoding files. Portable
  refs keep the JSON code path.
- `SpeakerProfileStore`: same public API over `profiles` / `profile_examples`;
  `withLock` becomes `inTransaction(.write)`; confirmation's
  move-evidence-between-profiles behavior becomes delete+insert in the joined
  transaction.
- `ProcessingStore` / `TimingStore`: `append` inserts a row; decision reads
  become one indexed snapshot query per planning run. `staleExportHint` reuses
  the snapshot instead of its own full load.
- `HistoryCommand`: reads rows; its empty-state message names the database.
- `LockedAppendWriter`: deleted. `withDocumentLock`: retained for portable refs;
  managed export refresh uses the `<state>/locks/<id>.lock` advisory lock.
- `SpeakerCommands`, `SpeakerReview`, `ExportRefresh`, `PipelineRunner`: take
  `TranscriptRef`; directory walks become listing queries; review output
  buffered to after commit; the `canonical_saved` event gains `id`.
- `StatePaths`: adds `stateDatabaseURL()`, the init-lock path, and the locks
  directory.
- `scripts/migrate-timing-history-v2.swift`: its default target file no longer
  exists after migration; retire it or point it at the archive.
- Docs: README (speaker workflow paths → IDs, `canonical_saved` event,
  state-storage description), hacking.md's state-layout notes, and the R8/R12
  entries in TODO.md.

## Verification and acceptance

- **Equivalence:** fixture JSON state (documents with matches, dismissals,
  exports present/absent/empty, non-default speaker strategies, warnings,
  stem≠id filenames, profiles, both ledgers including an unknown-field row and a
  torn final line) migrates, and every command — `transcripts`, `inspect`,
  `speakers review/confirm/clear`, `export --refresh`, `history`, skip and
  completion decisions — produces the same decisions and state as the
  JSON-backed build, with output differing only in the enumerated changes under
  Document references. The comparison runs through `export-legacy`: migrate the
  fixtures, export, and compare decoded values against the sources.
- **Lossless rollback:** after post-migration mutations (a new confirm, a
  dismissal, a ledger append), `export-legacy` output loads correctly in the
  previous JSON-backed build and contains those mutations; `export-legacy` into
  a non-empty directory is refused; state a future schema cannot represent in
  the 2.x formats makes the command error, not drop data.
- **Round-trip:** `export-document` of an imported portable file is semantically
  identical JSON: every field of `CanonicalTranscript` and `TranscriptionOutput`
  compared exhaustively on decoded values, including whole-second timestamps.
  The test constructs the document with every optional field populated so a
  newly added field fails loudly.
- **Performance:** listing, review planning, the non-interactive review table,
  and `inspect` over a 50-document store must not read segment payloads (assert
  via payload-table access counting); confirming one speaker writes kilobytes,
  not megabytes. Benchmark against the measured baseline above.
- **Concurrency:** two real processes confirming different speakers of the same
  document both succeed; two concurrent `export --refresh` runs of the same
  document serialize on the render lock and neither marks the other's fresh
  export "locally modified"; a reader during a writer's transaction sees the
  pre-commit state across a full document materialization; a writer committing
  between a reader's constituent queries cannot yield a mixed-generation
  document; a deliberately held transaction produces the bounded-wait success
  and, past the timeout, the explicit busy error; two processes racing first-run
  migration produce one correct database; a `.write` joining a `.read` trips the
  precondition in debug builds.
- **Error paths:** a managed confirm that fails mid-transaction leaves no
  profile example behind (atomicity replaces today's "retry with --profile"
  message); a review batch that fails midway prints no confirmation line for
  rolled-back decisions; portable documents keep today's two-store failure
  message.
- **Portable files:** two processes editing the same external `.transcript.json`
  serialize through the retained file lock; review, confirm, and clear on a
  portable path never create database rows.
- **Migration:** kill before `import_complete` → next run rebuilds from
  untouched sources; kill between rename and record → resume counts the planned
  destination as done, without double-moving; conflict and skipped files are
  left in place, reported by `migration-status`, and importable by `transcripts
  import` after repair; a dangling pre-migration managed path produces the error
  that points at `transcribe transcripts` and the ID form; a ledger file
  recreated by a simulated old binary after migration is detected and imported;
  `MANIFEST.tsv` alone suffices to restore the snapshot; a database with a newer
  `user_version` is refused with the newer-binary message.
- **Permissions:** `state.db`, `-wal`, `-shm`, `init.lock`, and lock files are
  `0600`; the state directory, `locks/`, and `migrated-v1/` are `0700`.
- **Crash safety:** kill mid-transaction → database passes `PRAGMA
  integrity_check` and the transaction is absent; with `synchronous=FULL`, a
  committed confirm survives a simulated post-commit crash; checkpoint-on-exit
  failure (`SQLITE_BUSY`) is tolerated silently.
- **Validation:** semantic validation failures (bad evidence ID, dangling
  speaker references, inconsistent per-model embedding dimensions) are rejected
  at save exactly as the JSON stores do, and the global example-identity unique
  index rejects the same duplicate the JSON validator rejects.

## Risks

- **SQLite version:** settled. The package already declares `.macOS(.v14)`
  (`Package.swift`), and macOS 14 ships SQLite 3.43+, far newer than any feature
  this design uses (WAL and `busy_timeout` date from 2010 and earlier). No new
  platform requirement.
- **Time Machine / backups:** a live WAL database can be backed up
  mid-transaction. Checkpointing on clean exit (`PRAGMA
  wal_checkpoint(TRUNCATE)`, best effort — it can return `SQLITE_BUSY` under
  concurrency) keeps the `-wal` file empty at rest, which is when backups
  normally run; `VACUUM INTO` is available later for an explicit backup command
  if wanted, and `export-legacy` already provides a plain-files snapshot.
- **History compaction stays out (R8):** decided. What is safe to delete depends
  on R8's completion-state-versus-audit-event distinction and R5's session
  identity, both unsettled; meanwhile 332 indexed rows cost nothing and the
  per-run re-parsing pain is fixed by the move itself. Verbatim rows make
  compaction a trivial, independently testable `DELETE` later.

## Future work

- FTS5 over segment text (`transcribe search`). The enabling decisions are
  already made — separate payload table, `encoding` column, plain-JSON payloads
  — so adding it is additive and needs no commitment here.
