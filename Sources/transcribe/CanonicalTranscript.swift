import CryptoKit
import Foundation

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
        speakerMatches: [String: SpeakerMatch] = [:]
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

    static func save(_ document: CanonicalTranscript, to url: URL? = nil) throws -> URL {
        try validate(document)
        let isManagedDestination = url == nil
        let destination = try url ?? defaultURL(for: document.id)
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

    private static func defaultURL(for id: UUID) throws -> URL {
        try StatePaths.stateDirectoryURL()
            .appendingPathComponent("transcripts", isDirectory: true)
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
    }

    private static func isLocalSpeakerID(_ value: String) -> Bool {
        guard value.hasPrefix("SPEAKER_"), value.count > 8 else { return false }
        return value.dropFirst(8).allSatisfy(\.isNumber)
    }
}
