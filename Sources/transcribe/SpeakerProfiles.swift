import Foundation
import Darwin

enum SpeakerMatchStatus: String, Codable { case suggested, automatic, confirmed }

struct SpeakerMatch: Codable, Equatable {
    let profileID: String
    let name: String
    let distance: Double
    let margin: Double?
    let confirmedExampleCount: Int
    let status: SpeakerMatchStatus
}

struct SpeakerProfileExample: Codable, Equatable {
    /// Content-derived evidence ID, not a canonical artifact UUID.
    let transcriptID: String
    let speakerID: String
    let modelID: String
    let embedding: [Float]
    let sourceHashes: [String]

    init(transcriptID: String, speakerID: String, modelID: String,
         embedding: [Float], sourceHashes: [String] = []) {
        self.transcriptID = transcriptID
        self.speakerID = speakerID
        self.modelID = modelID
        self.embedding = embedding
        self.sourceHashes = sourceHashes.isEmpty ? [transcriptID] : Set(sourceHashes).sorted()
    }

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case speakerID = "speaker_id"
        case modelID = "model_id"
        case embedding
        case sourceHashes = "source_hashes"
    }
}

struct SpeakerProfile: Codable, Equatable {
    let id: String
    var name: String
    var examples: [SpeakerProfileExample]
}

enum SpeakerProfileError: Error, LocalizedError, Equatable {
    case invalidEmbedding
    case invalidIdentifier
    case inconsistentDimensions
    case invalidStore(String)
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidEmbedding: return "Speaker embedding must be finite and nonzero."
        case .invalidIdentifier: return "Speaker names and identifiers must be nonempty and contain no control characters."
        case .inconsistentDimensions: return "Speaker embeddings have inconsistent dimensions for one model."
        case .invalidStore(let message): return "Invalid speaker profile store: \(message)"
        case .profileNotFound: return "Speaker profile was not found."
        }
    }
}

enum SpeakerProfileStore {
    // Conservative starting heuristics, not calibrated identity probabilities.
    static let suggestionThreshold = 0.30
    static let automaticThreshold = 0.15
    static let marginThreshold = 0.10
    private static let schemaVersion = 1

    private struct StoreFile: Codable {
        let schemaVersion: Int
        var profiles: [SpeakerProfile]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case profiles
        }
    }

    private struct Candidate {
        let profile: SpeakerProfile
        let distance: Double
        let count: Int
        let hasIndependentSupport: Bool
    }

    static func profiles() throws -> [SpeakerProfile] {
        try withLock { try load().profiles.sorted { $0.id < $1.id } }
    }

    static func matches(
        embeddings: [String: [Float]], modelID: String,
        excludingTranscriptID: String? = nil, excludingSourceHashes: [String] = []
    ) throws -> [String: SpeakerMatch] {
        try validateIdentifier(modelID)
        for vector in embeddings.values { try validateVector(vector) }
        guard !embeddings.isEmpty else { return [:] }
        let stored = try profiles()
        let excluded = Set(excludingSourceHashes)
        var result: [String: SpeakerMatch] = [:]
        for (speakerID, vector) in embeddings {
            let candidates = stored.compactMap { profile -> Candidate? in
                let examples = profile.examples.filter {
                    $0.modelID == modelID && $0.transcriptID != excludingTranscriptID
                        && excluded.isDisjoint(with: $0.sourceHashes)
                        && $0.embedding.count == vector.count
                }
                let ranked = examples.map { (example: $0, distance: cosineDistance(vector, $0.embedding)) }
                    .sorted {
                        if $0.distance != $1.distance { return $0.distance < $1.distance }
                        if $0.example.transcriptID != $1.example.transcriptID {
                            return $0.example.transcriptID < $1.example.transcriptID
                        }
                        return $0.example.speakerID < $1.example.speakerID
                    }
                guard let first = ranked.first else { return nil }
                let strong = ranked.filter { $0.distance <= automaticThreshold }
                var independent = false
                for (index, lhs) in strong.enumerated() {
                    if strong.dropFirst(index + 1).contains(where: {
                        lhs.example.transcriptID != $0.example.transcriptID
                            && Set(lhs.example.sourceHashes).isDisjoint(with: $0.example.sourceHashes)
                    }) {
                        independent = true
                        break
                    }
                }
                return Candidate(profile: profile, distance: first.distance,
                                 count: Set(examples.map(\.transcriptID)).count,
                                 hasIndependentSupport: independent)
            }.sorted {
                $0.distance == $1.distance ? $0.profile.id < $1.profile.id : $0.distance < $1.distance
            }
            guard let best = candidates.first, best.distance <= suggestionThreshold else { continue }
            let margin = candidates.dropFirst().first.map { $0.distance - best.distance }
            let automatic = best.hasIndependentSupport && (margin ?? .infinity) >= marginThreshold
            result[speakerID] = SpeakerMatch(
                profileID: best.profile.id, name: best.profile.name, distance: best.distance,
                margin: margin, confirmedExampleCount: best.count,
                status: automatic ? .automatic : .suggested
            )
        }
        return demoteConflictingAutomaticMatches(result)
    }

    /// A known person must not be automatically assigned to two local speakers.
    /// Confirmed assignments take precedence when refreshing a saved transcript.
    static func demoteConflictingAutomaticMatches(_ matches: [String: SpeakerMatch]) -> [String: SpeakerMatch] {
        var result = matches
        let groups = Dictionary(grouping: matches.filter { $0.value.status != .suggested },
                                by: { $0.value.profileID })
        for group in groups.values where group.count > 1 {
            for (speakerID, match) in group where match.status == .automatic {
                result[speakerID] = SpeakerMatch(
                    profileID: match.profileID, name: match.name, distance: match.distance,
                    margin: match.margin, confirmedExampleCount: match.confirmedExampleCount,
                    status: .suggested
                )
            }
        }
        return result
    }

    static func confirm(
        name: String, profileID: String?, transcriptID: String, speakerID: String,
        embedding: [Float], modelID: String, sourceHashes: [String] = []
    ) throws -> SpeakerMatch {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for value in [cleanName, transcriptID, speakerID, modelID] + sourceHashes {
            try validateIdentifier(value)
        }
        try validateVector(embedding)
        return try withLock {
            var file = try load()
            // --name is idempotent, but a different name corrects this example
            // instead of renaming the original person and all their examples.
            let named = file.profiles.filter { $0.name == cleanName }
            guard profileID != nil || named.count <= 1 else {
                throw SpeakerProfileError.invalidStore("name is ambiguous; select --profile")
            }
            let id = profileID ?? named.first?.id ?? UUID().uuidString
            if profileID != nil && !file.profiles.contains(where: { $0.id == id }) {
                throw SpeakerProfileError.profileNotFound
            }
            if !file.profiles.contains(where: { $0.id == id }) {
                file.profiles.append(SpeakerProfile(id: id, name: cleanName, examples: []))
            }
            // A correction moves this evidence rather than teaching two people
            // the same confirmed local speaker.
            for index in file.profiles.indices {
                file.profiles[index].examples.removeAll {
                    $0.transcriptID == transcriptID && $0.speakerID == speakerID
                }
            }
            let index = file.profiles.firstIndex { $0.id == id }!
            file.profiles[index].examples.append(SpeakerProfileExample(
                transcriptID: transcriptID, speakerID: speakerID, modelID: modelID,
                embedding: embedding, sourceHashes: sourceHashes
            ))
            try save(file)
            let profile = file.profiles[index]
            return SpeakerMatch(
                profileID: id, name: profile.name, distance: 0, margin: nil,
                confirmedExampleCount: Set(profile.examples.filter { $0.modelID == modelID }.map(\.transcriptID)).count,
                status: .confirmed
            )
        }
    }

    static func rename(profileID: String, name: String) throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateIdentifier(cleanName)
        try withLock {
            var file = try load()
            guard let index = file.profiles.firstIndex(where: { $0.id == profileID }) else {
                throw SpeakerProfileError.profileNotFound
            }
            file.profiles[index].name = cleanName
            try save(file)
        }
    }

    static func delete(profileID: String) throws {
        try withLock {
            var file = try load()
            guard file.profiles.contains(where: { $0.id == profileID }) else {
                throw SpeakerProfileError.profileNotFound
            }
            file.profiles.removeAll { $0.id == profileID }
            try save(file)
        }
    }

    static func removeExample(profileID: String, transcriptID: String, speakerID: String) throws {
        try withLock {
            var file = try load()
            guard let index = file.profiles.firstIndex(where: { $0.id == profileID }) else {
                throw SpeakerProfileError.profileNotFound
            }
            file.profiles[index].examples.removeAll {
                $0.transcriptID == transcriptID && $0.speakerID == speakerID
            }
            try save(file)
        }
    }

    static func clearExamples(transcriptID: String, speakerID: String) throws {
        try withLock {
            var file = try load()
            for index in file.profiles.indices {
                file.profiles[index].examples.removeAll {
                    $0.transcriptID == transcriptID && $0.speakerID == speakerID
                }
            }
            try save(file)
        }
    }

    private static func validateIdentifier(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw SpeakerProfileError.invalidIdentifier
        }
    }

    private static func validateVector(_ vector: [Float]) throws {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else {
            throw SpeakerProfileError.invalidEmbedding
        }
    }

    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let na = sqrt(a.reduce(0.0) { $0 + Double($1) * Double($1) })
        let nb = sqrt(b.reduce(0.0) { $0 + Double($1) * Double($1) })
        return 1 - max(-1, min(1, dot / (na * nb)))
    }

    private static func url() throws -> URL {
        try StatePaths.stateDirectoryURL().appendingPathComponent("speaker_profiles.json")
    }

    private static func withLock<T>(_ body: () throws -> T) throws -> T {
        let directory = try StatePaths.stateDirectoryURL()
        // Only tighten a directory this store creates. The state directory is
        // shared with timing and processing history, so an existing one keeps
        // whatever permissions the user chose for it.
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try tightenPermissions(ofPath: directory.path, to: privateDirectoryMode)
        }
        let lock = try url().appendingPathExtension("lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, privateFileMode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try tightenPermissions(ofFileDescriptor: fd, at: lock.path, to: privateFileMode)
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private static func load() throws -> StoreFile {
        let target = try url()
        guard FileManager.default.fileExists(atPath: target.path) else {
            return StoreFile(schemaVersion: schemaVersion, profiles: [])
        }
        do {
            let file = try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: target))
            guard file.schemaVersion == schemaVersion else {
                throw SpeakerProfileError.invalidStore("unsupported schema version")
            }
            try validate(file)
            return file
        } catch let error as SpeakerProfileError {
            throw error
        } catch {
            throw SpeakerProfileError.invalidStore(error.localizedDescription)
        }
    }

    private static func validate(_ file: StoreFile) throws {
        var profileIDs = Set<String>()
        var identities = Set<[String]>()
        var dimensions: [String: Int] = [:]
        for profile in file.profiles {
            try validateIdentifier(profile.id)
            try validateIdentifier(profile.name)
            guard profileIDs.insert(profile.id).inserted else {
                throw SpeakerProfileError.invalidStore("duplicate profile ID")
            }
            for example in profile.examples {
                for value in [example.transcriptID, example.speakerID, example.modelID] + example.sourceHashes {
                    try validateIdentifier(value)
                }
                guard !example.sourceHashes.isEmpty else {
                    throw SpeakerProfileError.invalidStore("missing source evidence")
                }
                try validateVector(example.embedding)
                guard identities.insert([example.transcriptID, example.speakerID]).inserted else {
                    throw SpeakerProfileError.invalidStore("duplicate example identity")
                }
                if let count = dimensions[example.modelID], count != example.embedding.count {
                    throw SpeakerProfileError.inconsistentDimensions
                }
                dimensions[example.modelID] = example.embedding.count
            }
        }
    }

    private static func save(_ file: StoreFile) throws {
        try validate(file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try writePrivateAtomically(data: try encoder.encode(file), to: try url())
    }
}
