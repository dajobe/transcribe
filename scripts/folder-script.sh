#!/bin/bash
# Example Automator Folder Action wrapper.
#
# Automator: Run Shell Script -> "Pass input" must be "as arguments".
# Configure paths in $HOME/.transcribe.env or by editing the defaults below.

set -euo pipefail

iso_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
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
  if [[ -n "${TRANSCRIBE_LOG:-}" ]]; then
    printf '%s\n' "$line" >>"$TRANSCRIBE_LOG"
  else
    printf '%s\n' "$line"
  fi
}

if [[ -f "$HOME/.transcribe.env" ]]; then
  # shellcheck disable=SC1090
  . "$HOME/.transcribe.env"
fi

TRANSCRIBE_BIN="${TRANSCRIBE_BIN:-$HOME/bin/transcribe}"
export TRANSCRIBE_BIN
TRANSCRIBE_SCRIPT_DIR="${TRANSCRIBE_SCRIPT_DIR:-$HOME/bin}"
TRANSCRIBE_SCRIPT_DIR="${TRANSCRIBE_SCRIPT_DIR/#\~/$HOME}"
export TRANSCRIBE_SCRIPT_DIR
TRANSCRIBE_LOG="${TRANSCRIBE_LOG:-/tmp/transcribe.log}"
export TRANSCRIBE_LOG

helper="$TRANSCRIBE_SCRIPT_DIR/folder-action-transcribe.sh"

if [[ -n "${TRANSCRIBE_SMOKE_LOG:-}" ]]; then
  {
    echo "=== $(date) ==="
    echo "argc=$# argv=$*"
    echo "script_dir=$TRANSCRIBE_SCRIPT_DIR"
    echo "helper=$helper"
    if [[ -x "$helper" ]]; then
      echo "helper_ok=yes"
    else
      echo "helper_ok=no (missing or not executable)"
    fi
  } >>"${TRANSCRIBE_SMOKE_LOG}" 2>&1 || true
fi

if [[ $# -eq 0 ]]; then
  log_event WARN no_input message "Automator must pass input as arguments, not stdin"
  exit 0
fi

if [[ ! -x "$helper" ]]; then
  log_event ERROR missing_helper helper "$helper" message "folder-action-transcribe.sh is missing or not executable"
  exit 1
fi

for f in "$@"; do
  "$helper" "$f" || true
done
