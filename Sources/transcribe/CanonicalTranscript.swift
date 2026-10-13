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
    /// Local speakers the user marked unidentifiable during review: review
    /// stops prompting for them and refresh assigns them no new matches.
    /// Sorted and unique, or absent when empty. Like `exports`, an additive
    /// optional key within schema version 1.
    var dismissedSpeakers: [String]?
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
        dismissedSpeakers: [String]? = nil,
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
        self.dismissedSpeakers = dismissedSpeakers
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
    /// A managed save that replaces the stored document for the same
    /// evidence keeps that document's id, so the ID users already hold for it
    /// stays valid.
    func adopting(id: UUID, speakerMatches: [String: SpeakerMatch]) -> CanonicalTranscript {
        CanonicalTranscript(
            schemaVersion: schemaVersion, id: id, evidenceID: evidenceID, sourceHashes: sourceHashes,
            createdAt: createdAt, model: model, transcribeVersion: transcribeVersion,
            audioPath: audioPath, audioFiles: audioFiles, basename: basename,
            sourceMetadata: sourceMetadata, output: output, embeddingModelID: embeddingModelID,
            speakerMatches: speakerMatches, dismissedSpeakers: dismissedSpeakers, exports: exports
        )
    }

    /// Whether review marked this local speaker as not identifiable.
    func isDismissed(_ speaker: String) -> Bool {
        dismissedSpeakers?.contains(speaker) ?? false
    }

    /// Adds a speaker to the dismissed set, keeping it sorted and unique.
    mutating func markDismissed(_ speaker: String) {
        dismissedSpeakers = Set(dismissedSpeakers ?? []).union([speaker]).sorted()
    }

    /// Removes a speaker from the dismissed set, dropping the key entirely
    /// when the set empties so untouched documents stay byte-identical.
    mutating func clearDismissed(_ speaker: String) {
        let remaining = (dismissedSpeakers ?? []).filter { $0 != speaker }
        dismissedSpeakers = remaining.isEmpty ? nil : remaining
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

/// One row of the saved-transcripts listing, read without touching segment
/// payloads or embedding vectors.
struct TranscriptListing: Equatable {
    /// The stored ID text as written. `id` is nil when it does not parse as
    /// a UUID; callers report that row unreadable in place rather than
    /// letting one damaged row hide the whole listing.
    let rawID: String
    let id: UUID?
    let basename: String
    let updatedAt: String
}

/// A canonical document without its segment payload: everything review
/// planning, the read-only review table, and inspect consume. Managed
/// documents build it from lifted columns (`segment_count`,
/// `segment_speakers`), so those commands never read the payload.
struct TranscriptSummary: Equatable {
    let id: UUID
    let basename: String
    let model: String
    let durationSeconds: Double
    let segmentCount: Int
    /// Distinct segment speaker labels, sorted.
    let segmentSpeakers: [String]
    let evidenceID: String
    let sourceHashes: [String]
    let embeddingModelID: String
    let speakerEmbeddings: [String: [Float]]
    var speakerMatches: [String: SpeakerMatch]
    var dismissedSpeakers: [String]?

    init(
        id: UUID, basename: String, model: String, durationSeconds: Double,
        segmentCount: Int, segmentSpeakers: [String], evidenceID: String,
        sourceHashes: [String], embeddingModelID: String,
        speakerEmbeddings: [String: [Float]], speakerMatches: [String: SpeakerMatch],
        dismissedSpeakers: [String]?
    ) {
        self.id = id
        self.basename = basename
        self.model = model
        self.durationSeconds = durationSeconds
        self.segmentCount = segmentCount
        self.segmentSpeakers = segmentSpeakers
        self.evidenceID = evidenceID
        self.sourceHashes = sourceHashes
        self.embeddingModelID = embeddingModelID
        self.speakerEmbeddings = speakerEmbeddings
        self.speakerMatches = speakerMatches
        self.dismissedSpeakers = dismissedSpeakers
    }

    init(_ document: CanonicalTranscript) {
        self.init(
            id: document.id, basename: document.basename, model: document.model,
            durationSeconds: document.output.durationSeconds,
            segmentCount: document.output.segments.count,
            segmentSpeakers: CanonicalTranscriptStore.segmentSpeakers(of: document.output.segments),
            evidenceID: document.evidenceID, sourceHashes: document.sourceHashes,
            embeddingModelID: document.embeddingModelID,
            speakerEmbeddings: document.output.speakerEmbeddings,
            speakerMatches: document.speakerMatches, dismissedSpeakers: document.dismissedSpeakers
        )
    }

    func isDismissed(_ speaker: String) -> Bool {
        dismissedSpeakers?.contains(speaker) ?? false
    }
}

/// Stores canonical transcripts. Managed documents are rows in the state
/// database (`documents` plus its child tables); portable documents are
/// `.transcript.json` files at a caller-chosen path, written and read with
/// the schema version 1 JSON coding. Validation runs on load and before save
/// for both.
enum CanonicalTranscriptStore {
    enum StoreError: Error, LocalizedError, Equatable {
        case unsupportedSchema(Int)
        case invalidData(String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version): return "Unsupported canonical transcript schema version: \(version)"
            case .invalidData(let reason): return "Invalid canonical transcript: \(reason)"
            case .notFound(let id): return "No saved transcript has ID \(id)."
            }
        }
    }

    // MARK: - References

    static func load(_ ref: TranscriptRef) throws -> CanonicalTranscript {
        switch ref {
        case .managed(let id): return try load(id: id)
        case .portable(let url): return try load(from: url)
        }
    }

    /// Persists a command's edit of a document it loaded from `ref`. A
    /// portable save rewrites the file. A managed save writes only the state
    /// commands change — speaker matches, dismissals, and export records —
    /// so confirming a speaker touches a few rows rather than the segment
    /// payload; a stored document's transcription content changes only
    /// through `saveManaged`.
    static func save(_ document: CanonicalTranscript, to ref: TranscriptRef) throws {
        switch ref {
        case .portable(let url):
            _ = try save(document, to: url)
        case .managed(let id):
            try validate(document)
            guard document.id == id else {
                throw StoreError.invalidData("document ID does not match the saved transcript it replaces")
            }
            try StateStore.withDatabase { database in
                try database.inTransaction(.write) {
                    let key = idKey(id)
                    try requireDocument(key, in: database)
                    try writeMutableState(document, key: key, in: database)
                }
            }
        }
    }

    /// Persists only `document.exports`. Export refresh renders under the
    /// document's render lock but not inside a database transaction, so a
    /// speaker change can commit meanwhile; writing just the records keeps
    /// that change instead of overwriting it with the refresh's older copy.
    /// A portable file has no such split and is saved whole.
    static func saveExports(of document: CanonicalTranscript, to ref: TranscriptRef) throws {
        switch ref {
        case .portable(let url):
            _ = try save(document, to: url)
        case .managed(let id):
            try validate(document)
            try StateStore.withDatabase { database in
                try database.inTransaction(.write) {
                    let key = idKey(id)
                    try requireDocument(key, in: database)
                    try writeExports(document.exports, key: key, in: database)
                }
            }
        }
    }

    /// Merges freshly written export records into the document's stored
    /// ones, by path: rewriting a destination replaces its record, a new
    /// destination adds one. The merge reads the current records, so the
    /// caller's copy of the document may be stale. A portable document is
    /// reloaded and saved whole, under the caller's document lock.
    static func mergeExports(_ records: [ExportRecord], into ref: TranscriptRef) throws {
        switch ref {
        case .portable(let url):
            var document = try load(from: url)
            document.exports = merging(records, into: document.exports)
            _ = try save(document, to: url)
        case .managed(let id):
            try StateStore.withDatabase { database in
                try database.inTransaction(.write) {
                    let key = idKey(id)
                    let recorded = try database.query(
                        "SELECT exports_recorded FROM documents WHERE id = ?", [.text(key)]
                    ) { $0.int(0) ?? 0 }
                    guard let flag = recorded.first else { throw StoreError.notFound(key) }
                    let existing = flag != 0 ? try readExports(key: key, in: database) : nil
                    let merged = merging(records, into: existing)
                    try validateExports(merged)
                    try writeExports(merged, key: key, in: database)
                }
            }
        }
    }

    static func merging(_ records: [ExportRecord], into existing: [ExportRecord]?) -> [ExportRecord] {
        var merged = existing ?? []
        for record in records {
            if let index = merged.firstIndex(where: { $0.path == record.path }) {
                merged[index] = record
            } else {
                merged.append(record)
            }
        }
        return merged
    }

    // MARK: - Portable files

    /// Writes the portable JSON form to an explicit destination. A copy the
    /// caller placed is written as asked and never deduplicated.
    static func save(_ document: CanonicalTranscript, to url: URL) throws -> URL {
        try validate(document)
        let directory = url.deletingLastPathComponent()
        // An existing directory keeps the permissions the user chose for it.
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writePrivateAtomically(data: try portableData(document), to: url)
        return url
    }

    /// The exact bytes of the portable schema v1 file: what the explicit
    /// destination save writes, `export-document` exports, and
    /// `export-legacy` dumps. Validates first.
    static func portableData(_ document: CanonicalTranscript) throws -> Data {
        try validate(document)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    static func load(from url: URL) throws -> CanonicalTranscript {
        try load(data: Data(contentsOf: url))
    }

    /// Decodes and validates portable JSON already read, for a caller that
    /// also needs the exact bytes (migration hashes them).
    static func load(data: Data) throws -> CanonicalTranscript {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(CanonicalTranscript.self, from: data)
        try validate(document)
        return document
    }

    // MARK: - Managed documents

    /// Saves a newly produced document into the state database and returns
    /// the ID it is stored under. Evidence IDs are derived from the source
    /// audio, so re-running the same recording produces the same one: the
    /// save replaces the stored document for that evidence, adopting its ID,
    /// instead of adding a second document that would grow the listing
    /// without end.
    @discardableResult
    static func saveManaged(_ document: CanonicalTranscript) throws -> UUID {
        try validate(document)
        return try StateStore.withDatabase { database in
            try database.inTransaction(.write) {
                var document = document
                let existing = try database.query(
                    "SELECT id FROM documents WHERE evidence_id = ?", [.text(document.evidenceID)]
                ) { $0.text(0) ?? "" }.first
                if let existing {
                    guard let existingID = UUID(uuidString: existing) else {
                        throw StoreError.invalidData("stored document ID \(existing) is not a UUID")
                    }
                    // A stored document that no longer loads in full is still
                    // replaced, only without its carried-forward state. Read
                    // directly, not through a joined transaction, so the
                    // failure stays local instead of dooming this save.
                    let previous = try? materialize(id: existingID, in: database)
                    let validPrevious = previous.flatMap { (try? validate($0)) != nil ? $0 : nil }
                    document = document.adopting(
                        id: existingID,
                        speakerMatches: confirmedMatchesCarriedForward(to: document, from: validPrevious)
                    )
                    // A rerun of the same audio (a --no-outputs enrollment run,
                    // say) knows nothing about files earlier runs exported;
                    // dropping their records here would orphan those files
                    // from future refreshes.
                    if document.exports == nil { document.exports = validPrevious?.exports }
                    document.dismissedSpeakers = dismissalsCarriedForward(to: document, from: validPrevious)
                    try validate(document)
                }
                // Replacing by ID too keeps a re-save of a loaded document
                // (or any colliding ID) a replacement, as a same-named file
                // overwrite was.
                try database.execute("DELETE FROM documents WHERE id = ?", [.text(idKey(document.id))])
                try insertDocument(document, in: database)
                return document.id
            }
        }
    }

    struct ImportOutcome: Equatable {
        /// The ID the document is stored under.
        let id: UUID
        /// A stored document for the same recording was replaced.
        let replacedExisting: Bool
        /// The file's own ID, when it was already used by a different
        /// recording and the document was stored under a fresh ID instead.
        let reassignedFrom: UUID?
    }

    /// `transcripts import`: stores a portable document with the managed
    /// save's semantics — a stored document for the same evidence is
    /// replaced, its ID adopted and its confirmations, dismissals and
    /// export records carried forward. The one difference: a file whose own
    /// ID belongs to a different recording gets a fresh ID, since a managed
    /// save's replace-by-ID would silently delete that other document (a
    /// migration conflict file is exactly this case). Joins the caller's
    /// transaction.
    static func importPortable(_ document: CanonicalTranscript) throws -> ImportOutcome {
        try validate(document)
        return try StateStore.withDatabase { database in
            try database.inTransaction(.write) {
                let replaced = !(try database.query(
                    "SELECT 1 FROM documents WHERE evidence_id = ?", [.text(document.evidenceID)]
                ) { _ in true }).isEmpty
                var incoming = document
                var reassignedFrom: UUID?
                if !replaced, !(try database.query(
                    "SELECT 1 FROM documents WHERE id = ?", [.text(idKey(document.id))]
                ) { _ in true }).isEmpty {
                    incoming = document.adopting(id: UUID(), speakerMatches: document.speakerMatches)
                    reassignedFrom = document.id
                }
                let id = try saveManaged(incoming)
                return ImportOutcome(id: id, replacedExisting: replaced, reassignedFrom: reassignedFrom)
            }
        }
    }

    /// Stores a migrated 2.x document exactly as its file had it: its own ID,
    /// no evidence replacement and no carry-forward (migration's preflight
    /// already settled which file wins each ID and evidence ID), and
    /// `updated_at` seeded from the file's mtime so the newest-first review
    /// order survives. The caller provides the transaction.
    static func importMigrated(
        _ document: CanonicalTranscript, updatedAt: Date, in database: StateDatabase
    ) throws {
        try validate(document)
        try insertDocument(document, in: database)
        try database.execute(
            "UPDATE documents SET updated_at = ? WHERE id = ?",
            [.text(iso8601String(updatedAt)), .text(idKey(document.id))]
        )
    }

    static func load(id: UUID) throws -> CanonicalTranscript {
        // One read transaction: the document spans several tables, and a
        // writer committing between the queries would otherwise produce a
        // mixed-generation document.
        let document = try StateStore.withDatabase { database in
            try database.inTransaction(.read) {
                try materialize(id: id, in: database)
            }
        }
        try validate(document)
        return document
    }

    /// Builds the full document from its rows. The caller provides the
    /// transaction; no validation happens here.
    static func materialize(id: UUID, in database: StateDatabase) throws -> CanonicalTranscript {
        let key = idKey(id)
        let rows = try database.query(
            """
            SELECT evidence_id, source_hashes, created_at, model, transcribe_version,
                   audio_path, audio_files, basename, source_metadata, embedding_model_id,
                   language, duration_seconds, diarization_enabled, speakers_detected,
                   speaker_strategy, warnings, exports_recorded
            FROM documents WHERE id = ?
            """,
            [.text(key)]
        ) { row -> CanonicalTranscript in
            let segments = try readSegments(key: key, in: database)
            let output = TranscriptionOutput(
                segments: segments,
                language: row.text(10),
                durationSeconds: row.double(11) ?? 0,
                diarizationEnabled: (row.int(12) ?? 0) != 0,
                speakersDetected: row.int(13).map { Int($0) },
                speakerStrategy: row.text(14) ?? "",
                warnings: try decodeJSON([String].self, row.text(15)),
                speakerEmbeddings: try readEmbeddings(key: key, in: database)
            )
            return CanonicalTranscript(
                id: id,
                evidenceID: row.text(0) ?? "",
                sourceHashes: try decodeJSON([String].self, row.text(1)),
                createdAt: try parseDate(row.text(2)),
                model: row.text(3) ?? "",
                transcribeVersion: row.text(4) ?? "",
                audioPath: row.text(5) ?? "",
                audioFiles: try row.text(6).map { try decodeJSON([String].self, $0) },
                basename: row.text(7) ?? "",
                sourceMetadata: try row.text(8).map { try decodeJSON(OutputSourceMetadata.self, $0) },
                output: output,
                embeddingModelID: row.text(9) ?? "",
                speakerMatches: try readMatches(key: key, in: database),
                dismissedSpeakers: try readDismissed(key: key, in: database),
                exports: (row.int(16) ?? 0) != 0 ? try readExports(key: key, in: database) : nil
            )
        }
        guard let document = rows.first else { throw StoreError.notFound(key) }
        return document
    }

    /// The payload-free view of a stored document.
    static func summary(id: UUID) throws -> TranscriptSummary {
        let key = idKey(id)
        return try StateStore.withDatabase { database in
            try database.inTransaction(.read) {
                let rows = try database.query(
                    """
                    SELECT basename, model, duration_seconds, segment_count, segment_speakers,
                           evidence_id, source_hashes, embedding_model_id
                    FROM documents WHERE id = ?
                    """,
                    [.text(key)]
                ) { row in
                    TranscriptSummary(
                        id: id,
                        basename: row.text(0) ?? "",
                        model: row.text(1) ?? "",
                        durationSeconds: row.double(2) ?? 0,
                        segmentCount: Int(row.int(3) ?? 0),
                        segmentSpeakers: try decodeJSON([String].self, row.text(4)),
                        evidenceID: row.text(5) ?? "",
                        sourceHashes: try decodeJSON([String].self, row.text(6)),
                        embeddingModelID: row.text(7) ?? "",
                        speakerEmbeddings: try readEmbeddings(key: key, in: database),
                        speakerMatches: try readMatches(key: key, in: database),
                        dismissedSpeakers: try readDismissed(key: key, in: database)
                    )
                }
                guard let summary = rows.first else { throw StoreError.notFound(key) }
                try validate(summary)
                return summary
            }
        }
    }

    enum ListingOrder {
        /// By document ID, the `transcripts` listing order.
        case id
        /// Most recently updated first, so an all-documents review reaches
        /// recent recordings before the backlog.
        case recentlyUpdated
    }

    /// Every stored document's ID, title, and update time, read from the
    /// `documents` table alone.
    static func listing(order: ListingOrder = .id) throws -> [TranscriptListing] {
        let orderBy = order == .id ? "id" : "updated_at DESC, id DESC"
        return try StateStore.withDatabase { database in
            try database.inTransaction(.read) {
                try database.query("SELECT id, basename, updated_at FROM documents ORDER BY \(orderBy)") { row in
                    let text = row.text(0) ?? ""
                    return TranscriptListing(
                        rawID: text, id: UUID(uuidString: text),
                        basename: row.text(1) ?? "", updatedAt: row.text(2) ?? ""
                    )
                }
            }
        }
    }

    /// Every stored document ID as written, including rows whose ID does not
    /// parse as a UUID: `IDAbbreviator` needs the complete prefix space.
    static func allDocumentIDs() throws -> [String] {
        try StateStore.withDatabase { database in
            try database.inTransaction(.read) {
                try database.query("SELECT id FROM documents") { $0.text(0) ?? "" }
            }
        }
    }

    /// Saved document IDs keyed by `HistoryFormatter.sourceHashesKey` of
    /// their source hashes, for joining processing-history records to the
    /// documents they produced. A row whose hashes do not decode is skipped:
    /// it only loses that row's history annotation. Should two rows share a
    /// hash set, the most recently updated one wins (ties broken by ID).
    static func documentIDsBySourceHashes() throws -> [String: String] {
        let rows = try StateStore.withDatabase { database in
            try database.inTransaction(.read) {
                try database.query("SELECT id, source_hashes FROM documents ORDER BY updated_at, id") { row in
                    (row.text(0) ?? "", row.text(1) ?? "")
                }
            }
        }
        var map: [String: String] = [:]
        for (id, hashesJSON) in rows {
            guard !id.isEmpty,
                  let hashes = try? JSONDecoder().decode([String].self, from: Data(hashesJSON.utf8)),
                  let key = HistoryFormatter.sourceHashesKey(hashes) else { continue }
            map[key] = id
        }
        return map
    }

    /// Stored document IDs beginning with `prefix` (lowercase hex and
    /// dashes), sorted.
    static func documentIDs(withPrefix prefix: String) throws -> [String] {
        try StateStore.withDatabase { database in
            try database.inTransaction(.read) { try documentIDs(withPrefix: prefix, in: database) }
        }
    }

    /// `documentIDs(withPrefix:)` through `StateDatabase.probeExisting`, for
    /// an argument that may name a plain file: nil whenever the state
    /// database cannot be read without side effects.
    static func probeDocumentIDs(withPrefix prefix: String) -> [String]? {
        StateDatabase.probeExisting { try documentIDs(withPrefix: prefix, in: $0) }
    }

    private static func documentIDs(withPrefix prefix: String, in database: StateDatabase) throws -> [String] {
        try database.query(
            "SELECT id FROM documents WHERE substr(id, 1, ?) = ? ORDER BY id",
            [.integer(Int64(prefix.count)), .text(prefix)]
        ) { $0.text(0) ?? "" }
    }

    /// Distinct segment speaker labels, sorted: the lifted
    /// `segment_speakers` column.
    static func segmentSpeakers(of segments: [TranscriptSegment]) -> [String] {
        Set(segments.compactMap(\.speaker)).sorted()
    }

    // MARK: - Rows

    private static func idKey(_ id: UUID) -> String { id.uuidString.lowercased() }

    private static func requireDocument(_ key: String, in database: StateDatabase) throws {
        let found = try database.query("SELECT 1 FROM documents WHERE id = ?", [.text(key)]) { _ in true }
        guard !found.isEmpty else { throw StoreError.notFound(key) }
    }

    private static func insertDocument(_ document: CanonicalTranscript, in database: StateDatabase) throws {
        let key = idKey(document.id)
        let output = document.output
        try database.execute(
            """
            INSERT INTO documents (
              id, evidence_id, source_hashes, created_at, model, transcribe_version,
              audio_path, audio_files, basename, source_metadata, embedding_model_id,
              language, duration_seconds, diarization_enabled, speakers_detected,
              speaker_strategy, warnings, segment_count, segment_speakers,
              exports_recorded, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            """,
            [
                .text(key),
                .text(document.evidenceID),
                .text(try jsonText(document.sourceHashes)),
                .text(iso8601String(document.createdAt)),
                .text(document.model),
                .text(document.transcribeVersion),
                .text(document.audioPath),
                try document.audioFiles.map { .text(try jsonText($0)) } ?? .null,
                .text(document.basename),
                try document.sourceMetadata.map { .text(try jsonText($0)) } ?? .null,
                .text(document.embeddingModelID),
                output.language.map { .text($0) } ?? .null,
                .real(output.durationSeconds),
                .integer(output.diarizationEnabled ? 1 : 0),
                output.speakersDetected.map { .integer(Int64($0)) } ?? .null,
                .text(output.speakerStrategy),
                .text(try jsonText(output.warnings)),
                .integer(Int64(output.segments.count)),
                .text(try jsonText(segmentSpeakers(of: output.segments))),
                .text(iso8601String(Date())),
            ]
        )
        try database.execute(
            "INSERT INTO document_segments (document_id, encoding, payload) VALUES (?, 'json', ?)",
            [.text(key), .blob(try jsonEncoder().encode(output.segments))]
        )
        for (speaker, vector) in output.speakerEmbeddings.sorted(by: { $0.key < $1.key }) {
            try database.execute(
                "INSERT INTO document_embeddings (document_id, speaker_id, vector) VALUES (?, ?, ?)",
                [.text(key), .text(speaker), .blob(Float32Blob.encode(vector))]
            )
        }
        try writeMutableState(document, key: key, in: database)
    }

    /// Replaces the rows commands edit and bumps `updated_at`.
    private static func writeMutableState(
        _ document: CanonicalTranscript, key: String, in database: StateDatabase
    ) throws {
        try database.execute("DELETE FROM speaker_matches WHERE document_id = ?", [.text(key)])
        for (speaker, match) in document.speakerMatches.sorted(by: { $0.key < $1.key }) {
            try database.execute(
                """
                INSERT INTO speaker_matches
                  (document_id, speaker_id, profile_id, name, distance, margin, example_count, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(key), .text(speaker), .text(match.profileID), .text(match.name),
                    .real(match.distance), match.margin.map { .real($0) } ?? .null,
                    .integer(Int64(match.confirmedExampleCount)), .text(match.status.rawValue),
                ]
            )
        }
        try database.execute("DELETE FROM dismissed_speakers WHERE document_id = ?", [.text(key)])
        for speaker in document.dismissedSpeakers ?? [] {
            try database.execute(
                "INSERT INTO dismissed_speakers (document_id, speaker_id) VALUES (?, ?)",
                [.text(key), .text(speaker)]
            )
        }
        try writeExports(document.exports, key: key, in: database)
    }

    /// Replaces the export records, keeping nil (no records ever) distinct
    /// from an empty list, and bumps `updated_at`; every mutation path ends
    /// here.
    private static func writeExports(
        _ exports: [ExportRecord]?, key: String, in database: StateDatabase
    ) throws {
        try database.execute("DELETE FROM exports WHERE document_id = ?", [.text(key)])
        for (position, record) in (exports ?? []).enumerated() {
            try database.execute(
                """
                INSERT INTO exports (document_id, position, path, format, sha256, exported_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(key), .integer(Int64(position)), .text(record.path), .text(record.format),
                    .text(record.sha256), .text(iso8601String(record.exportedAt)),
                ]
            )
        }
        try database.execute(
            "UPDATE documents SET exports_recorded = ?, updated_at = ? WHERE id = ?",
            [.integer(exports == nil ? 0 : 1), .text(iso8601String(Date())), .text(key)]
        )
    }

    private static func readSegments(key: String, in database: StateDatabase) throws -> [TranscriptSegment] {
        let rows = try database.query(
            "SELECT encoding, payload FROM document_segments WHERE document_id = ?", [.text(key)]
        ) { ($0.text(0) ?? "", $0.blob(1) ?? Data()) }
        guard let (encoding, payload) = rows.first else {
            throw StoreError.invalidData("segment payload is missing")
        }
        guard encoding == "json" else {
            throw StoreError.invalidData("unsupported segment encoding '\(encoding)'")
        }
        return try JSONDecoder().decode([TranscriptSegment].self, from: payload)
    }

    private static func readEmbeddings(key: String, in database: StateDatabase) throws -> [String: [Float]] {
        let rows = try database.query(
            "SELECT speaker_id, vector FROM document_embeddings WHERE document_id = ?", [.text(key)]
        ) { ($0.text(0) ?? "", try Float32Blob.decode($0.blob(1) ?? Data())) }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    private static func readMatches(key: String, in database: StateDatabase) throws -> [String: SpeakerMatch] {
        let rows = try database.query(
            """
            SELECT speaker_id, profile_id, name, distance, margin, example_count, status
            FROM speaker_matches WHERE document_id = ?
            """,
            [.text(key)]
        ) { row -> (String, SpeakerMatch) in
            let statusText = row.text(6) ?? ""
            guard let status = SpeakerMatchStatus(rawValue: statusText) else {
                throw StoreError.invalidData("speaker match status '\(statusText)' is unknown")
            }
            return (row.text(0) ?? "", SpeakerMatch(
                profileID: row.text(1) ?? "", name: row.text(2) ?? "",
                distance: row.double(3) ?? 0, margin: row.double(4),
                confirmedExampleCount: Int(row.int(5) ?? 0), status: status
            ))
        }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    private static func readDismissed(key: String, in database: StateDatabase) throws -> [String]? {
        let speakers = try database.query(
            "SELECT speaker_id FROM dismissed_speakers WHERE document_id = ?", [.text(key)]
        ) { $0.text(0) ?? "" }
        return speakers.isEmpty ? nil : speakers.sorted()
    }

    private static func readExports(key: String, in database: StateDatabase) throws -> [ExportRecord] {
        try database.query(
            "SELECT path, format, sha256, exported_at FROM exports WHERE document_id = ? ORDER BY position",
            [.text(key)]
        ) { row in
            ExportRecord(
                path: row.text(0) ?? "", format: row.text(1) ?? "", sha256: row.text(2) ?? "",
                exportedAt: try parseDate(row.text(3))
            )
        }
    }

    // MARK: - Encoding

    /// Compact JSON for stored columns; same key order and slash handling as
    /// the portable writer, without its indentation.
    private static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func jsonText<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try jsonEncoder().encode(value), as: UTF8.self)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, _ text: String?) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data((text ?? "").utf8))
    }

    /// Stored timestamps are the whole-second strings `.iso8601` coding
    /// writes, so a stored document round-trips through portable JSON
    /// unchanged.
    private static func parseDate(_ text: String?) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let text, let date = formatter.date(from: text) else {
            throw StoreError.invalidData("timestamp '\(text ?? "")' is invalid")
        }
        return date
    }

    // MARK: - Carry-forward

    /// Merges the confirmed assignments of the previously stored document into
    /// the matches of a new run over the same evidence. Confirmations are keyed by
    /// (evidence ID, speaker ID) in the profile store, so they stay valid
    /// across a re-run of the same audio, but only where the new run still
    /// produced an embedding for that speaker: a speaker the new diarization
    /// did not emit has nothing to attach the decision to. Everything else
    /// keeps the fresh suggested or automatic match. A stored document that no
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

    /// Merges the previously stored document's dismissed speakers into a new
    /// run over the same evidence, for the same reason confirmed matches carry
    /// forward: the user already decided those voices cannot be identified.
    /// Only speakers the new run still diarized are kept, since validation
    /// rejects a dismissal without an embedding.
    private static func dismissalsCarriedForward(
        to document: CanonicalTranscript, from previous: CanonicalTranscript?
    ) -> [String]? {
        let carried = (previous?.dismissedSpeakers ?? []).filter {
            document.output.speakerEmbeddings[$0] != nil
        }
        let merged = Set(document.dismissedSpeakers ?? []).union(carried)
        return merged.isEmpty ? nil : merged.sorted()
    }

    // MARK: - Validation

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
        try validateSpeakerState(
            embeddings: document.output.speakerEmbeddings,
            matches: document.speakerMatches,
            dismissed: document.dismissedSpeakers,
            localIDs: localIDs
        )
        try validateExports(document.exports ?? [])
    }

    /// The summary-accessible slice of `validate(_:)`: a payload-free read
    /// (inspect, the review table) must reject the same bad embeddings,
    /// matches and dismissals a full load rejects, with the lifted
    /// `segment_speakers` standing in for the segment-derived local IDs.
    static func validate(_ summary: TranscriptSummary) throws {
        guard summary.evidenceID.hasPrefix("sha256:"), summary.evidenceID.count == 71,
              summary.evidenceID.dropFirst(7).allSatisfy({ $0.isHexDigit }),
              !summary.model.isEmpty, !summary.basename.isEmpty,
              !summary.embeddingModelID.isEmpty else {
            throw StoreError.invalidData("required string is empty")
        }
        guard summary.sourceHashes == Set(summary.sourceHashes).sorted(),
              summary.sourceHashes.allSatisfy({
                  $0.count == 64 && $0.allSatisfy(\.isHexDigit) && $0 == $0.lowercased()
              }),
              summary.evidenceID == CanonicalTranscript.evidenceID(forSourceHashes: summary.sourceHashes) else {
            throw StoreError.invalidData("source hash evidence is invalid")
        }
        guard summary.durationSeconds.isFinite, summary.durationSeconds >= 0,
              summary.segmentCount >= 0 else {
            throw StoreError.invalidData("duration is not finite and non-negative")
        }
        try validateSpeakerState(
            embeddings: summary.speakerEmbeddings,
            matches: summary.speakerMatches,
            dismissed: summary.dismissedSpeakers,
            localIDs: Set(summary.segmentSpeakers.filter(isLocalSpeakerID))
        )
    }

    private static func validateSpeakerState(
        embeddings: [String: [Float]],
        matches: [String: SpeakerMatch],
        dismissed: [String]?,
        localIDs: Set<String>
    ) throws {
        for (speakerID, vector) in embeddings {
            guard isLocalSpeakerID(speakerID), localIDs.contains(speakerID), !vector.isEmpty,
                  vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else {
                throw StoreError.invalidData("speaker embedding reference or vector is invalid")
            }
        }
        for speakerID in matches.keys {
            guard isLocalSpeakerID(speakerID), localIDs.contains(speakerID),
                  embeddings[speakerID] != nil else {
                throw StoreError.invalidData("speaker match reference is invalid")
            }
            let match = matches[speakerID]!
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
        if let dismissed {
            guard dismissed == Set(dismissed).sorted(), !dismissed.isEmpty else {
                throw StoreError.invalidData("dismissed speaker list is not sorted and unique")
            }
            for speakerID in dismissed {
                guard isLocalSpeakerID(speakerID), localIDs.contains(speakerID),
                      embeddings[speakerID] != nil else {
                    throw StoreError.invalidData("dismissed speaker reference is invalid")
                }
            }
        }
    }

    static func validateExports(_ records: [ExportRecord]) throws {
        for record in records {
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
