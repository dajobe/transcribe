# shellcheck shell=bash

audio_smoke_fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

audio_smoke_extensions() {
  local configured="${AUDIO_FORMAT_SMOKE_EXTENSIONS:-}"
  local source_file="${AUDIO_FORMAT_SOURCE_FILE:-Sources/transcribe/AudioLoader.swift}"
  local raw

  if [[ -n "$configured" ]]; then
    raw="$configured"
  else
    [[ -f "$source_file" ]] || audio_smoke_fail "missing audio extension source: $source_file"
    raw="$(sed -n 's/.*static let audioFormatExtensions = \[\(.*\)\].*/\1/p' "$source_file" | head -n 1)"
    [[ -n "$raw" ]] || audio_smoke_fail "could not parse audioFormatExtensions from $source_file"
    raw="${raw//\"/}"
    raw="${raw//,/ }"
  fi

  local -a extensions
  read -r -a extensions <<<"$raw"
  [[ "${#extensions[@]}" -gt 0 ]] || audio_smoke_fail "no audio smoke extensions configured"

  local ext
  for ext in "${extensions[@]}"; do
    printf '%s\n' "$ext"
  done
}
