#!/bin/bash
# Smoke-test individual audio fixture formats through the real CLI.

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

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/transcribe-audio-smoke.XXXXXX")"
cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

extensions=()
while IFS= read -r ext; do
  extensions+=("$ext")
done < <(audio_smoke_extensions)

for ext in "${extensions[@]}"; do
  fixture="$fixture_dir/smoke.$ext"
  outdir="$tmp_root/$ext"
  mkdir -p "$outdir"

  [[ -f "$fixture" ]] || audio_smoke_fail "missing audio fixture: $fixture"

  printf 'Audio format smoke: %s\n' "$fixture"
  "$transcribe_binary" \
    --model "$model" \
    --model-dir "$model_dir" \
    --transcript-only \
    --format txt \
    -o "$outdir" \
    --stateless \
    --eta-hints off \
    --progress-log off \
    --audio-encoder-compute cpuOnly \
    --text-decoder-compute cpuOnly \
    file "$fixture" >/dev/null

  [[ -s "$outdir/smoke.txt" ]] || audio_smoke_fail "missing or empty transcript: $outdir/smoke.txt"
done
