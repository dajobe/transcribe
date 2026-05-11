# Processing History Reason Labels

## Summary

`transcribe history` should show how each record entered the processing history.
The command remains compact and column-oriented, but adds a `WHY` column with a
short reason label.

New processing-history rows store the reason as a stable machine value.
Duplicate skips are also appended to history, making the ledger an audit trail
of both processed and skipped decisions.

## Output

Example:

```text
WHEN              WHY          KIND    RECORDED      FILE
just now          first run    voice   2026-05-09    fresh.m4a
2 mins ago        skip dup     voice   2026-05-09    fresh.m4a
8 mins ago        settings     file    -             interview.m4a
12 mins ago       missing out  file    -             interview.m4a
1 hour ago        imported     voice   2014-05-13    Memo5.m4a
```

Reason labels:

| Label          | Stored value       | Meaning                                                                                                      |
|:---------------|:-------------------|:-------------------------------------------------------------------------------------------------------------|
| `first run`    | `first_run`        | No prior matching history entry caused this run.                                                             |
| `skip dup`     | `skip_duplicate`   | Skipped because the input matched prior completed or imported history.                                       |
| `settings`     | `settings_changed` | Reprocessed because model, language, speaker settings, output formats, version, or similar settings changed. |
| `missing out`  | `missing_outputs`  | Reprocessed because matching prior output files were missing.                                                |
| `redo`         | `redo`             | Reprocessed because `--redo` ignored processing history.                                                     |
| `imported`     | `imported`         | Entered history through `--mark-imported`.                                                                   |
| `changed file` | `changed_file`     | Reprocessed because the source identity matched but audio bytes changed.                                     |
| `legacy`       | `legacy`           | Older history row without enough stored reason data.                                                         |

## Ledger Behavior

Processing history records include an optional `history_reason` field. Existing
JSONL records remain readable without migration:

- Baseline import records without `history_reason` render as `imported`.
- Other records without `history_reason` render as `legacy`.

Normal duplicate skips append a new row unless `--stateless` or `--dry-run` is
active. Skip rows preserve source kind, source id, fingerprint, basename,
requested output paths, and metadata, but do not set audio duration or warning
counts as if transcription had run.

## Decision Rules

Reason selection is based on the first decisive history match:

- Exact source, fingerprint, settings, and existing outputs: `skip dup`.
- Exact source with different fingerprint: `changed file`.
- Exact source and fingerprint with changed settings or requested output paths:
  `settings`.
- Exact source and fingerprint with matching settings but missing outputs:
  `missing out`.
- Path-agnostic content matches with compatible settings and existing outputs:
  `skip dup`.
- `--redo` processing rows: `redo`.
- `--mark-imported` rows: `imported`.
- No decisive prior match: `first run`.
