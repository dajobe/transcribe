# User configuration (`transcribe config`)

This document describes the XDG-based user configuration file (always **JSON**
on disk), hierarchical keys, merge precedence with CLI flags, tristate booleans,
and the `transcribe config` subcommands.

## Config file location

Configuration is stored separately from **application state** (processing
history, timing ledger):

| Purpose    | Location                                                                                                                                                         |
|:-----------|:-----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Config** | `$XDG_CONFIG_HOME/transcribe/config.json` if `XDG_CONFIG_HOME` is set; otherwise `~/.config/transcribe/config.json` — **including on macOS** (XDG-style layout). |
| **State**  | See runtime state paths (`XDG_STATE_HOME`, Application Support, etc.); unchanged.                                                                                |

Override for tests or tooling: set **`TRANSCRIBE_CONFIG`** to an absolute path
of a JSON file.

If no file exists, all settings behave as built-in defaults. The **only**
persisted format is **JSON** (`config.json`). `transcribe config show` prints
**dotted `key value` lines** (values shell-quoted when they contain spaces or
similar characters) using the same key names as `config get` / `set` / `unset`.
When the effective value differs from the **built-in default**, the line ends
with **`(default DEFAULT)`** so overrides are obvious. **Display order** (blank
line between groups, sorted within each): ultra-common flat keys (`model`,
`format`, `language`), then `output.*`, `cache.*`, `speakers.*`, `compute.*`,
`logging.*`, then `dir.*`, then `voiceMemos.*`. **Do not** paste `show` lines
blindly into `config set`; split key and quoted value, or edit JSON. Edit JSON
by hand or use `config get` / `set` / `unset`.

## Precedence

For each setting:

1. **CLI** — if the user supplied an explicit value (including explicit boolean
   flags), that wins.
2. **User config file** — otherwise values from `config.json`.
3. **Defaults** —
   [`TranscriptionDefaults`](../Sources/transcribe/TranscriptionDefaults.swift)
   / [`Transcribe.defaultModel`](../Sources/transcribe/main.swift).

Flags that affect safety or one-shot behavior are **not** stored in the config
file: `--overwrite`, `--redo`, `--dry-run` / `--dryrun`, `--mark-imported`,
`--stateless`. They remain CLI-only.

## JSON shape

Ultra-common options stay as **top-level** JSON keys (`model`, `format`,
`language`) so they stay easy to spot. Other settings are grouped in nested
objects whose structure matches the **dotted** names used by `config get` /
`set` / `show` (e.g. `output.dir` → `"output": { "dir": "..." }`).

```json
{
  "model": "openai_whisper-large-v3_turbo",
  "format": "txt,json,md",
  "language": "en",
  "output": {
    "dir": "./transcripts",
    "prefix": null
  },
  "cache": {
    "modelDir": "~/.cache/transcribe"
  },
  "speakers": {
    "enabled": true,
    "merge": "subsegment",
    "min": 2,
    "max": null
  },
  "compute": {
    "audioEncoder": "auto",
    "textDecoder": "auto",
    "segmenter": "auto",
    "embedder": "auto"
  },
  "logging": {
    "level": "info",
    "verbose": false,
    "etaHints": null,
    "progressLog": "auto"
  },
  "dir": {
    "sessionGap": 15,
    "sort": "recorded",
    "inputTimeSource": "auto",
    "sessionNaming": "auto"
  },
  "voiceMemos": {
    "sessionGap": 10,
    "recordingsDir": "~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
  }
}
```

### Tristate booleans (file)

For boolean preferences exposed in the file:

- **Key absent** or **`null`** → **omitted** (fall through to defaults).
- **`true`** / **`false`** → explicit value after CLI is applied.

For booleans in the file, **omitted** / **`null`** still mean “fall through
after CLI.” On the CLI, overlapping preferences use positive pairs where needed
(e.g. `--with-speakers` / `--transcript-only`); logging accepts
`--log-level debug|info|warn|error`, with `--verbose` as debug shorthand and
`--quiet` as warn shorthand. Other settings use explicit values such as
`--eta-hints on|off` or `--progress-log auto|plain|off`.

## Key catalog (dotted names for CLI; JSON nesting)

**Flat (ultra-common):**

| Key        | JSON      | Semantics                               |
|:-----------|:----------|:----------------------------------------|
| `model`    | top-level | Whisper model id                        |
| `language` | top-level | Language code; omit key for auto-detect |
| `format`   | top-level | Comma-separated formats or `all`        |

**`output.*` →** `"output": { ... }`

| Key             | JSON field      | Semantics                                                                                    |
|:----------------|:----------------|:---------------------------------------------------------------------------------------------|
| `output.dir`    | `output.dir`    | Output directory (`-o`)                                                                      |
| `output.prefix` | `output.prefix` | Optional string; when omitted / `(none)`, basename is derived from the input (see main docs) |

**`cache.*` →** `"cache": { ... }`

| Key              | JSON field       | Semantics                            |
|:-----------------|:-----------------|:-------------------------------------|
| `cache.modelDir` | `cache.modelDir` | Model download cache (`--model-dir`) |

**`speakers.*` →** `"speakers": { ... }`

| Key                | JSON field         | Semantics                                           |
|:-------------------|:-------------------|:----------------------------------------------------|
| `speakers.enabled` | `speakers.enabled` | Tri-state; when effective is false, transcript-only |
| `speakers.merge`   | `speakers.merge`   | `subsegment` or `segment`                           |
| `speakers.min`     | `speakers.min`     | Optional int                                        |
| `speakers.max`     | `speakers.max`     | Optional int                                        |

**`compute.*` →** `"compute": { ... }` — each value is a
[`ComputeUnitsOption`](../Sources/transcribe/ComputeOptions.swift) raw string
(`auto`, `cpuOnly`, …):

| Key                    | JSON field             |
|:-----------------------|:-----------------------|
| `compute.audioEncoder` | `compute.audioEncoder` |
| `compute.textDecoder`  | `compute.textDecoder`  |
| `compute.segmenter`    | `compute.segmenter`    |
| `compute.embedder`     | `compute.embedder`     |

**`logging.*` →** `"logging": { ... }`

| Key                   | JSON field            | Semantics                                                                                                                        |
|:----------------------|:----------------------|:---------------------------------------------------------------------------------------------------------------------------------|
| `logging.level`       | `logging.level`       | String: `debug`, `info`, `warn`, or `error`; overrides legacy `logging.verbose`                                                  |
| `logging.verbose`     | `logging.verbose`     | Legacy tri-state shorthand: `true` = `debug`, `false` = `info`                                                                   |
| `logging.etaHints`    | `logging.etaHints`    | Tri-state; env `TRANSCRIBE_ETA_HINTS=0` (or legacy `TRANSCRIBE_TIMING_STATS=0`) still disables when merged effective would be on |
| `logging.progressLog` | `logging.progressLog` | String: `auto`, `plain`, or `off`                                                                                                |

`dir.*` (directory source defaults):

| Key                   | Semantics                                                                                          |
|:----------------------|:---------------------------------------------------------------------------------------------------|
| `dir.sort`            | `recorded`, `name`, or `mtime`                                                                     |
| `dir.sessionGap`      | Minutes between sessions (integer ≥ 0)                                                             |
| `dir.inputTimeSource` | `auto`, `embedded`, `filename`, or `off` (filename-prefix time recovery when `auto` or `filename`) |
| `dir.sessionNaming`   | `auto`, `clip`, or `off` (auto prefix–based session basenames when `auto`)                         |

`voiceMemos.*`:

| Key                        | Semantics                      |
|:---------------------------|:-------------------------------|
| `voiceMemos.recordingsDir` | Path to Voice Memos recordings |
| `voiceMemos.sessionGap`    | Session gap in minutes         |

## CLI: `transcribe config`

| Subcommand                 | Description                                                                                                                   |
|:---------------------------|:------------------------------------------------------------------------------------------------------------------------------|
| `config show`              | Print effective settings as dotted `key value` lines; annotate overrides with `(default …)` (sorted per group; display only). Optional `# …` lines immediately before a key document unset semantics when the displayed value is `(none)` or `(auto)` (same wording as `transcribe --help` for those options). |
| `config get <key>`         | Print one **dotted** key’s effective value (e.g. `dir.sessionGap`; same names as `set` / `unset`).                            |
| `config set <key> <value>` | Validate and write override (atomically).                                                                                     |
| `config unset <key>`       | Remove key from file (nested keys supported).                                                                                 |
| `config path`              | Print resolved config file path.                                                                                              |

## Migration

If you previously used an unofficial or Application Support–based config path,
copy the JSON file to `~/.config/transcribe/config.json` (or
`$XDG_CONFIG_HOME/transcribe/config.json`).

## Examples

Example `transcribe config show` shape (dotted keys match `get`/`set`; values
illustrative; sorted within each group). Lines with **`(default …)`** only
appear when the effective value differs from the built-in default. **`#` lines**
(not valid for `config set`) appear only when the displayed value is **`(none)`**
or **`(auto)`** (for `language`), and explain unset semantics for those keys
(same wording as global `--help`).

```text
format txt,json
# When omitted or (auto), Whisper auto-detects the language.
language (auto)
model openai_whisper-large-v3_turbo

output.dir .
# When omitted, the output basename is derived from the input path.
output.prefix "(none)"

cache.modelDir ~/.cache/transcribe

speakers.enabled true
# When omitted, no maximum speaker-count hint is applied.
speakers.max "(none)"
# When omitted, no minimum speaker-count hint is applied.
speakers.min "(none)"
speakers.merge subsegment

compute.audioEncoder auto
compute.embedder auto
compute.segmenter auto
compute.textDecoder auto

logging.etaHints true
logging.level info
logging.progressLog auto
logging.verbose false

dir.inputTimeSource auto
dir.sessionGap 10
dir.sessionNaming auto
dir.sort recorded

voiceMemos.recordingsDir "~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
voiceMemos.sessionGap 10
```

This layout is for **terminal viewing only**; the authoritative store is always
JSON in `config.json`.

```bash
# Show everything including defaults when no file exists
transcribe config show

transcribe config set format md,json
transcribe config set output.dir ./transcripts
transcribe config set dir.sessionGap 20
transcribe config unset model

# Run using merged defaults (no global overrides on CLI)
transcribe file meeting.m4a
```
