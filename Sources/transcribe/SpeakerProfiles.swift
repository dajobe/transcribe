import Foundation

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

/// Confirmed speaker profiles, stored as `profiles` and `profile_examples`
/// rows in the state database. Every method runs in a transaction that joins
/// a caller's, so a profile change made while a managed document is being
/// edited commits or rolls back together with the document rows.
enum SpeakerProfileStore {
    // Conservative starting heuristics, not calibrated identity probabilities.
    static let suggestionThreshold = 0.30
    static let automaticThreshold = 0.15
    static let marginThreshold = 0.10

    private struct Candidate {
        let profile: SpeakerProfile
        let distance: Double
        let count: Int
        let hasIndependentSupport: Bool
    }

    static func profiles() throws -> [SpeakerProfile] {
        try StateStore.withDatabase { database in
            // Profiles and their examples are separate queries; one read
            // transaction keeps a concurrent confirmation from landing
            // between them.
            try database.inTransaction(.read) { try loadProfiles(in: database) }
        }
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
        return try write { database in
            var profiles = try loadProfiles(in: database)
            // --name is idempotent, but a different name corrects this example
            // instead of renaming the original person and all their examples.
            let named = profiles.filter { $0.name == cleanName }
            guard profileID != nil || named.count <= 1 else {
                throw SpeakerProfileError.invalidStore("name is ambiguous; select --profile")
            }
            let id = profileID ?? named.first?.id ?? UUID().uuidString
            if profileID != nil && !profiles.contains(where: { $0.id == id }) {
                throw SpeakerProfileError.profileNotFound
            }
            let isNewProfile = !profiles.contains(where: { $0.id == id })
            if isNewProfile {
                profiles.append(SpeakerProfile(id: id, name: cleanName, examples: []))
            }
            // A correction moves this evidence rather than teaching two people
            // the same confirmed local speaker.
            for index in profiles.indices {
                profiles[index].examples.removeAll {
                    $0.transcriptID == transcriptID && $0.speakerID == speakerID
                }
            }
            let index = profiles.firstIndex { $0.id == id }!
            let example = SpeakerProfileExample(
                transcriptID: transcriptID, speakerID: speakerID, modelID: modelID,
                embedding: embedding, sourceHashes: sourceHashes
            )
            profiles[index].examples.append(example)
            // The whole resulting store must still be valid (per-model
            // dimensions in particular) before any row changes.
            try validate(profiles)

            if isNewProfile {
                try database.execute("INSERT INTO profiles (id, name) VALUES (?, ?)", [.text(id), .text(cleanName)])
            }
            try database.execute(
                "DELETE FROM profile_examples WHERE transcript_id = ? AND speaker_id = ?",
                [.text(transcriptID), .text(speakerID)]
            )
            try insert(example, profileID: id, in: database)
            let profile = profiles[index]
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
        try write { database in
            try database.execute("UPDATE profiles SET name = ? WHERE id = ?", [.text(cleanName), .text(profileID)])
            guard database.changes > 0 else { throw SpeakerProfileError.profileNotFound }
        }
    }

    static func delete(profileID: String) throws {
        try write { database in
            // Examples go with the profile (ON DELETE CASCADE). Saved
            // transcripts keep their match name snapshots: speaker_matches
            // deliberately has no foreign key to profiles.
            try database.execute("DELETE FROM profiles WHERE id = ?", [.text(profileID)])
            guard database.changes > 0 else { throw SpeakerProfileError.profileNotFound }
        }
    }

    static func removeExample(profileID: String, transcriptID: String, speakerID: String) throws {
        try write { database in
            guard try profileExists(profileID, in: database) else { throw SpeakerProfileError.profileNotFound }
            try database.execute(
                "DELETE FROM profile_examples WHERE profile_id = ? AND transcript_id = ? AND speaker_id = ?",
                [.text(profileID), .text(transcriptID), .text(speakerID)]
            )
        }
    }

    static func clearExamples(transcriptID: String, speakerID: String) throws {
        try write { database in
            try database.execute(
                "DELETE FROM profile_examples WHERE transcript_id = ? AND speaker_id = ?",
                [.text(transcriptID), .text(speakerID)]
            )
        }
    }

    /// The 2.x `speaker_profiles.json` layout, read by migration and written
    /// by `export-legacy`.
    private struct LegacyStoreFile: Codable {
        static let schemaVersion = 1
        let schemaVersion: Int
        let profiles: [SpeakerProfile]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case profiles
        }
    }

    /// The stored profiles as a 2.x `speaker_profiles.json`, encoded exactly
    /// as the 2.x store wrote it (sorted keys, pretty printed, no trailing
    /// newline). Profiles and examples keep insertion order, which is the
    /// order the 2.x store appended them in, so a migrated store exports
    /// unchanged. The rows get the same validation every load applies. The
    /// caller provides the transaction.
    static func legacyStoreData(in database: StateDatabase) throws -> (data: Data, count: Int) {
        let profiles = try loadProfiles(in: database)
        let order = try database.query("SELECT id FROM profiles ORDER BY rowid") { $0.text(0) ?? "" }
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = profiles.sorted { (position[$0.id] ?? .max, $0.id) < (position[$1.id] ?? .max, $1.id) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let file = LegacyStoreFile(schemaVersion: LegacyStoreFile.schemaVersion, profiles: ordered)
        return (try encoder.encode(file), ordered.count)
    }

    /// Imports a 2.x profile store into empty profile tables, applying the
    /// same checks the JSON store's loader did. Any failure throws
    /// `invalidStore` rather than importing part of the shared profile state.
    /// Examples insert in file order, which is confirmation order. The caller
    /// provides the transaction. Returns the number of profiles imported.
    @discardableResult
    static func importLegacyStore(data: Data, in database: StateDatabase) throws -> Int {
        let file: LegacyStoreFile
        do {
            file = try JSONDecoder().decode(LegacyStoreFile.self, from: data)
        } catch {
            throw SpeakerProfileError.invalidStore(error.localizedDescription)
        }
        guard file.schemaVersion == LegacyStoreFile.schemaVersion else {
            throw SpeakerProfileError.invalidStore("unsupported schema version")
        }
        try validate(file.profiles)
        for profile in file.profiles {
            try database.execute(
                "INSERT INTO profiles (id, name) VALUES (?, ?)", [.text(profile.id), .text(profile.name)]
            )
            for example in profile.examples {
                try insert(example, profileID: profile.id, in: database)
            }
        }
        return file.profiles.count
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

    // MARK: - Rows

    /// Runs `body` in a write transaction, joining the caller's when one is
    /// open (a managed document edit), so profile and document rows commit
    /// together.
    private static func write<T>(_ body: (StateDatabase) throws -> T) throws -> T {
        try StateStore.withDatabase { database in
            try database.inTransaction(.write) { try body(database) }
        }
    }

    private static func profileExists(_ id: String, in database: StateDatabase) throws -> Bool {
        !(try database.query("SELECT 1 FROM profiles WHERE id = ?", [.text(id)]) { _ in true }.isEmpty)
    }

    private static func insert(_ example: SpeakerProfileExample, profileID: String, in database: StateDatabase) throws {
        let hashes = String(decoding: try JSONEncoder().encode(example.sourceHashes), as: UTF8.self)
        try database.execute(
            """
            INSERT INTO profile_examples (profile_id, transcript_id, speaker_id, model_id, vector, source_hashes)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .text(profileID), .text(example.transcriptID), .text(example.speakerID),
                .text(example.modelID), .blob(Float32Blob.encode(example.embedding)), .text(hashes),
            ]
        )
    }

    /// Every profile with its examples, sorted by ID, examples in the order
    /// they were confirmed. The stored rows get the same semantic validation
    /// the JSON store applied on every load: rows can be edited outside this
    /// tool, and matching must never compare against an invalid vector.
    private static func loadProfiles(in database: StateDatabase) throws -> [SpeakerProfile] {
        var profiles: [SpeakerProfile]
        do {
            profiles = try database.query("SELECT id, name FROM profiles") {
                SpeakerProfile(id: $0.text(0) ?? "", name: $0.text(1) ?? "", examples: [])
            }
            let positions = Dictionary(
                profiles.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            let examples = try database.query(
                """
                SELECT profile_id, transcript_id, speaker_id, model_id, vector, source_hashes
                FROM profile_examples ORDER BY rowid
                """
            ) { row -> (String, SpeakerProfileExample) in
                let transcriptID = row.text(1) ?? ""
                let hashes = try JSONDecoder().decode([String].self, from: Data((row.text(5) ?? "").utf8))
                guard !hashes.isEmpty else { throw SpeakerProfileError.invalidStore("missing source evidence") }
                return (row.text(0) ?? "", SpeakerProfileExample(
                    transcriptID: transcriptID, speakerID: row.text(2) ?? "", modelID: row.text(3) ?? "",
                    embedding: try Float32Blob.decode(row.blob(4) ?? Data()), sourceHashes: hashes
                ))
            }
            for (profileID, example) in examples {
                // The foreign key makes an orphan impossible while
                // foreign_keys is on; one inserted without it is ignored, as a
                // dangling row would be by any reader.
                guard let position = positions[profileID] else { continue }
                profiles[position].examples.append(example)
            }
        } catch let error as DecodingError {
            throw SpeakerProfileError.invalidStore(error.localizedDescription)
        } catch StateDatabaseError.invalidVectorBlob(let byteCount) {
            throw SpeakerProfileError.invalidStore(
                StateDatabaseError.invalidVectorBlob(byteCount: byteCount).localizedDescription
            )
        }
        try validate(profiles)
        return profiles.sorted { $0.id < $1.id }
    }

    private static func validate(_ profiles: [SpeakerProfile]) throws {
        var profileIDs = Set<String>()
        var identities = Set<[String]>()
        var dimensions: [String: Int] = [:]
        for profile in profiles {
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
}
