#!/bin/bash
# Example Automator Folder Action wrapper: set paths below, chmod +x,
# point Automator at this file, pass input as arguments. Requires
# folder-action-transcribe.sh in the same directory (e.g. keep both
# under scripts/ or copy both to ~/bin).

set -e

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

for f in "$@"; do
    echo "$f"
    "$script_dir/folder-action-transcribe.sh" "$f" || true
done
