# Voice Memos Structured Metadata and Title Naming

## Goal

Expose richer Apple Voice Memos metadata in transcript outputs and use edited
Voice Memo titles consistently for generated filenames.

The current importer already reads the edited title from `ZCUSTOMLABEL` with
fallbacks, but grouped Voice Memo sessions used to fall back to generic
`Voice Memos Session N` filenames. JSON and Markdown also only exposed a small
flat metadata subset. This change makes Voice Memos metadata a first-class
domain model while preserving the existing compatibility fields.

## Design

- Keep SQLite access in `VoiceMemosImport`, but move the Voice Memo domain and
  output metadata structs into a dedicated model file.
- Read a curated set of stable fields from `ZCLOUDRECORDING`: title
  (`ZCUSTOMLABEL`, then `ZCUSTOMLABELFORSORTING`, then `ZENCRYPTEDTITLE`),
  title source, sorting title, recorded date, duration, unique id, path, folder
  id, flags, audio digest, and enhancement flags when present.
- Treat timestamp-shaped labels as placeholders when a non-timestamp sorting or
  encrypted title is available.
- Continue treating `ZDATE`, `ZPATH`, and `Z_PK` as required for usable rows,
  with all newer metadata columns optional for schema tolerance.
- Do not emit opaque audio-future blobs or transient playback state in
  transcript metadata.
- Do not add a separate location field in this pass. Apple Voice Memos
  location-based naming appears to surface as the recording title rather than a
  confirmed coordinate field in the local recording row.

## Filename Behavior

- `--output-prefix` remains authoritative and keeps the existing
  `- Recording N` suffix behavior.
- A single Voice Memo uses `YYYY-MM-DD HHMM <title>`.
- A grouped Voice Memo session uses a meaningful common title prefix when one
  exists; otherwise it uses the first edited title in the group.
- Grouped sessions append `+N memos` so a multi-recording transcript is visible
  from the filename.
- Generated basenames are sanitized and de-duplicated before output preflight.

## Output Metadata

JSON keeps the existing flat keys for compatibility:

- `source`
- `recorded_at`
- `recording_title`
- `voice_memos_unique_id`
- `voice_memos_path`

JSON also adds `metadata.voice_memos`:

- `session_title`
- `recording_count`
- `recordings[]`, with curated per-recording fields

Markdown gains YAML frontmatter with the same structured metadata and keeps the
existing readable `## Metadata` section for humans.

## Tests

- Voice Memos importer tests cover title source precedence, sorting title,
  enhancement flags, optional schema tolerance, and grouped title filenames.
- Output writer tests cover nested JSON metadata, preserved flat JSON keys, and
  Markdown frontmatter.
- Existing CLI and processing-history behavior remains compatible.
