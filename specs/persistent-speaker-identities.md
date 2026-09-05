# Persistent speaker identities and canonical transcripts

## Status and scope

Target release: 2.6.0. Implementation uses Argmax OSS Swift 1.1.0, whose
SpeakerKit exposes per-speaker centroid embeddings. The Whisper transcription
model default is unchanged; this feature needs an SDK update, not replacement
ASR weights.

The first version saves a reusable inference result, suggests speaker
identities, allows users to confirm them, and applies sufficiently supported
strong matches. Explicit exports reuse saved results without audio or models.
Automatic inference-cache lookup, full session recovery, an editor, and a
general backend abstraction remain separate work.

## User workflow

Run transcription normally, then locate the canonical result:

```bash
transcribe file meeting.m4a
transcribe transcripts
transcribe inspect /path/to/result.transcript.json
transcribe speakers review /path/to/result.transcript.json
transcribe speakers confirm /path/to/result.transcript.json SPEAKER_0 --name "Dave"
transcribe speakers list
```

Use the printed profile ID to confirm another independent recording:

```bash
transcribe speakers confirm /path/to/second.transcript.json SPEAKER_1 --profile PROFILE_ID
transcribe speakers review /path/to/third.transcript.json --apply
transcribe export /path/to/third.transcript.json --format md,srt -o ./notes
```

Without `--apply`, review is a preview and does not modify the transcript.
Confirmation always requires a local `SPEAKER_n` identifier from inspect/review,
even when an export displays a name. Only explicit confirmation adds an example.
`--name` reuses a unique exact-name profile; use `--profile` when names are
ambiguous. Repeating confirmation replaces the same evidence entry rather than
adding another example.

Correction uses the same confirm command with the intended name/profile. It
moves that local evidence out of the old profile; it does not rename the old
person. Several local diarization fragments can be explicitly confirmed as one
person, but the matcher does not automatically assign a person to multiple local
speakers in one document.

```bash
transcribe speakers clear /path/to/result.transcript.json SPEAKER_0
transcribe speakers rename PROFILE_ID "David"
transcribe speakers delete PROFILE_ID
```

Clear removes the assignment and its confirmed example, not the original
centroid. An explicit later review can suggest that person again. Delete removes
the profile and all examples from future matching. Neither operation rewrites
past exports or name snapshots in other canonical documents.

## Storage boundaries

- Canonical results: `<state>/transcripts/<uuid>.transcript.json`.
- Confirmed profiles: `<state>/speaker_profiles.json`.
- Stable advisory profile lock: `<state>/speaker_profiles.json.lock`.
- State resolves through `StatePaths`: `XDG_STATE_HOME/transcribe`, otherwise
  macOS Application Support/transcribe.
- Managed directories use mode 0700; artifacts, profiles, and locks use 0600.
  Temporary files are private before content is written and are atomically
  renamed into place. Explicit portable document destinations do not change the
  permissions of their existing parent directory.
- Embeddings are identifying voice data. The feature makes no remote identity
  lookup and uploads neither audio nor embeddings. Model acquisition retains the
  existing network behavior.
- `--stateless` bypasses profile lookup, automatic naming, and canonical
  persistence. Inference may still compute embeddings internally, but ordinary
  exports never include them.
- Copy a canonical file to back it up or transfer it. Its confirmed/automatic
  names are snapshots and can be exported without the originating profile store.
  Deleting a profile does not erase those portable copies.

## Canonical JSON schema v1

The canonical document is a distinct format from the existing JSON export. It is
encoded/decoded by `CanonicalTranscript`; the implementation uses these
top-level keys:

| Key                                   | Meaning                                                                                                            |
|:--------------------------------------|:-------------------------------------------------------------------------------------------------------------------|
| `schemaVersion`                       | Integer schema version, currently 1; unknown versions fail explicitly                                              |
| `id`                                  | UUID identifying this saved result                                                                                 |
| `evidenceID`                          | SHA-256 identity derived from the sorted unique source hashes                                                      |
| `sourceHashes`                        | Sorted unique SHA-256 hashes of input file bytes                                                                   |
| `createdAt`                           | ISO 8601 time of result creation                                                                                   |
| `model`, `transcribeVersion`          | ASR model selection and application version                                                                        |
| `audioPath`, `audioFiles`, `basename` | Source/output context required by existing renderers                                                               |
| `sourceMetadata`                      | Optional Voice Memos metadata, preserved for export                                                                |
| `output`                              | Transcript segments, words when available, duration, language, diarization state, warnings, and local centroid map |
| `embeddingModelID`                    | Compatibility identifier for the embedding space                                                                   |
| `speakerMatches`                      | Local speaker ID to suggestion/automatic/confirmed identity decision                                               |

The `output.speakerEmbeddings` dictionary maps local IDs to float arrays.
Segments always retain their local speaker IDs in canonical storage; export
creates a view with accepted names substituted. Suggestions never substitute
names. Raw centroids and original text/timing are retained after confirmation.

Segment/word times use seconds relative to the combined decoded session. This
initial schema preserves current renderer inputs, not a full raw diarization
result or exact per-clip sample-offset timeline. It cannot rerun speaker
merging, invent missing word timings, or redo ASR from the document alone. A
future inference cache needs ordered source/timeline and complete recipe
provenance beyond the evidence set used here.

Validation rejects unsupported schemas, inconsistent evidence hashes, nonfinite
or reversed timestamps, invalid speaker references, zero/nonfinite embeddings,
and invalid matching evidence. Overlapping speech is permitted; global
non-overlap is not a validation requirement.

## Profile schema and confirmed evidence

The profile file has `schema_version: 1` and a `profiles` array. Each profile
contains a stable `id`, user-supplied `name`, and `examples`. Each example
contains:

- `transcript_id`: the content-derived evidence ID, not an artifact UUID.
- `speaker_id`: the original local speaker ID.
- `model_id`: the embedding compatibility identifier.
- `embedding`: the explicitly confirmed centroid vector.
- `source_hashes`: the input hashes contributing to this example.

Re-exporting, copying, or rerunning unchanged files cannot create independent
evidence merely by generating a new artifact UUID. Confirmations are unique by
evidence ID and local speaker ID. Correcting an assignment removes that example
from any prior profile.

Multiple clips in a session share one evidence set. Automatic support requires
disjoint sets between two supporting examples. Reordering or repeating the same
files does not increase independence. Re-encoding audio changes file hashes and
can evade this heuristic; this is content bookkeeping, not a biometric
anti-spoofing system.

Read-modify-write operations hold the stable profile lock until atomic
publication. Malformed or unsupported stores are reported and never reset
silently. A profile write and a canonical document update are separate atomic
operations, not a cross-file transaction. If confirmation saves the profile but
fails to save the document, the error reports the profile ID and an idempotent
retry command.

## Matching policy

All thresholds are conservative initial heuristics, not calibrated
probabilities.

1. Consider only confirmed examples from the same embedding model ID and vector
   dimension. Exclude examples with the current evidence ID or overlapping
   source hashes.
2. Rank profiles by their closest eligible example's cosine distance. Stable
   profile IDs break equal-distance ties deterministically.
3. Suggest the nearest profile only when its distance is at most 0.30.
4. Apply an automatic name only if at least two examples are each within 0.15,
   originate from distinct evidence IDs with disjoint source hash sets, and the
   nearest competing profile is at least 0.10 farther away. With no competing
   profile, the margin condition is satisfied; the two-example rule still
   applies.
5. Demote automatic assignments to suggestions when they would assign one
   profile to multiple local speakers. During refresh, explicit confirmations
   take precedence over automatic assignments.
6. Never append automatic or suggested matches to profiles. A user must confirm.

Saved decisions include profile ID, name snapshot, status, nearest distance,
runner-up margin when available, and eligible distinct evidence count. The count
is not necessarily the number of mutually independent examples: the separate
disjoint-source test controls automatic eligibility.

Short/noisy speech and diarization contamination can make matching unreliable.
Unknown speakers remain local IDs. Initial releases do not provide an identity
guarantee or authentication functionality. Threshold changes require evaluation
against recordings from varied microphones and acoustic conditions.

The initial embedding space identifier is
`argmax-speakerkit-1.1.0/pyannote-v3/speaker_embedder/W8A16`, the SDK's default
on supported macOS versions. A changed model/variant must use a different ID.
This identifier is not a cryptographic digest of downloaded model weights;
replacing upstream assets under the same name is a remaining provenance limit.

## Pipeline and exports

After inference, stateful runs assemble the canonical result, obtain matches,
and save it before writing any requested export. Missing profiles yield no
matches. A corrupt/unavailable profile store produces a warning and preserves
the canonical inference result with local labels, allowing later repair/review.

Existing output overwrite checks remain in place, both before inference and at
write time. An export command cannot overwrite its own canonical input. A failed
export can be retried from the retained document without loading models.

Legacy `--format json` remains the established export schema and includes no
embeddings. JSON, TXT, Markdown, SRT, and VTT receive accepted names through the
existing renderer interface; TSV keeps its existing speaker-free columns. Legacy
JSON exports cannot be enrolled as canonical documents because they lack the
required embeddings and evidence provenance.

`speakers review --apply` refreshes suggestions and automatic decisions.
Explicit confirmations remain authoritative; if their profile still exists,
their saved name is refreshed from that profile. Otherwise the portable
confirmed name snapshot remains. Existing exports change only when exported
again.

Existing processing-history skip behavior is unchanged. Older completed runs
have no canonical artifact until explicitly rerun with the existing redo and
overwrite options. New format selection during an ordinary transcription is not
yet an automatic canonical-cache lookup: use `export` for guaranteed reuse.

## Enrollment runs (--no-outputs)

`--no-outputs` reruns existing audio purely to grow the speaker recognizer: the
full pipeline runs and the canonical transcript is saved, but no output files
are written, so previously edited transcripts are never touched. Such a run
neither consults nor appends processing history — it processes inputs that
history would skip (no `--redo` needed) and leaves no record that could make a
later normal run skip as a duplicate, including the Voice Memos imported
baseline. Because the canonical document is the run's entire product, a
canonical save failure is an error for `--no-outputs`, not the warning ordinary
runs degrade to. `--stateless --no-outputs` is rejected as contradictory.

Managed-store saves deduplicate by `evidenceID`: re-saving the same source
replaces the existing canonical document in place, carrying forward confirmed
speaker assignments for speakers the new run still detects. Rerunning the same
audio therefore cannot duplicate `transcripts` listings, and — since evidence is
keyed by source hash — cannot inflate a speaker's independent-example count.

## Verification and acceptance

- Synthetic vector tests cover suggestions, independent strong matches,
  ambiguity, weak support, model/dimension mismatch, conflicting local
  assignments, self/overlap exclusion, and large finite values.
- Store tests cover repeated confirmation, correction, rename/delete/clear,
  schema corruption, invalid vectors, file modes, and concurrent process
  updates.
- Canonical tests cover round trips, validation, original local IDs, name
  substitution rules, private writes, and stateless profile-lookup bypass.
- CLI integration tests use synthetic canonical documents to confirm, correct,
  review, export, and inspect without audio/model access. Ordinary exports must
  contain no embeddings and existing files must remain protected.
- Run the full Swift suite with four workers and ShellCheck; build release,
  verify 2.6.0, commit the version change, immediately create its annotated tag,
  and run `make verify-tag`.
- Real recording accuracy and threshold calibration remain evaluation work.
  Synthetic tests prove policy behavior, not recognition accuracy.

## Related work

- [Library embedding](library-embedding.md)
- [Processing history](processing-history-reasons.md)
- [Project backlog](../TODO.md), especially R5–R10 and R12
- [Argmax 1.1.0
  release](https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.0)
