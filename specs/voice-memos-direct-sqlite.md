# Voice Memos: Read `CloudRecordings.db` Without Shelling Out

## Goal

Replace the `Process`-based `/usr/bin/sqlite3` calls in
[`Sources/transcribe/VoiceMemosImport.swift`](../Sources/transcribe/VoiceMemosImport.swift)
with **in-process, read-only** SQLite access. Keep behavior, schema-tolerance,
and error reporting identical so existing tests and the
[voice-memos-cli-cleanup.md](voice-memos-cli-cleanup.md) contract still hold.

This spec documents the design and trade-offs only; the code change is a
follow-up.

## Current state

[`VoiceMemosImport.swift`](../Sources/transcribe/VoiceMemosImport.swift) issues
two queries by spawning the system `sqlite3` binary:

- `runSQLiteQuery` (lines 170-202) runs
  `/usr/bin/sqlite3 -init /dev/null -readonly -batch -list -separator <US> ...`
  and parses stdout split by `\n` and `\u{1f}`.
- `loadColumnNames` (lines 204-210) reuses the same path with
  `PRAGMA table_info(ZCLOUDRECORDING)`.

Consequences:

- Each call is a **fork+exec** of `/usr/bin/sqlite3`.
- Every value crosses a **text boundary**, so blobs (`ZAUDIODIGEST`) need a SQL
  `hex(...)` wrapper, and `NULL`s are smuggled through `IFNULL(..., '')` empty
  strings that the Swift side later disambiguates with `nilIfEmpty`.
- Errors arrive as a stderr string; the helper attaches a Full Disk Access hint
  and re-raises a [`TranscribeError`](../Sources/transcribe/Errors.swift).

## Options

### Option A (recommended): system SQLite3 via `import SQLite3`

macOS ships **libsqlite3** and a Swift module map. `xcrun --show-sdk-path`
points at an SDK whose `usr/include/sqlite3.h` is present, so `import SQLite3`
works with **no** changes to [`Package.swift`](../Package.swift), no extra
linker flags, and no new dependency.

Mechanics:

- Open with
  `sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)`.
- Prepare/step/finalize with `sqlite3_prepare_v2`, `sqlite3_step`,
  `sqlite3_finalize`.
- Read columns with `sqlite3_column_int64`, `sqlite3_column_double`,
  `sqlite3_column_text`, `sqlite3_column_blob` + `sqlite3_column_bytes`.
- Use real `SQLITE_NULL` checks instead of `IFNULL(..., '')` sentinels.
- Read `ZAUDIODIGEST` directly as a blob and hex-encode in Swift, dropping the
  SQL `hex(...)` wrapper.

#### Pros

- **Zero new dependencies**; smallest blast radius.
- No subprocess, no PATH/Full Disk Access weirdness from a second process, no
  text-boundary parsing.
- **Real typing**: blobs, doubles, ints, and nullability are first-class.
- **Faster** for many rows; one DB handle, prepared statements, no fork+exec.
- Read-only is enforced at open time via `SQLITE_OPEN_READONLY`, matching
  today's `-readonly` flag.

#### Cons

- The C API is verbose; we need a small Swift wrapper (a `Database` /
  `Statement` pair) to keep call sites readable. Estimate ~80-120 lines added
  in a new file
  ([`Sources/transcribe/SQLiteReader.swift`](../Sources/transcribe/SQLiteReader.swift)
  if reused later, otherwise file-private inside `VoiceMemosImport.swift`).
- Manual lifecycle: every prepared statement needs `sqlite3_finalize` and the
  connection needs `sqlite3_close_v2`, both via `defer`.
- `SQLITE_TRANSIENT` discipline applies to any **bound** text. We don't bind
  user input today; if that changes the rule must be documented.
- Slightly more code than the current shell-out, but with simpler runtime
  behavior.

### Option B: add a Swift SQLite wrapper as a SwiftPM dependency

Candidates: [GRDB.swift](https://github.com/groue/GRDB.swift),
[stephencelis/SQLite.swift](https://github.com/stephencelis/SQLite.swift).

#### Pros

- Idiomatic Swift API, easy column decoding, query builders.
- Battle-tested.

#### Cons

- A new dependency for **one** query in **one** file. GRDB is large;
  SQLite.swift is smaller but still adds source and build-time surface.
- Increases binary size and resolved-package surface for very little gain.
- The project intentionally minimizes deps; today
  [`Package.swift`](../Package.swift) only pulls in WhisperKit and
  swift-argument-parser.

### Option C: keep the subprocess, just tidy

Leave `Process` in place; centralize separator/encoding handling in one helper.

#### Pros

- Zero risk; the current code works.

#### Cons

- Still pays fork+exec per call; still parses text streams; still hex-encodes
  blobs in SQL.
- Doesn't address the "clunky" complaint and leaves the unit-separator parsing
  as a permanent foot-gun.

## Recommendation

**Option A.** It removes the subprocess and text parsing, gains real types and
null handling, costs no new dependencies, and keeps read-only enforcement at
the SQLite open flag.

## Implementation sketch (follow-up change)

1. Introduce a tiny internal helper, either file-private inside
   [`VoiceMemosImport.swift`](../Sources/transcribe/VoiceMemosImport.swift) or
   a new `Sources/transcribe/SQLiteReader.swift` if reused later:
    - `final class ReadOnlyDatabase` whose `init(path:) throws` calls
      `sqlite3_open_v2(..., SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)`
      and closes via `sqlite3_close_v2` on `deinit`.
    - `func query<T>(_ sql: String, map: (Statement) throws -> T) throws -> [T]`
      that prepares, steps, finalizes, and re-throws a `TranscribeError` on
      failure.
    - A small `Statement` value type exposing typed accessors:
      `int(_:)`, `double(_:)`, `text(_:)`, `blob(_:)`, `isNull(_:)`,
      `columnCount`, and `columnName(_:)`.
2. Replace `runSQLiteQuery` and `loadColumnNames` in
   [`VoiceMemosImport.swift`](../Sources/transcribe/VoiceMemosImport.swift):
    - `loadColumnNames` runs `PRAGMA table_info(ZCLOUDRECORDING)` and collects
      the `name` column into a `Set<String>`.
    - The main query drops every `IFNULL(..., '')` wrapper in favor of
      Swift-side `isNull` checks. It drops `hex(ZAUDIODIGEST)`; the blob is
      hex-encoded in Swift to populate `audioDigestHex`.
3. Map SQLite errors to existing
   [`TranscribeError`](../Sources/transcribe/Errors.swift) values with the
   same wording (Full Disk Access hint preserved). Distinguish
   "file does not exist" (already handled before opening) from
   "cannot open / authorization denied" (`SQLITE_CANTOPEN`, `SQLITE_AUTH`).
4. Keep all public API of `VoiceMemosImport` unchanged. Behavior must match
   for both the happy path and the missing-required-column /
   missing-audio-file branches that the existing tests exercise.
5. In the test target, add `SQLiteTestHelpers.executeScript(at:_:)` that
   opens the fixture file with `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE`
   and runs multi-statement SQL via `sqlite3_exec`, then route both fixture
   helpers (`VoiceMemosImportTests.sqlite(_:_:)` and
   `CLITests.createVoiceMemosDB(...)`) through it. Drop the `XCTSkipIf`
   guards on `/usr/bin/sqlite3` since nothing in the suite needs the CLI.

## Test impact

Test fixtures are also moved off the `/usr/bin/sqlite3` subprocess so the
suite has zero dependency on the system CLI:

- New file
  [`Tests/transcribeTests/SQLiteTestHelpers.swift`](../Tests/transcribeTests/SQLiteTestHelpers.swift)
  exposes `SQLiteTestHelpers.executeScript(at:_:)`, which opens with
  `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE` and runs multi-statement SQL via
  `sqlite3_exec`. This helper is **test-only**; production stays read-only.
- The fixture helpers in
  [`Tests/transcribeTests/VoiceMemosImportTests.swift`](../Tests/transcribeTests/VoiceMemosImportTests.swift)
  and
  [`Tests/transcribeTests/CLITests.swift`](../Tests/transcribeTests/CLITests.swift)
  delegate to `SQLiteTestHelpers.executeScript` instead of spawning
  `/usr/bin/sqlite3`.
- All `XCTSkipIf(!isExecutableFile("/usr/bin/sqlite3"))` guards are removed
  (7 in `VoiceMemosImportTests`, 2 in `CLITests`).
- New tests exercise blob retrieval through the new code path:
  `testAudioDigestBlobIsHexEncodedInSwift` (writes `x'DEADBEEF'`, expects
  `"DEADBEEF"`) and `testAudioDigestNullBlobYieldsNil`.
- All existing cases
  (`testLoadsConfirmedCloudRecordingSchema`,
  `testTitleFallbackAndUniqueIDFallback`,
  `testMissingOptionalColumnsStillLoadsRecording`,
  `testMissingRequiredColumnThrowsInputError`,
  `testMissingAudioFileIsSkipped`)
  continue to pass unchanged.
- Voice Memos test runtime drops from ~0.8s to ~0.01s thanks to removing
  fork+exec per fixture.

## Risks and notes

- **macOS SDK module**: `import SQLite3` resolves through the system module
  map; the SDK header is verified present at the workspace's current Xcode
  SDK.
- **Threading**: `loadRecordings` is called once per run on a single thread;
  `SQLITE_OPEN_NOMUTEX` is safe.
- `sqlite3_busy_timeout` is unnecessary for read-only access; the database
  file is normally not contended.
- No bound parameters today, so `SQLITE_TRANSIENT` is not on the critical
  path; if user-controlled input is ever bound, document the rule at that
  time.

## Out of scope

- Any schema discovery beyond what `loadColumnNames` already does.
- Any new Voice Memos columns or behaviors.
