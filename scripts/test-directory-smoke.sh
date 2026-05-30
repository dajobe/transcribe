#!/bin/bash
# Smoke-test directory input output names and stdout event logging.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"

# shellcheck source=scripts/audio-format-smoke-lib.sh
. "$script_dir/audio-format-smoke-lib.sh"

transcribe_binary="${TRANSCRIBE_BINARY:-.build/debug/transcribe}"
fixture_dir="${AUDIO_FORMAT_FIXTURE_DIR:-Tests/transcribeTests/Fixtures/AudioFormats}"
model="${AUDIO_FORMAT_SMOKE_MODEL:-openai_whisper-base}"
model_dir="${AUDIO_FORMAT_SMOKE_MODEL_DIR:-$HOME/.cache/transcribe}"
output_prefix="${DIRECTORY_SMOKE_OUTPUT_PREFIX:-audio-format-dir}"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/transcribe-dir-smoke.XXXXXX")"
outdir="$tmp_root/out"
log="$tmp_root/stdout.log"
err="$tmp_root/stderr.log"
mkdir -p "$outdir"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

logfmt_value() {
  local value="$1"
  if [[ -z "$value" || "$value" =~ [[:space:]\",\\,] ]]; then
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
  else
    printf '%s' "$value"
  fi
}

dump_failure_context() {
  printf '\nDirectory smoke stdout log:\n' >&2
  cat "$log" >&2 || true
  printf '\nDirectory smoke stderr log:\n' >&2
  cat "$err" >&2 || true
}

fail_with_context() {
  printf 'error: %s\n' "$*" >&2
  dump_failure_context
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -F -- "$needle" "$file" >/dev/null || fail_with_context "missing '$needle' in $file"
}

assert_phase_done() {
  local phase="$1"
  grep -F 'event=phase_done' "$log" | grep -F "phase=$phase" >/dev/null \
    || fail_with_context "missing phase_done for phase=$phase"
}

extensions=()
while IFS= read -r ext; do
  extensions+=("$ext")
done < <(audio_smoke_extensions)

printf 'Directory smoke: %s\n' "$fixture_dir"
"$transcribe_binary" \
  --model "$model" \
  --model-dir "$model_dir" \
  --transcript-only \
  --format txt,json \
  --output-prefix "$output_prefix" \
  -o "$outdir" \
  --stateless \
  --eta-hints off \
  --progress-log plain \
  --audio-encoder-compute cpuOnly \
  --text-decoder-compute cpuOnly \
  dir --sort name "$fixture_dir" >"$log" 2>"$err"

if [[ -s "$err" ]]; then
  fail_with_context "unexpected stderr from directory smoke"
fi

txt_output="$outdir/$output_prefix.txt"
json_output="$outdir/$output_prefix.json"

[[ -f "$txt_output" ]] || fail_with_context "missing transcript output: $txt_output"
[[ -s "$json_output" ]] || fail_with_context "missing or empty JSON output: $json_output"

assert_contains '"audio_files"' "$json_output"
assert_contains 'event=session_start' "$log"
assert_contains 'source=directory_session' "$log"
assert_contains 'session=1/1' "$log"
assert_contains "output_basename=$(logfmt_value "$output_prefix")" "$log"
assert_contains "outputs=$(logfmt_value "$output_prefix.txt,$output_prefix.json")" "$log"

for ext in "${extensions[@]}"; do
  assert_contains "smoke.$ext" "$log"
  assert_contains "smoke.$ext" "$json_output"
done

assert_phase_done model_loading
assert_phase_done audio
assert_phase_done output
assert_contains 'event=session_done' "$log"
assert_contains 'event=run_done' "$log"

if grep -F 'Total:' "$log" >/dev/null; then
  fail_with_context "plain directory smoke log unexpectedly contained TUI output"
fi
