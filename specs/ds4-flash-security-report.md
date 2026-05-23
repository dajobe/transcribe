# Deepseek 4 Flash Security Review of transcribe (v2.3.3)

**Review date:** 2026-05-18

*Scope:** All 31 Swift source files under `Sources/transcribe/`, shell scripts
under `scripts/`, package definition (`Package.swift`), Makefile, `.gitignore`,
state/config file paths, SQLite handling.

**Project:** On-device audio transcription using WhisperKit + SpeakerKit.
Local-only CLI tool for macOS (Apple Silicon). No network listeners, no web UI,
no remote API, no daemon mode.

---

## 1. Methodology

Each source file was reviewed for:

- Injection vulnerabilities (SQL, shell, path)
- Path traversal and symlink handling
- File permission issues
- Resource exhaustion
- Secure defaults and idempotency
- Dependency integrity
- Secret/key handling
- Concurrency and race conditions
- Overall attack surface

---

## 2. Severity Ratings

| Severity | Meaning                                                                                              |
|:---------|:-----------------------------------------------------------------------------------------------------|
| Critical | Remote code execution, privilege escalation, or data loss                                            |
| High     | Local code execution, bypass of a security mechanism, sensitive data leak                            |
| Medium   | Partial data leak, moderate integrity issue, insecure default that may matter in multi-user contexts |
| Low      | Limited-impact issue requiring specific conditions or a hardening opportunity                        |
| Info     | Best-practice observation, no immediate risk                                                         |

---

## 3. Findings

### 3.1 SQL Injection via Column Names in Voice Memos Import — MEDIUM

**File:** `Sources/transcribe/VoiceMemosImport.swift` **Lines:** ~47–68 (the
`columnOrNull` helper and the constructed SQL query)

```swift
func columnOrNull(_ name: String) -> String {
    columns.contains(name) ? name : "NULL"
}

let sql = """
    SELECT
      Z_PK,
      \(columnOrNull("ZUNIQUEID")),
      ZPATH,
      ZDATE,
      \(columnOrNull("ZDURATION")),
      ...
    FROM ZCLOUDRECORDING
    ...
"""
```

**Description:** The SQL `SELECT` statement is built by string-interpolating
column names obtained from the database schema itself (`loadColumnNames` reads
`PRAGMA table_info`). The column names are used directly as SQL identifiers
**without quoting**. Although `ZCLOUDRECORDING` is an Apple-maintained schema
read from `~/Library/Group
Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`,
nothing in the code validates that a column name is safe before embedding it.

**Impact:** If a column name contained a single quote, SQL comment marker
(`--`), or other control characters, it could alter the SQL statement's logic.
Because the database is opened with `SQLITE_OPEN_READONLY`, the damage is
limited to incorrect results, crashes, or denial of service — no writes are
possible. In practice, Apple's Voice Memos schema uses well-known column names
(`Z_PK`, `ZPATH`, `ZDATE`, `ZUNIQUEID`, etc.), so the realistic risk is low.
However, the pattern of interpolating untrusted strings into SQL is a
code-quality concern.

**Recommendation:** Quote column identifiers with backtick or double-quote
delimiters (e.g., `"\(name)"`) or validate that column names match a strict
pattern such as `^[A-Z][A-Z_]+$` before using them.

---

### 3.2 World-Readable Timing History File — MEDIUM

**Files:**

- `Sources/transcribe/TimingStore.swift` (line ~67)
- `Sources/transcribe/ProcessingStore.swift` (implicitly, via `Data.write(to:)`)

```swift
// TimingStore.swift
let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o644))
```

**Description:** The timing-history JSONL file (`timing_history.jsonl`) is
created with Unix permissions `0644` (world-readable). This file records:

- `input_basename` — the filename of the audio that was transcribed
- `model` — the Whisper model used
- `audio_duration_s`, `segment_count`, `speakers_detected` — performance
  metadata
- `ended_at` — ISO 8601 timestamp of the run

The processing-history file (`processing_history.jsonl`) written by
`ProcessingStore.swift` uses `Data.write(to:)` which also defaults to `0644` on
most Unix systems. It contains similar metadata plus `source_id` and
`source_kind`.

**Impact:** Any process on the system (including unrelated sandboxed apps,
background agents, or other users on a multi-user Mac) can read these files.
This leaks information about which audio files were transcribed, when, and with
what settings. On a single-user personal Mac the risk is low; on shared
workstations or macOS multi-user setups it is a meaningful data-exposure issue.

**Recommendation:** Change the creation mode to `0o600` (owner-only read/write).
For the `ProcessingStore.swift` path, create the file with explicit permissions
using `open()` + `flock` (same pattern as `TimingStore.swift`) or set
permissions after writing with
`FileManager.default.setAttributes(_:ofItemAtPath:)`.

---

### 3.3 No Input Size Limit — LOW

**Files:**

- `Sources/transcribe/AudioLoader.swift`
- `Sources/transcribe/TranscriptionPipeline.swift`

**Description:** Audio files are fully decoded into `[Float]` arrays in memory
with no size validation. A multi-gigabyte audio file would cause the process to
allocate a correspondingly large buffer (e.g., 4 hours of 16 kHz mono ≈ 230
million floats ≈ 920 MB).

**Impact:** The user controls the input, so this is self-inflicted resource
exhaustion. However, if the tool is used in automated pipelines (macOS Folder
Actions via `scripts/folder-action-transcribe.sh`, cron jobs, or Automator
workflows), a single large or corrupt file could consume all available memory
and trigger OOM kill by the OS.

**Recommendation:** Add a configurable `--max-audio-mb` option or a hard upper
bound (e.g., 2 GB uncompressed). Log a warning before loading files above a
threshold (e.g., >500 MB).

---

### 3.4 Symlink Following in Alias Path Resolution — LOW

**File:** `Sources/transcribe/PipelineRunner.swift` →
`SourcePlanner.modeForAliasPath`

```swift
static func modeForAliasPath(_ rawPath: String) throws -> SourceMode {
    let expanded = (rawPath as NSString).expandingTildeInPath
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else { ... }
    return isDir.boolValue ? .directory : .file
}
```

**Description:** `fileExists(atPath:isDirectory:)` follows symlinks by default.
A symlink pointing to a directory is treated as a directory source; a symlink
pointing to a file is treated as a file source. This is documented in
`SourcePlanner` as intended behavior, but the tool follows symlinks silently
without warning.

**Impact:** If an attacker (or untrusted source) can write a symlink into the
input directory, they could redirect processing to an unexpected file or
directory. The user controls the invocation, so this is a hardening concern
rather than an active vulnerability. In automated contexts (Folder Actions), the
input path comes from the Finder, which does not expose symlinks to unsandboxed
Automator scripts under normal circumstances.

**Recommendation:** Consider adding a `--follow-symlinks` flag (default off), or
log a warning when a resolved path is a symlink.

---

### 3.5 Unvalidated Output Directory Path — LOW

**Files:**

- `Sources/transcribe/ConfigMerge.swift`
- `Sources/transcribe/OutputWriter.swift`

**Description:** The `--output-dir` value (or `output.dir` from user config) is
used directly to construct output file paths. While tilde expansion is applied
(`expandingTildeInPath`), there is no validation that the resolved path is
within an expected subtree. A value like `/etc` or `/tmp/../sensitive` would be
accepted.

**Impact:** Self-inflicted misconfiguration. The user controls the value, so
this is not an external attack vector. However, if the tool is ever driven by an
external controller (e.g., a web service that accepts user-supplied output
paths), this would become a high-severity issue.

**Recommendation:** Canonicalize the output directory
(`URL.resolvingSymlinksInPath()`) and optionally reject paths that escape the
intended base (e.g., `$HOME/transcribe`).

---

### 3.6 Config File Permissions Not Enforced — INFO

**File:** `Sources/transcribe/ConfigPaths.swift`,
`Sources/transcribe/UserConfigFile.swift`

**Description:** The user config file (`config.json` under
`~/.config/transcribe/` or `XDG_CONFIG_HOME`) is read and written with default
file permissions. The tool does not check or enforce that the config file is
owner-only readable. On a multi-user system, the config may contain
user-specific preferences that are world-readable.

**Recommendation:** On read, warn if the config file is world-readable (`mode &
0o004 != 0`). On write, set mode `0600`.

---

### 3.7 Processing History Uses Default File Permissions — INFO

**File:** `Sources/transcribe/ProcessingStore.swift`

```swift
let data = try encoder.encode(record)
guard var line = String(data: data, encoding: .utf8) else { ... }
line.append("\n")
guard let out = line.data(using: .utf8) else { return }
try out.write(to: url)  // <-- no explicit permissions
```

**Description:** `Data.write(to:)` creates the file with default permissions
(`0644` typically). This is the same issue as Finding 3.2 but for the processing
history file.

**Recommendation:** Apply the same fix as 3.2 (use `open()` + `flock` with
`0600`, or `chmod` after write).

---

## 4. Positive Findings

These are security controls or design decisions that are notably
well-implemented.

### 4.1 SQLite Read-Only Database

**File:** `Sources/transcribe/SQLiteReader.swift`

The database is opened with `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`. This
prevents any writes to the Voice Memos SQLite database. The wrapper is minimal,
scoped to a single query, and properly finalizes statements in `defer`. No
injection into the SQLite file itself is possible.

### 4.2 POSIX File Locking for Concurrent Writes

**File:** `Sources/transcribe/TimingStore.swift`

Uses `flock(fd, LOCK_EX)` before appending to the timing history JSONL file.
This prevents interleaved writes from concurrent `transcribe` invocations. The
lock is released with `LOCK_UN` in `defer`.

### 4.3 Atomic File Writes

**File:** `Sources/transcribe/OutputWriter.swift`

The `writeAtomically` function writes to a temp file (with UUID in the name),
then renames/moves to the final path. This prevents partial output from being
visible and avoids truncation of existing files on write failure. The temp file
is cleaned up on error.

### 4.4 Overwrite Protection by Default

**File:** `Sources/transcribe/OutputWriter.swift` and
`Sources/transcribe/PipelineRunner.swift`

The `--overwrite` flag defaults to `false`. The pipeline runs an overwrite check
before starting the expensive transcription work (and again inside
`writeOutputs` as a guard). This prevents accidental data loss.

### 4.5 No Shell Invocations from Swift

All file system and process operations use `FileManager`, POSIX calls (`open`,
`flock`, `write`), or Foundation APIs. There are zero shell executions from
Swift code, eliminating command injection risk.

### 4.6 No Network Listeners

The application is entirely offline. WhisperKit and SpeakerKit models are
downloaded to a local cache at initialization, but all processing is on-device.
No HTTP servers, no UNIX sockets, no remote API endpoints.

### 4.7 Dependency Pinning

**File:** `Package.resolved`

Dependencies are pinned to specific versions. The `Package.swift` uses
`.from("0.17.0")` for WhisperKit (a semver range), but `Package.resolved` locks
exact versions in CI and release builds. Good supply-chain practice.

### 4.8 Processing History Is Append-Only

**File:** `Sources/transcribe/ProcessingStore.swift`

The `processing_history.jsonl` file is append-only: records are never
overwritten or deleted. This provides an audit trail and prevents tampering with
idempotency checks.

### 4.9 Input Validation on CLI Arguments

**File:** `Sources/transcribe/CLICommands.swift`,
`Sources/transcribe/TriState.swift`, `Sources/transcribe/ComputeOptions.swift`

All CLI arguments are validated: mutually exclusive flags are rejected, speaker
counts are checked for positive values, output formats are validated against a
known set, and compute units are checked for validity. The `TriState` pattern
ensures that omitted vs. explicitly-set values are distinguishable at merge
time.

### 4.10 Path Traversal Fix in Output Prefix

**File:** `Sources/transcribe/OutputWriter.swift`

The `outputBasename` is checked for `/` or `..` before use, preventing path
traversal via `--output-prefix`. (Fixed 2026-03-22, noted in TODO.md.)

### 4.11 Unpredictable Temp File Names

**File:** `Sources/transcribe/OutputWriter.swift`

Temp file names use `UUID().uuidString`, making them unpredictable. The previous
PID-based naming was replaced. (Fixed 2026-03-22, noted in TODO.md.)

---

## 5. Summary Table

| # | Finding                        | Severity   | File(s)                                            | Status |
|:---|:-------------------------------|:-----------|:---------------------------------------------------|:-------|
| 1 | SQL injection via column names | **Medium** | `VoiceMemosImport.swift`                           | Open   |
| 2 | World-readable timing history  | **Medium** | `TimingStore.swift`, `ProcessingStore.swift`       | Open   |
| 3 | No input size limit            | Low        | `AudioLoader.swift`, `TranscriptionPipeline.swift` | Open   |
| 4 | Symlink following              | Low        | `PipelineRunner.swift`                             | Open   |
| 5 | Unvalidated output directory   | Low        | `ConfigMerge.swift`, `OutputWriter.swift`          | Open   |
| 6 | Config file permissions        | Info       | `ConfigPaths.swift`, `UserConfigFile.swift`        | Open   |
| 7 | Processing history permissions | Info       | `ProcessingStore.swift`                            | Open   |
| — | SQLite read-only               | ✅ Positive | `SQLiteReader.swift`                               | —      |
| — | POSIX flock                    | ✅ Positive | `TimingStore.swift`                                | —      |
| — | Atomic writes                  | ✅ Positive | `OutputWriter.swift`                               | —      |
| — | Overwrite protection           | ✅ Positive | `OutputWriter.swift`, `PipelineRunner.swift`       | —      |
| — | No shell invocations           | ✅ Positive | All Swift sources                                  | —      |
| — | No network listeners           | ✅ Positive | All Swift sources                                  | —      |
| — | Dependency pinning             | ✅ Positive | `Package.resolved`                                 | —      |
| — | Append-only ledger             | ✅ Positive | `ProcessingStore.swift`                            | —      |
| — | CLI input validation           | ✅ Positive | `CLICommands.swift`, `TriState.swift`              | —      |
| — | Path traversal fix             | ✅ Positive | `OutputWriter.swift`                               | —      |
| — | Unpredictable temp names       | ✅ Positive | `OutputWriter.swift`                               | —      |

---

## 6. Recommended Fixes (Priority Order)

1. **Quote SQL column identifiers** in `VoiceMemosImport.swift` — wrap column
   names in double quotes (`"\(name)"`) or validate against `^[A-Z][A-Z_0-9]*$`.
   This eliminates the SQL injection path.

2. **Set timing history permissions to `0600`** in `TimingStore.swift` line 67.
   Apply the same fix to `ProcessingStore.swift` (use `open()` + `flock`
   pattern, or `chmod` after `Data.write`).

3. **Add a maximum input size guard** in `AudioLoader.swift` or
   `TranscriptionPipeline.swift` — either a hard limit (e.g., 2 GB uncompressed)
   or a configurable `--max-audio-mb` option. Log a warning before loading large
   files.

4. **Canonicalize output directory paths** in `ConfigMerge.swift` or
   `OutputWriter.swift` — resolve symlinks and reject paths that escape the
   intended base directory.

5. **Warn on world-readable config file** — on `config show` or `config set`,
   check if `config.json` is world-readable and emit a warning to stderr.

---

## 7. Attack Surface Diagram

```
┌───────────────────────────┐
│        User CLI           │  ← ArgumentParser input validation
│      (stdin / args)       │     Rejects unknown flags, validates options
└────┬──────────────────┬───┘
     │                  │
     ▼                  ▼
┌─────────────┐   ┌──────────────┐
│  WhisperKit  │   │  SpeakerKit  │  ← On-device ML, no network
│  (local ML)  │   │  (local ML)  │     Models cached on disk
└─────────────┘   └──────────────┘
     │                  │
     ▼                  ▼
┌──────────────────────────────┐
│   Output files (txt/json/    │  ← Atomic writes, overwrite check
│   srt/vtt/md)                │     Temp file with UUID, then rename
│   + history JSONL files      │     flock for concurrent writes
└──────────────────────────────┘
```

All data flows are local. The two medium-severity findings (SQL injection path
via column names, world-readable timing files) are the most actionable. No
critical or high-severity vulnerabilities were identified.

---

## 8. Conclusion

The **transcribe** codebase is well-structured with strong security hygiene:

- **Atomic file operations** prevent partial/corrupt output
- **No shell commands** eliminate command injection
- **No network listeners** keep the attack surface narrow
- **Dependency pinning** ensures supply-chain integrity
- **Overwrite protection** and **append-only ledgers** protect data

Two **medium-severity** issues should be fixed:

1. SQL column names interpolated into queries without quoting
2. Timing/processing history files created world-readable

Four **low-severity** hardening items (input size limit, symlink handling,
output path validation, config file permissions) are recommended but not urgent.

The tool is safe for its intended use case: a local CLI for personal audio
transcription on a single-user Mac.

---

## 9. Follow-up evaluation and remediation (v2.4.0)

**Evaluation date:** 2026-05-23

**Reviewer:** Implementation pass following this report (Cursor /
Claude)

**Version addressed:** v2.4.0 (security hardening release)

This section records an independent evaluation of the Deepseek 4 Flash report
against the codebase at remediation time, what was correct or overstated in the
original findings, and what was actually changed.

### 9.1 Overall assessment of the report

The report is **accurate and useful** for a local-only macOS CLI. Methodology,
severity framing, positive findings (§4), and the attack-surface summary (§7–§8)
all match the code. No critical or high-severity remote-exploitation paths
exist. The two medium findings were the right priorities for action.

Minor inaccuracies in the original write-up (detailed below) do not undermine
the report; they mostly affect how urgently each item needed a code change
versus defensive hardening.

### 9.2 Finding-by-finding evaluation

| #   | Report claim                                | Verdict                            | Notes                                                                                                                                                                                                                                                                                                |
|:----|:--------------------------------------------|:-----------------------------------|:-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 3.1 | SQL injection via interpolated column names | **Partially overstated**           | `columnOrNull` only ever embeds **hardcoded** Swift literals (`"ZUNIQUEID"`, etc.). `PRAGMA table_info` is used for `.contains()` membership checks, not to build identifiers from schema text. Real exploitability was near-zero with read-only DB access. The *pattern* was still worth hardening. |
| 3.2 | World-readable timing history (`0644`)      | **Correct**                        | Confirmed at `TimingStore.swift` `open(..., 0o644)`. Meaningful on multi-user systems.                                                                                                                                                                                                               |
| 3.3 | No audio size limit                         | **Correct**                        | Full in-memory decode with no guard; relevant for Folder Actions / automation.                                                                                                                                                                                                                       |
| 3.4 | Symlink following without warning           | **Correct**                        | Documented intentional behavior; silent follow was the issue, not follow itself.                                                                                                                                                                                                                     |
| 3.5 | Unvalidated output directory                | **Correct but low urgency**        | Self-inflicted misconfiguration for a CLI; canonicalization was appropriate; base-dir confinement was not.                                                                                                                                                                                           |
| 3.6 | Config file permissions                     | **Correct**                        | Default permissions on read/write; info-level but easy to fix.                                                                                                                                                                                                                                       |
| 3.7 | Processing history default permissions      | **Correct issue, wrong mechanism** | At review time `ProcessingStore` already used `open()` + `flock`, not `Data.write(to:)` as quoted in §3.7. The bug was mode `0644`, same as 3.2.                                                                                                                                                     |

**Positive findings (§4):** All confirmed unchanged and still valid after
remediation.

**Not covered in report (noted during remediation):**
`scripts/folder-action-transcribe.sh` word-splits `TRANSCRIBE_EXTRA_ARGS`;
injection is only possible if that environment variable is attacker-controlled.
Left out of scope.

### 9.3 Remediation summary (v2.4.0)

All seven open findings were addressed. Implementation choices where the report
offered alternatives:

| #        | Fix applied                                                                                                                                         | Deliberate deviations from report                                                                                                                         |
|:---------|:----------------------------------------------------------------------------------------------------------------------------------------------------|:----------------------------------------------------------------------------------------------------------------------------------------------------------|
| 3.1      | `isSafeColumnName()` validator; double-quoted identifiers in SELECT; fail closed if schema contains unexpected names                                | Used character validation instead of regex literals (Swift portability). Hardening is defensive — original code did not interpolate PRAGMA-derived names. |
| 3.2, 3.7 | New `LockedAppendWriter.swift`: `open(O_APPEND)` + `flock(LOCK_EX)` + `fchmod(0600)` on every append; shared by `TimingStore` and `ProcessingStore` | Also tightens **existing** world-readable files on next append, not only new creates.                                                                     |
| 3.3      | `--max-audio-mb` (default 2048; `0` disables); `input.maxAudioMB` in config; warn when on-disk file > 500 MB; hard cap after decode                 | Wired through `ConfigMerge` / pipeline, not only `AudioLoader`.                                                                                           |
| 3.4      | `warnIfSymlink()` in `SourcePlanner` (alias, file, dir validators)                                                                                  | **Warn-only** — did not add `--follow-symlinks` default-off, which would break documented working symlink use.                                            |
| 3.5      | `resolvedOutputDir()` now uses `standardizedFileURL.resolvingSymlinksInPath()`                                                                      | Did **not** reject paths outside `$HOME` (would break `/tmp`, external drives, iCloud).                                                                   |
| 3.6      | `UserConfigFile.save` sets mode `0600`; `warnIfWorldReadable` on load (covers `config show` / `get` / `set` via `loadOrEmpty`)                      | Warning fires on any config read path that loads the file.                                                                                                |

### 9.4 Tests added

- `FilePermissionsTests` — owner-only mode on create and on tighten-after-append
- `VoiceMemosImportTests.testUnsafeColumnNameThrowsInputError` — invalid schema
  name rejected
- `AudioLoaderTests` — limit math helpers
- `OutputWriterTests.testResolvedOutputDirFollowsSymlinkComponent` — canonical
  output dir
- `UserConfigFileTests` — `0600` on save; world-readable warning on load
- `CLITests` — `--max-audio-mb` help and validation; symlink input warning

Full suite: 181 tests passing after remediation.

### 9.5 Updated status table

| # | Finding                        | Severity | Status (v2.4.0)                                            |
|:---|:-------------------------------|:---------|:-----------------------------------------------------------|
| 1 | SQL column identifier handling | Medium   | **Fixed** — validation + quoting                           |
| 2 | World-readable timing history  | Medium   | **Fixed** — `LockedAppendWriter` `0600`                    |
| 3 | No input size limit            | Low      | **Fixed** — `--max-audio-mb` + warnings                    |
| 4 | Symlink following              | Low      | **Mitigated** — warning on symlink input (follow retained) |
| 5 | Unvalidated output directory   | Low      | **Fixed** — symlink canonicalization                       |
| 6 | Config file permissions        | Info     | **Fixed** — `0600` on write, warn on world-readable read   |
| 7 | Processing history permissions | Info     | **Fixed** — same as #2 via `LockedAppendWriter`            |

### 9.6 Conclusion

The original report correctly identified the security posture of **transcribe**
as strong for a personal local CLI, with two actionable medium issues and
several low/info hardening opportunities. Finding 3.1 was **more severe on paper
than in practice** because column names in the query were hardcoded, not read
from the schema; finding 3.7 **misidentified the write path** but correctly
identified the permission mode.

v2.4.0 closes all listed items without changing the fundamental threat model:
local user, local files, no network listeners, no shell from Swift. Remaining
residual risk is limited to optional shell wrappers and dependency-trusted model
downloads — unchanged from §8.
