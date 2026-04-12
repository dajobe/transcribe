# Example Automator Folder Action wrapper
#
# This goes into Automator shell script body
#
# Automator: Run Shell Script → "Pass input" must be "as arguments" (not stdin).
#
# Requires configuring in $HOME/.transcribe.env

set -e

. $HOME/.transcribe.env

TRANSCRIBE_BIN="${TRANSCRIBE_BIN:-$HOME/bin/transcribe}"
export TRANSCRIBE_BIN
TRANSCRIBE_SCRIPT_DIR="${TRANSCRIBE_SCRIPT_DIR:-$HOME/bin}"
export TRANSCRIBE_SCRIPT_DIR
TRANSCRIBE_LOG="${TRANSCRIBE_LOG:-/tmp/transcribe.log}"
export TRANSCRIBE_LOG

if [[ $# -eq 0 ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") folder-script: no input paths (Automator must pass input as arguments, not stdin)" >>"$TRANSCRIBE_LOG"
  exit 0
fi

helper="$TRANSCRIBE_SCRIPT_DIR/folder-action-transcribe.sh"
# Smoke log: set TRANSCRIBE_SMOKE_LOG=/tmp/folder-action-smoke.log to debug Automator.
if [[ -n "${TRANSCRIBE_SMOKE_LOG:-}" ]]; then
  {
    echo "=== $(date) ==="
    echo "argc=$# argv=$*"
    echo "script_dir=$script_dir"
    echo "helper=$helper"
    if [[ -x "$helper" ]]; then
      echo "helper_ok=yes"
    else
      echo "helper_ok=no (missing or not executable)"
    fi
  } >>"${TRANSCRIBE_SMOKE_LOG}" 2>&1 || true
fi

if [[ ! -x "$helper" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") folder-script: missing or not executable: $helper (set TRANSCRIBE_SCRIPT_DIR or run this script from disk, not inline)" >>"$TRANSCRIBE_LOG"
  exit 1
fi

for f in "$@"; do
  echo "$f"
  "$helper" "$f" || true
done

#!/bin/bash
# Example Automator Folder Action wrapper: set paths below, chmod +x,
# point Automator at this file, pass input as arguments. Requires
# folder-action-transcribe.sh in the same directory (e.g. keep both
# under scripts/ or copy both to ~/bin).
#
# Automator: Run Shell Script → "Pass input" must be "as arguments" (not stdin).
# If you paste this inline instead of running this file, set script_dir to the
# directory that contains folder-action-transcribe.sh.

set -e

# Directory containing folder-action-transcribe.sh. When the script is pasted
# inline into Automator, BASH_SOURCE is unreliable — set TRANSCRIBE_SCRIPT_DIR
# (e.g. to $HOME/bin) or hardcode script_dir below.
if [[ -n "${TRANSCRIBE_SCRIPT_DIR:-}" ]]; then
  script_dir="${TRANSCRIBE_SCRIPT_DIR/#\~/$HOME}"
else
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# ROOT for audio input, logs, lock file dir, and default output
root_dir="$HOME/somewhere"
logs_dir="$root_dir/logs"
input_dir="$root_dir/audio"
output_dir="$root_dir/transcriptions"

mkdir -p "$logs_dir" "$output_dir"

TRANSCRIBE_BIN="${TRANSCRIBE_BIN:-$HOME/bin/transcribe}"
export TRANSCRIBE_BIN
TRANSCRIBE_LOG="$logs_dir/transcribe.log"
export TRANSCRIBE_LOG
TRANSCRIBE_OUTPUT_DIR="$output_dir"
export TRANSCRIBE_OUTPUT_DIR
TRANSCRIBE_LOCK_FILE="$input_dir/transcribe.lock"
export TRANSCRIBE_LOCK_FILE

if [[ $# -eq 0 ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") folder-script: no input paths (Automator must pass input as arguments, not stdin)" >>"$TRANSCRIBE_LOG"
  exit 0
fi

helper="$script_dir/folder-action-transcribe.sh"
# Smoke log: set TRANSCRIBE_SMOKE_LOG=/tmp/folder-action-smoke.log to debug Automator.
if [[ -n "${TRANSCRIBE_SMOKE_LOG:-}" ]]; then
  {
    echo "=== $(date) ==="
    echo "argc=$# argv=$*"
    echo "script_dir=$script_dir"
    echo "helper=$helper"
    if [[ -x "$helper" ]]; then
      echo "helper_ok=yes"
    else
      echo "helper_ok=no (missing or not executable)"
    fi
  } >>"${TRANSCRIBE_SMOKE_LOG}" 2>&1 || true
fi

if [[ ! -x "$helper" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") folder-script: missing or not executable: $helper (set TRANSCRIBE_SCRIPT_DIR or run this script from disk, not inline)" >>"$TRANSCRIBE_LOG"
  exit 1
fi

for f in "$@"; do
  echo "$f"
  "$helper" "$f" || true
done
