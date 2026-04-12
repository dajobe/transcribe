# Spike: WhisperKit and SpeakerKit API Research

Research completed for the transcribe CLI implementation. Source: Argmax
WhisperKit repository (main branch).

## Package Layout

- **Repository:** <https://github.com/argmaxinc/WhisperKit>
- **Package name (SPM):** `whisperkit` (lowercase in Package.swift)
- **Products we use:**
  - `WhisperKit` (library, target: WhisperKit)
  - `SpeakerKit` (library, target: SpeakerKit)
- **Dependency:** Add as `.package(url:
  "https://github.com/argmaxinc/WhisperKit.git", from: "0.17.0")`. Consume
  products: `WhisperKit`, `SpeakerKit`. Both are in the same repo.
- **WhisperKit dependencies:** ArgmaxCore, Hub, Tokenizers (from
  swift-transformers). SpeakerKit depends on ArgmaxCore, WhisperKit, Hub. Our
  package only needs to depend on WhisperKit and SpeakerKit; their transitive
  deps are resolved by SPM.
- **Platform:** WhisperKit uses macOS 13+, iOS 16+. Spec requires macOS 14+; we
  set `.macOS(.v14)`.
- **Swift tools version:** WhisperKit uses 5.9. We use 5.9 for compatibility.

## WhisperKit API

### Initialization

- `WhisperKit(config: WhisperKitConfig()) async throws`
- Convenience: `WhisperKit(model:downloadBase:modelFolder:...) async throws`
- **Config (WhisperKitConfig):** `model` (String?, e.g. "large-v3"),
  `downloadBase` (URL?), `modelFolder` (String? or URL?), `download` (Bool),
  `verbose`, `load`, etc. Use `modelFolder` for cache path (our `--model-dir`).

### Audio Loading

- **Preferred (single file → Float array):**
  `AudioProcessor.loadAudioAsFloatArray(fromPath: String, channelMode:
  ChannelMode = .sumChannels(nil), startTime: Double?, endTime: Double?) throws
  -> [Float]`
- **Alternative:** `AudioProcessor.loadAudio(fromPath: String, ...) throws ->
  AVAudioPCMBuffer` then `AudioProcessor.convertBufferToArray(buffer:
  AVAudioPCMBuffer) -> [Float]`
- **Errors:** `WhisperError.loadAudioFailed("Resource path does not exist ...")`
  when file missing; throws on unreadable/unsupported format.
- **Sample rate:** Output is 16 kHz mono (WhisperKit resamples if needed).

### Transcription

- **From path:** `whisperKit.transcribe(audioPath: String, decodeOptions:
  DecodingOptions?, callback: TranscriptionCallback?) async throws ->
  [TranscriptionResult]`
- **From float array:** `whisperKit.transcribe(audioArray: [Float],
  decodeOptions: DecodingOptions?, callback: TranscriptionCallback?) async
  throws -> [TranscriptionResult]`
- **DecodingOptions:** Include `wordTimestamps: true` when diarization is
  enabled (required for SpeakerKit merge with subsegment strategy). Chunking
  strategy: e.g. `.vad` for long audio.
- **Return type:** `[TranscriptionResult]` — array of segments. Each
  `TranscriptionResult` has `segments: [TranscriptionSegment]`. Each
  `TranscriptionSegment` has `start`, `end` (Float, seconds), `text`, and
  optional `words: [WordTiming]?`. Word timestamps are optional and must be
  enabled via `DecodingOptions.wordTimestamps`.

### Supported Input Formats

- Audio is loaded via `AVAudioFile(forReading: URL, ...)`. Formats are whatever
  **AVFoundation** supports on macOS (e.g. .wav, .m4a, .aiff, .caf, .mp3 when
  available). No explicit list in code; document as "formats supported by
  WhisperKit's audio path (typically wav, m4a, aiff, caf; mp3 and flac depend on
  system)." Spec already lists mp3, wav, m4a, flac — keep that in help and error
  messages; implementation will throw on unsupported.

### Model Cache

- `WhisperKitConfig.modelFolder` (URL or String) sets where Whisper models are
  loaded from / downloaded to. Use `--model-dir` as the cache root for
  WhisperKit. SpeakerKit uses a separate config (see below).

## SpeakerKit API

### Initialization

- `SpeakerKit(_ config: PyannoteConfig) async throws` — loads (and optionally
  downloads) Pyannote models.
- **PyannoteConfig:** `modelFolder: URL?`, `downloadBase: URL?`, `download: Bool
  = true`, `verbose: Bool`. Use same cache root as Whisper: e.g. `modelFolder:
  URL(fileURLWithPath: modelDir).appendingPathComponent("speakerkit")` or pass
  same dir if SpeakerKit accepts a shared parent; check SpeakerKitModelManager
  for exact path usage. Config has `modelFolder` for where to find/download
  diarization models.

### Diarization

- `speakerKit.diarize(audioArray: [Float], options: (any
  DiarizationOptionsProtocol)?, progressCallback: ((Progress) -> Void)?) async
  throws -> DiarizationResult`
- **Options:** `PyannoteDiarizationOptions(numberOfSpeakers: Int?,
  minActiveOffset: Float?, ...)`. For fixed speaker count use
  `numberOfSpeakers`. For min/max: API has `numberOfSpeakers` (single value);
  when min and max are equal use it; when only min or only max, use that value
  and document that SpeakerKit may not support true min/max range
  (implementation can pass one or the other as needed).

### Merge (Speaker Info into Transcript)

- **Library provides merge:** `DiarizationResult.addSpeakerInfo(to:
  [TranscriptionResult], strategy: SpeakerInfoStrategy) -> [[SpeakerSegment]]`
- **Strategy:** `SpeakerInfoStrategy.segment` or
  `SpeakerInfoStrategy.subsegment`. Default `.subsegment` uses a 0.15s
  between-word threshold. `SpeakerInfoStrategy(from: "segment")` /
  `SpeakerInfoStrategy(from: "subsegment")` for CLI.
- **Input:** Array of `TranscriptionResult` (one per "file" or logical chunk; we
  pass a single-element array with our full transcription).
- **Output:** `[[SpeakerSegment]]` — one array per input TranscriptionResult;
  each `SpeakerSegment` has transcription + speaker info (startTime, endTime,
  speaker: SpeakerInfo). SpeakerInfo can be `.speakerId(Int)`, `.noMatch`,
  `.multiple([Int])`. Format as SPEAKER_0, SPEAKER_1 from speakerId.
- **Word timestamps required:** For `subsegment` strategy, segments must have
  `words` (word-level timings); otherwise merge skips them. Enable
  `DecodingOptions(wordTimestamps: true)` when diarization is on.

## Model Cache Location

- **WhisperKit:** `WhisperKitConfig.modelFolder` / `downloadBase` — we set from
  `--model-dir` (e.g. `~/.cache/transcribe` for Whisper).
- **SpeakerKit:** `PyannoteConfig.modelFolder` — can point to a subdirectory of
  the same `--model-dir` (e.g. `modelDir/speakerkit` or as required by
  SpeakerKitModelManager). Both families can live under one `--model-dir`;
  implementation will set both configs from that root.

## Word-Level Timestamps

- **Conditional:** Word timestamps are only present when
  `DecodingOptions.wordTimestamps == true`. Default may be false. For
  diarization with subsegment strategy we must enable word timestamps. JSON
  output should include `words` when present; spec already marks it optional.

## Summary for Implementation

| Concern            | Finding                                                                                                              |
|:-------------------|:---------------------------------------------------------------------------------------------------------------------|
| Package / products | Same repo; products `WhisperKit`, `SpeakerKit`; dependency from "0.17.0"                                             |
| Audio load         | `AudioProcessor.loadAudioAsFloatArray(fromPath:channelMode:)` → `[Float]`                                            |
| Transcribe         | `whisperKit.transcribe(audioPath:decodeOptions:callback:)` or `transcribe(audioArray:...)` → `[TranscriptionResult]` |
| Diarize            | `SpeakerKit(PyannoteConfig(...))` then `diarize(audioArray:options:progressCallback:)` → `DiarizationResult`         |
| Merge              | `diarizationResult.addSpeakerInfo(to: [transcription], strategy: .subsegment or .segment)` → `[[SpeakerSegment]]`    |
| Min/max speakers   | Pass via `PyannoteDiarizationOptions(numberOfSpeakers: n)`; use single value when min==max                           |
| Formats            | AVFoundation-based; document wav, m4a, mp3, flac; list in help/errors                                                |
| Cache              | Both Whisper and SpeakerKit configs accept folder URLs; use `--model-dir` as root for both                           |
| Word timestamps    | Enable in DecodingOptions when diarization enabled (required for subsegment merge)                                   |
