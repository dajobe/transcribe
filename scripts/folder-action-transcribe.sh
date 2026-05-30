#!/bin/bash
# Run transcribe when a file is added to a Folder Action folder (macOS Automator).
# See specs/folder-action-markdown.md for environment variables and behavior.
# Requires transcribe >= 2.0 (uses the `file <path>` source command form).
#
# Optional env passed through to the child (export in Automator or a wrapper if needed):
#   TRANSCRIBE_ETA_HINTS=0  — disable timing-store + ETA-from-history (same as --eta-hints off).
#   Legacy alias: TRANSCRIBE_TIMING_STATS=0 (still honored by the binary).
set -euo pipefail

# ISO 8601 UTC (second precision), e.g. 2026-04-12T19:35:55Z
iso_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_line() {
  if [[ -n "${TRANSCRIBE_LOG:-}" ]]; then
    printf '%s\n' "$*" >>"${TRANSCRIBE_LOG}" 2>/dev/null || true
  else
    printf '%s\n' "$*"
  fi
}

log_value() {
  local value="$1"
  if [[ -z "$value" || "$value" =~ [[:space:]\",\\,] ]]; then
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
  else
    printf '%s' "$value"
  fi
}

log_event() {
  local level="$1"
  local event="$2"
  shift 2
  local line
  line="$(iso_utc) $level event=$event"
  while [[ "$#" -gt 1 ]]; do
    local key="$1"
    local value="$2"
    line+=" ${key}=$(log_value "$value")"
    shift 2
  done
  log_line "$line"
}

warn() {
  log_event WARN warning message "$*"
}

append_child_stdout() {
  local out_tmp="$1"
  [[ -s "$out_tmp" ]] || return 0
  if [[ -n "${TRANSCRIBE_LOG:-}" ]]; then
    cat "$out_tmp" >>"${TRANSCRIBE_LOG}" 2>/dev/null || true
  else
    cat "$out_tmp"
  fi
}

# Globals set in main() before trap; used by end_log on EXIT.
f=""
start_epoch=""
REASON=""

# shellcheck disable=SC2329 # Invoked indirectly by trap.
end_log() {
  local code=$?
  [[ -n "${start_epoch:-}" ]] || return 0
  local end_epoch
  end_epoch=$(date +%s)
  local dur=$((end_epoch - start_epoch))
  if [[ -n "${REASON:-}" ]]; then
    log_event INFO end path "$f" exit "$code" duration_s "$dur" reason "$REASON"
  else
    log_event INFO end path "$f" exit "$code" duration_s "$dur"
  fi
}

file_size() {
  local p="$1"
  if [[ ! -e "$p" ]]; then
    echo 0
    return
  fi
  stat -f%z "$p" 2>/dev/null || echo 0
}

# Wait until file size is unchanged for STABLE_SEC consecutive seconds, or MAX wait seconds total.
wait_stable_file() {
  local path="$1"
  local stable_need="${TRANSCRIBE_STABLE_SECS:-2}"
  local max_wait="${TRANSCRIBE_MAX_STABLE_WAIT:-3600}"
  local prev=""
  local same=0
  local elapsed=0
  while [[ "$elapsed" -lt "$max_wait" ]]; do
    local sz
    sz="$(file_size "$path")"
    if [[ "$sz" == "$prev" && -n "$prev" ]]; then
      same=$((same + 1))
      if [[ "$same" -ge "$stable_need" ]]; then
        return 0
      fi
    else
      same=0
    fi
    prev="$sz"
    sleep 1
    elapsed=$((elapsed + 1))
  done
  warn "folder-action-transcribe: timeout waiting for stable size: $path"
  return 1
}

is_allowed_audio() {
  local n="$1"
  local ext="${n##*.}"
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in
    mp3|wav|m4a|flac|aiff|caf|aac) return 0 ;;
    *) return 1 ;;
  esac
}

# Matches Sources/transcribe/Errors.swift ExitCode (transcribe binary).
transcribe_exit_meaning() {
  case "$1" in
    1) echo "runtime" ;;
    2) echo "invalid-usage" ;;
    3) echo "input-file" ;;
    4) echo "model" ;;
    5) echo "output-write" ;;
    *) echo "other" ;;
  esac
}

main() {
  if [[ "$#" -lt 1 || -z "${1:-}" ]]; then
    warn "folder-action-transcribe: missing file path argument"
    exit 2
  fi

  f="$(cd -- "$(dirname -- "$1")" && pwd -P)/$(basename -- "$1")"

  start_epoch=$(date +%s)
  REASON=""
  log_event INFO start path "$f"
  trap end_log EXIT

  local base
  base="$(basename "$f")"

  if [[ "$base" == .* ]]; then
    REASON=skip-hidden
    exit 0
  fi
  case "$base" in
    *.tmp)
      REASON=skip-tmp
      exit 0
      ;;
  esac

  if ! is_allowed_audio "$base"; then
    REASON=skip-non-audio
    exit 0
  fi

  if ! wait_stable_file "$f"; then
    REASON=skip-unstable
    exit 0
  fi

  local outdir=""
  if [[ -n "${TRANSCRIBE_OUTPUT_DIR:-}" ]]; then
    outdir="${TRANSCRIBE_OUTPUT_DIR/#\~/$HOME}"
  else
    outdir="$(dirname "$f")"
  fi

  local stem="${base%.*}"
  if [[ "${TRANSCRIBE_SKIP_IF_MD_EXISTS:-0}" == "1" ]]; then
    if [[ -e "${outdir}/${stem}.md" ]]; then
      REASON=skip-existing-md
      exit 0
    fi
  fi

  local bin="${TRANSCRIBE_BIN:-transcribe}"
  local fmt="${TRANSCRIBE_FORMAT:-md}"

  # 2.0 reorganised the CLI around source commands (`file <path>` etc).
  # If the user upgraded the script but their installed binary is still
  # pre-2.0, fail fast with a clear message instead of running with
  # silently wrong argument ordering.
  local bin_version
  if bin_version="$("$bin" --version 2>/dev/null)"; then
    case "$bin_version" in
      0.*|1.*)
        REASON=binary-too-old
        log_event ERROR binary_too_old path "$f" transcribe_version "$bin_version" required ">=2.0"
        exit 1
        ;;
    esac
  fi

  local -a cmd
  cmd=("$bin" -o "$outdir" --format "$fmt")
  if [[ "${TRANSCRIBE_EXTRA_ARGS:-}" != *"--progress-log"* ]]; then
    cmd+=(--progress-log plain)
  fi
  # TRANSCRIBE_EXTRA_ARGS: global flags only; must match current `transcribe --help`
  # (e.g. --transcript-only, --eta-hints off — not legacy spellings such as --no-diarize).
  if [[ -n "${TRANSCRIBE_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    cmd+=(${TRANSCRIBE_EXTRA_ARGS})
  fi
  cmd+=(file "$f")

  local flock_warned=0
  local out_tmp
  local err_tmp
  out_tmp=$(mktemp "${TMPDIR:-/tmp}/transcribe-fa-out.XXXXXX")
  err_tmp=$(mktemp "${TMPDIR:-/tmp}/transcribe-fa.XXXXXX")

  set +e
  if [[ -n "${TRANSCRIBE_LOCK_FILE:-}" ]] && command -v flock >/dev/null 2>&1; then
    local lockfile="${TRANSCRIBE_LOCK_FILE/#\~/$HOME}"
    touch "$lockfile"
    flock "$lockfile" "${cmd[@]}" >"$out_tmp" 2>"$err_tmp"
  else
    if [[ -n "${TRANSCRIBE_LOCK_FILE:-}" && "$flock_warned" -eq 0 ]]; then
      log_event WARN warning path "$f" message "flock not found; ignoring TRANSCRIBE_LOCK_FILE"
      flock_warned=1
    fi
    "${cmd[@]}" >"$out_tmp" 2>"$err_tmp"
  fi
  local code=$?
  set -e

  append_child_stdout "$out_tmp"

  if [[ "$code" -ne 0 ]]; then
    REASON=transcribe-failed
    local mean
    mean=$(transcribe_exit_meaning "$code")
    if [[ -s "$err_tmp" ]]; then
      local summ
      summ=$(tr '\n' ' ' <"$err_tmp" | sed 's/  */ /g; s/^ *//; s/ *$//' | head -c 2000)
      log_event ERROR transcribe_failed path "$f" exit "$code" meaning "$mean" stderr_summary "$summ"
      if [[ -n "${TRANSCRIBE_LOG:-}" ]]; then
        local log_dir
        log_dir="$(dirname "$TRANSCRIBE_LOG")"
        local persistent="${TRANSCRIBE_STDERR_LOG:-${log_dir}/transcribe.stderr.log}"
        {
          echo "=== $(iso_utc) exit=${code} meaning=${mean} path=${f} ==="
          cat "$err_tmp"
          echo
        } >>"$persistent" 2>/dev/null || true
      fi
    else
      log_event ERROR transcribe_failed path "$f" exit "$code" meaning "$mean" stderr_summary "empty"
    fi
  fi
  rm -f "$out_tmp" "$err_tmp"

  exit "$code"
}

main "$@"
