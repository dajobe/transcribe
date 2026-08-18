# CLI Output and Batch Logs

## Summary

`transcribe` has two processing-output modes controlled by `--progress-log`:

- `auto`: live stdout TUI when stdout is a terminal; stdout text event logs when
  stdout is not a terminal.
- `plain`: stdout text event logs.
- `off`: no processing/status events. Warnings may still be emitted as stdout
  warning events.

Dry-run, help, version, config, and history commands keep their existing
report-style stdout output. Transcript content is always written to output
files; there is no transcript-to-stdout processing mode.

## Interactive TUI

Interactive processing writes the live progress block to stdout. Before the
phase rows, the block shows stable run context:

```text
Session: 1/3
Input: clip.m4a
Output: clip (txt,json) -> /tmp/out [clip.txt, clip.json]
Model: openai_whisper-large-v3-v20240930_turbo
```

The phase rows retain the icon based status display:

- blank icon: not started
- `▶`: running, with elapsed time and ETA when available
- `✓`: finished, with final elapsed time only
- `✕`: failed, with elapsed time until failure

The final TUI snapshot remains visible after completion.

### TUI Diagnostics

When interactive TUI mode is active, non-`INFO` structured events are rendered
inside the progress block instead of falling through to stderr. `INFO` events
remain represented by the phase rows and run context.

The diagnostics block appears below phase rows, keeps the last five diagnostic
events, and remains visible in the final TUI snapshot:

```text
Diagnostics:
  DEBUG event=verbose elapsed_s=4.2 message="loaded model cache metadata"
```

When older diagnostics have been truncated, the heading includes the total:

```text
Diagnostics (last 5 of 12):
```

Diagnostics use compact logfmt without timestamps: uppercase level, event name,
fields, then optional message. `--log-level debug` and `--verbose` show `DEBUG`
diagnostics. Warnings and handled errors show as `WARN`/`ERROR` diagnostics when
they meet the configured minimum log level. On handled fatal errors, the final
snapshot shows `✕ Total: failed after <elapsed>` and unfinished phases are not
marked successful.

The live TUI is currently shown for one processing session at a time. A
directory or Voice Memos run with multiple sessions uses the same event model
for per-session records, but does not yet render a multi-session in-place TUI.

## Text Event Logs

Non-interactive processing emits text logfmt events to stdout only. The current
public format is:

```text
2026-05-29T16:28:08Z INFO event=phase_done source=file session=1/1 input="clip.m4a" output_dir="/tmp/o" outputs="clip.txt,clip.json" phase=model_loading elapsed_s=4.2 message="model loaded"
```

Rules:

- Prefix every line with UTC ISO-8601 timestamp and uppercase level (`DEBUG`,
  `INFO`, `WARN`, or `ERROR`).
- Include `event=<name>` after the level.
- Use key/value fields for source, session, input, output basename, output
  names, output directory, phase, elapsed seconds, and related metadata when
  known.
- Quote and escape values containing whitespace, quotes, backslashes, commas, or
  empty strings.
- Emit completion-style processing events only. `session_start`, `phase_done`,
  `session_done`, and `run_done` are `INFO`; duplicate `session_skipped` details
  are `DEBUG`; warnings and handled failures are `WARN`/`ERROR`.
- Do not emit per-second progress snapshots in text event mode.
- `--log-level debug` and `--verbose` include debug events. `--quiet` is
  shorthand for `--log-level warn`. Normal `INFO` logs summarize skipped work in
  `run_done skipped=N` instead of printing one line per skipped session.

The Swift implementation keeps events typed internally so a future `jsonl` or
other structured renderer can be added without changing pipeline call sites.

## Automator and Folder Actions

`scripts/folder-action-transcribe.sh` defaults child runs to `--progress-log
plain` unless `TRANSCRIBE_EXTRA_ARGS` already supplies a `--progress-log`
option. It captures child stdout and stderr separately:

- Child stdout event lines are appended verbatim to `TRANSCRIBE_LOG`.
- If `TRANSCRIBE_LOG` is unset, child stdout is forwarded to wrapper stdout.
- Helper-owned start/end/skip/failure records use the same text event format.
- Child stderr is summarized in one `ERROR event=transcribe_failed` line on
  failure, and raw stderr is kept only in `TRANSCRIBE_STDERR_LOG`.

`scripts/folder-script.sh` is a thin Automator wrapper that emits the same text
event format for wrapper errors and does not echo raw input paths.

## Smoke Coverage

`make test-directory-smoke` runs the real `dir` subcommand against
`Tests/transcribeTests/Fixtures/AudioFormats`, writes `txt` and `json` outputs
with a fixed basename, and captures stdout/stderr separately. The smoke asserts
that the JSON output records all source audio basenames; that stdout contains
plain text events for session start, phase completion, session completion, and
run completion; that the event fields include the directory source, input
basenames, output basename, and output filenames; that no TUI progress block
appears in plain mode; and that successful processing emits no stderr.
