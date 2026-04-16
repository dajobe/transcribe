#!/bin/bash
# Run transcribe when a file is added to a Folder Action folder (macOS Automator).
# See specs/folder-action-markdown.md for environment variables and behavior.
set -euo pipefail

# ISO 8601 UTC (second precision), e.g. 2026-04-12T19:35:55Z
iso_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_line() {
  if [[ -n "${TRANSCRIBE_LOG:-}" ]]; then
    printf '%s %s\n' "$(iso_utc)" "$*" >>"${TRANSCRIBE_LOG}" 2>/dev/null || true
  fi
}

warn() {
  echo "$*" >&2
}

# Globals set in main() before trap; used by end_log on EXIT.
f=""
start_epoch=""
REASON=""

end_log() {
  local code=$?
  [[ -n "${start_epoch:-}" ]] || return 0
  local end_epoch
  end_epoch=$(date +%s)
  local dur=$((end_epoch - start_epoch))
  log_line "event=end path=${f} exit=${code} duration_s=${dur}${REASON:+ reason=${REASON}}"
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
    mp3|wav|m4a|flac|aiff|caf) return 0 ;;
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
  log_line "event=start path=${f}"
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

  local -a cmd
  cmd=("$bin" "$f" -o "$outdir" --format "$fmt")
  if [[ -n "${TRANSCRIBE_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    cmd+=(${TRANSCRIBE_EXTRA_ARGS})
  fi

  local flock_warned=0
  local err_tmp
  err_tmp=$(mktemp "${TMPDIR:-/tmp}/transcribe-fa.XXXXXX")

  set +e
  if [[ -n "${TRANSCRIBE_LOCK_FILE:-}" ]] && command -v flock >/dev/null 2>&1; then
    local lockfile="${TRANSCRIBE_LOCK_FILE/#\~/$HOME}"
    touch "$lockfile"
    flock "$lockfile" "${cmd[@]}" 2>"$err_tmp"
  else
    if [[ -n "${TRANSCRIBE_LOCK_FILE:-}" && "$flock_warned" -eq 0 ]]; then
      warn "folder-action-transcribe: flock not found; ignoring TRANSCRIBE_LOCK_FILE"
      flock_warned=1
    fi
    "${cmd[@]}" 2>"$err_tmp"
  fi
  local code=$?
  set -e

  if [[ "$code" -ne 0 ]]; then
    REASON=transcribe-failed
    local mean
    mean=$(transcribe_exit_meaning "$code")
    log_line "transcribe-exit=${code} meaning=${mean}"
    if [[ -s "$err_tmp" ]]; then
      # One line for the main log (transcribe prints newlines to stderr).
      local summ
      summ=$(tr '\n' ' ' <"$err_tmp" | sed 's/  */ /g' | head -c 2000)
      log_line "transcribe-stderr: ${summ}"
      if [[ -n "${TRANSCRIBE_LOG:-}" ]]; then
        local persistent="${TRANSCRIBE_STDERR_LOG:-${TRANSCRIBE_LOG%/*}/transcribe.stderr.log}"
        {
          echo "=== $(iso_utc) exit=${code} meaning=${mean} path=${f} ==="
          cat "$err_tmp"
          echo
        } >>"$persistent" 2>/dev/null || true
      fi
    else
      log_line "transcribe-stderr: (empty — run the same command in Terminal to see output)"
    fi
  fi
  rm -f "$err_tmp"

  exit "$code"
}

main "$@"
