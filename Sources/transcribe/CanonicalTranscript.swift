import CryptoKit
import Foundation

/// One rendered output file a canonical document knows it produced. The hash
/// is change detection for transcribe's own writes — refresh only overwrites a
/// file whose current bytes still match it — not an integrity guarantee.
/// Paths are absolute and per-machine: a document copied elsewhere carries
/// paths that will not resolve there, and refresh treats them as deleted.
struct ExportRecord: Codable, Equatable {
    var path: String
    var format: String
    var sha256: String
    var exportedAt: Date
}

struct CanonicalTranscript: Codable, Equatable {
    static let currentSchemaVersion = 1
    /// SpeakerKit SDK version stamped into embedding identities. This must
    /// track the `exact:` pin in Package.swift: bumping that pin means deciding
    /// whether the default embedder changed, and bumping this string when it
    /// did. SpeakerProfileStore.matches() only compares vectors whose model IDs
    /// are equal, so reusing an ID across a changed embedder would score
    /// meaningless cosine distances against confirmed examples.
    static let speakerKitVersion = "1.1.0"
    /// Identity stamped on every saved embedding. The embedder components are
    /// the SpeakerKit defaults for the pinned SDK; verifySpeakerEmbeddingModelID()
    /// re-derives them from the SDK at startup so a changed embedder is caught
    /// instead of silently reusing this ID for incompatible vectors.
    static let speakerEmbeddingModelID = makeSpeakerEmbeddingModelID(
        embedderName: "speaker_embedder", embedderVersion: "pyannote-v3", embedderVariant: "W8A16"
    )

    /// Composes a stamped identity from the pinned SDK version and an
    /// embedder's name, version and variant, in the layout saved documents and
    /// speaker profiles already carry.
    static func makeSpeakerEmbeddingModelID(
        embedderName: String, embedderVersion: String?, embedderVariant: String?
    ) -> String {
        (["argmax-speakerkit-\(speakerKitVersion)"]
            + [embedderVersion, embedderName, embedderVariant].compactMap { $0 })
            .joined(separator: "/")
    }

    let schemaVersion: Int
    let id: UUID
    /// Stable identity of the unique source recordings used as speaker evidence.
    let evidenceID: String
    /// Sorted unique audio hashes used to prevent overlapping evidence from counting twice.
    let sourceHashes: [String]
    let createdAt: Date
    let model: String
    let transcribeVersion: String
    let audioPath: String
    let audioFiles: [String]?
    let basename: String
    let sourceMetadata: OutputSourceMetadata?
    var output: TranscriptionOutput
    let embeddingModelID: String
    var speakerMatches: [String: SpeakerMatch]
    /// Rendered files this document produced, absent on documents from
    /// releases before export refresh. An additive optional key within schema
    /// version 1: older binaries ignore it and older documents decode as nil.
    var exports: [ExportRecord]?

    init(
        schemaVersion: Int = CanonicalTranscript.currentSchemaVersion,
        id: UUID = UUID(),
        evidenceID: String,
        sourceHashes: [String] = [],
        createdAt: Date = Date(),
        model: String,
        transcribeVersion: String,
        audioPath: String,
        audioFiles: [String]? = nil,
        basename: String,
        sourceMetadata: OutputSourceMetadata? = nil,
        output: TranscriptionOutput,
        embeddingModelID: String = CanonicalTranscript.speakerEmbeddingModelID,
        speakerMatches: [String: SpeakerMatch] = [:],
        exports: [ExportRecord]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.evidenceID = evidenceID
        self.sourceHashes = sourceHashes
        self.createdAt = createdAt
        self.model = model
        self.transcribeVersion = transcribeVersion
        self.audioPath = audioPath
        self.audioFiles = audioFiles
        self.basename = basename
        self.sourceMetadata = sourceMetadata
        self.output = output
        self.embeddingModelID = embeddingModelID
        self.speakerMatches = speakerMatches
        self.exports = exports
    }

    static func evidenceID(for fingerprint: SourceFingerprint) -> String {
        evidenceID(forSourceHashes: sourceHashes(for: fingerprint))
    }

    static func sourceHashes(for fingerprint: SourceFingerprint) -> [String] {
        Set(fingerprint.files.map { $0.sha256.lowercased() }).sorted()
    }

    static func evidenceID(forSourceHashes hashes: [String]) -> String {
        let digest = SHA256.hash(data: Data(Set(hashes).sorted().joined(separator: "\n").utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns a copy carrying another document's identity and speaker matches.
    /// Managed store filenames embed the document id, so replacing a stored
    /// file means adopting the id encoded in its name.
    func adopting(id: UUID, speakerMatches: [String: SpeakerMatch]) -> CanonicalTranscript {
        CanonicalTranscript(
            schemaVersion: schemaVersion, id: id, evidenceID: evidenceID, sourceHashes: sourceHashes,
            createdAt: createdAt, model: model, transcribeVersion: transcribeVersion,
            audioPath: audioPath, audioFiles: audioFiles, basename: basename,
            sourceMetadata: sourceMetadata, output: output, embeddingModelID: embeddingModelID,
            speakerMatches: speakerMatches, exports: exports
        )
    }

    /// Returns an export view with accepted profile names substituted for local speaker IDs.
    /// The stored output remains unchanged so profile decisions can be reviewed or reversed.
    func renderedOutput() -> TranscriptionOutput {
        var rendered = output
        rendered.segments = output.segments.map { segment in
            var copy = segment
            guard let localID = segment.speaker, let match = speakerMatches[localID] else { return copy }
            switch match.status {
            case .automatic, .confirmed:
                copy.speaker = match.name
            case .suggested:
                break
            }
            return copy
        }
        return rendered
    }
}

enum CanonicalTranscriptStore {
    enum StoreError: Error, LocalizedError, Equatable {
        case unsupportedSchema(Int)
        case invalidData(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version): return "Unsupported canonical transcript schema version: \(version)"
            case .invalidData(let reason): return "Invalid canonical transcript: \(reason)"
            }
        }
    }

    /// The only field the duplicate scan compares. Decoding this instead of the
    /// whole canonical document keeps one damaged, truncated or newer-schema
    /// file from failing every later save, and avoids reading stored embedding
    /// vectors just to compare one identity string.
    private struct EvidenceListing: Decodable {
        let evidenceID: String
    }

    static func save(_ document: CanonicalTranscript, to url: URL? = nil) throws -> URL {
        try validate(document)
        let isManagedDestination = url == nil
        // Evidence IDs are derived from the source audio, so re-running the
        // same recording produces the same one. A managed save replaces the
        // stored document for that evidence instead of adding a second file,
        // which would grow the transcripts listing without end. An explicit
        // destination is a portable copy the caller placed, so it is written
        // as asked and never deduped.
        var document = document
        var destination: URL
        if let url {
            destination = url
        } else if let existing = existingManagedFile(forEvidenceID: document.evidenceID) {
            let previous = try? load(from: existing.url)
            document = document.adopting(
                id: existing.id, speakerMatches: confirmedMatchesCarriedForward(to: document, from: previous)
            )
            // A rerun of the same audio (a --no-outputs enrollment run, say)
            // knows nothing about files earlier runs exported; dropping their
            // records here would orphan those files from future refreshes.
            if document.exports == nil { document.exports = previous?.exports }
            destination = existing.url
        } else {
            destination = try defaultURL(for: document.id)
        }
        let directory = destination.deletingLastPathComponent()
        // Only a managed directory this store creates is tightened; an
        // existing one keeps the permissions the user chose for it.
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if isManagedDestination {
                try tightenPermissions(ofPath: directory.path, to: privateDirectoryMode)
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)

        try writePrivateAtomically(data: data, to: destination)
        return destination
    }

    static func load(from url: URL) throws -> CanonicalTranscript {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(CanonicalTranscript.self, from: Data(contentsOf: url))
        try validate(document)
        return document
    }

    /// Returns the stored file already holding `evidenceID`, with the id its
    /// name encodes. Only files this store named are candidates: replacing a
    /// file in place keeps the filename, so the replacement has to adopt that
    /// id, which a foreign filename cannot supply. Anything unreadable at this
    /// depth is skipped rather than failing the save it was scanned for.
    private static func existingManagedFile(forEvidenceID evidenceID: String) -> (url: URL, id: UUID)? {
        guard let directory = try? transcriptsDirectoryURL(),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              ) else { return nil }
        let suffix = ".transcript.json"
        // Sorted so a directory that somehow holds several files for one
        // evidence ID collapses onto the same one on every run.
        for file in files.sorted(by: { $0.path < $1.path }) where file.lastPathComponent.hasSuffix(suffix) {
            guard let id = UUID(uuidString: String(file.lastPathComponent.dropLast(suffix.count))),
                  let data = try? Data(contentsOf: file),
                  let listing = try? JSONDecoder().decode(EvidenceListing.self, from: data),
                  listing.evidenceID == evidenceID else { continue }
            return (file, id)
        }
        return nil
    }

    /// Merges the confirmed assignments of the previously stored document into
    /// the matches of a new run over the same evidence. Confirmations are keyed by
    /// (evidence ID, speaker ID) in the profile store, so they stay valid
    /// across a re-run of the same audio, but only where the new run still
    /// produced an embedding for that speaker: a speaker the new diarization
    /// did not emit has nothing to attach the decision to. Everything else
    /// keeps the fresh suggested or automatic match. A stored file that no
    /// longer loads in full is still replaced, only without its confirmations.
    private static func confirmedMatchesCarriedForward(
        to document: CanonicalTranscript, from previous: CanonicalTranscript?
    ) -> [String: SpeakerMatch] {
        guard let previous else { return document.speakerMatches }
        var matches = document.speakerMatches
        for (speakerID, match) in previous.speakerMatches
        where match.status == .confirmed && document.output.speakerEmbeddings[speakerID] != nil {
            matches[speakerID] = match
        }
        return matches
    }

    private static func transcriptsDirectoryURL() throws -> URL {
        try StatePaths.stateDirectoryURL().appendingPathComponent("transcripts", isDirectory: true)
    }

    private static func defaultURL(for id: UUID) throws -> URL {
        try transcriptsDirectoryURL()
            .appendingPathComponent("\(id.uuidString.lowercased()).transcript.json", isDirectory: false)
    }

    static func validate(_ document: CanonicalTranscript) throws {
        guard document.schemaVersion == CanonicalTranscript.currentSchemaVersion else {
            throw StoreError.unsupportedSchema(document.schemaVersion)
        }
        guard document.evidenceID.hasPrefix("sha256:"), document.evidenceID.count == 71,
              document.evidenceID.dropFirst(7).allSatisfy({ $0.isHexDigit }),
              !document.model.isEmpty, !document.transcribeVersion.isEmpty,
              !document.audioPath.isEmpty, !document.basename.isEmpty,
              !document.embeddingModelID.isEmpty else {
            throw StoreError.invalidData("required string is empty")
        }
        guard document.sourceHashes == Set(document.sourceHashes).sorted(),
              document.sourceHashes.allSatisfy({
                  $0.count == 64 && $0.allSatisfy(\.isHexDigit) && $0 == $0.lowercased()
              }),
              document.evidenceID == CanonicalTranscript.evidenceID(forSourceHashes: document.sourceHashes) else {
            throw StoreError.invalidData("source hash evidence is invalid")
        }
        // Exporters convert seconds to integer milliseconds. Leave rounding
        // headroom so imported documents cannot overflow those conversions.
        let maximumSeconds = Double(Int.max / 2000)
        guard document.output.durationSeconds.isFinite, document.output.durationSeconds >= 0,
              document.output.durationSeconds <= maximumSeconds else {
            throw StoreError.invalidData("duration is not finite and non-negative")
        }
        for segment in document.output.segments {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
                  segment.end >= segment.start, segment.end <= maximumSeconds else {
                throw StoreError.invalidData("segment timing is invalid")
            }
            for word in segment.words ?? [] where !word.start.isFinite || !word.end.isFinite || word.start < 0 || word.end < word.start || word.end > maximumSeconds {
                throw StoreError.invalidData("word timing is invalid")
            }
        }
        let localIDs = Set(document.output.segments.compactMap(\.speaker).filter(isLocalSpeakerID))
        for (speakerID, vector) in document.output.speakerEmbeddings {
            guard isLocalSpeakerID(speakerID), localIDs.contains(speakerID), !vector.isEmpty,
                  vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else {
                throw StoreError.invalidData("speaker embedding reference or vector is invalid")
            }
        }
        for speakerID in document.speakerMatches.keys {
            guard isLocalSpeakerID(speakerID), localIDs.contains(speakerID),
                  document.output.speakerEmbeddings[speakerID] != nil else {
                throw StoreError.invalidData("speaker match reference is invalid")
            }
            let match = document.speakerMatches[speakerID]!
            guard !match.profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  match.profileID.rangeOfCharacter(from: .controlCharacters) == nil,
                  !match.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  match.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  match.distance.isFinite, (0...2).contains(match.distance),
                  match.confirmedExampleCount >= 0,
                  match.margin.map({ $0.isFinite && (0...2).contains($0) }) ?? true else {
                throw StoreError.invalidData("speaker match evidence is invalid")
            }
        }
        for record in document.exports ?? [] {
            guard record.path.hasPrefix("/"),
                  record.path.rangeOfCharacter(from: .controlCharacters) == nil,
                  validOutputFormats.contains(record.format),
                  // Every writer names files "<basename>.<format>", so a path
                  // whose extension disagrees with its format was not written
                  // by transcribe and must never become a refresh target.
                  (record.path as NSString).pathExtension.lowercased() == record.format,
                  record.sha256.count == 64,
                  record.sha256.allSatisfy({ $0.isHexDigit }),
                  record.sha256 == record.sha256.lowercased() else {
                throw StoreError.invalidData("export record is invalid")
            }
        }
    }

    private static func isLocalSpeakerID(_ value: String) -> Bool {
        guard value.hasPrefix("SPEAKER_"), value.count > 8 else { return false }
        return value.dropFirst(8).allSatisfy(\.isNumber)
    }
}
