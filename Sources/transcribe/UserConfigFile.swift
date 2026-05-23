import Foundation

/// Persistent user overrides (nested JSON); `nil` means omitted at merge time.
///
/// Ultra-common keys stay at the top level (`model`, `format`, `language`) so they match
/// how people think about quick edits. Everything else is grouped under nested objects
/// with dotted CLI names (`output.dir`, `speakers.merge`, …).
struct UserConfigFile: Codable, Equatable {
    var model: String?
    var language: String?
    var format: String?

    var output: OutputSection?
    struct OutputSection: Codable, Equatable {
        var dir: String?
        var prefix: String?
    }

    var cache: CacheSection?
    struct CacheSection: Codable, Equatable {
        var modelDir: String?
    }

    /// Speaker labels and merge settings (maps to global CLI speaker options).
    var speakers: SpeakersSection?
    struct SpeakersSection: Codable, Equatable {
        var enabled: Bool?
        var merge: String?
        var min: Int?
        var max: Int?
    }

    var compute: ComputeSection?
    struct ComputeSection: Codable, Equatable {
        var audioEncoder: String?
        var textDecoder: String?
        var segmenter: String?
        var embedder: String?
    }

    var logging: LoggingSection?
    struct LoggingSection: Codable, Equatable {
        var verbose: Bool?
        var etaHints: Bool?
        var progressLog: String?
    }

    var dir: DirSection?
    struct DirSection: Codable, Equatable {
        var sort: String?
        var sessionGap: Int?
        var inputTimeSource: String?
        var sessionNaming: String?
    }

    var voiceMemos: VoiceMemosSection?
    struct VoiceMemosSection: Codable, Equatable {
        var recordingsDir: String?
        var sessionGap: Int?
    }

    init() {}

    static func load(from url: URL) throws -> UserConfigFile {
        warnIfWorldReadable(at: url)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(UserConfigFile.self, from: data)
    }

    /// Returns empty config if the file is missing; fails on malformed JSON.
    static func loadOrEmpty(from url: URL) throws -> UserConfigFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return UserConfigFile()
        }
        return try load(from: url)
    }

    static func save(_ config: UserConfigFile, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let tmp = dir.appendingPathComponent(".config.\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int(0o600))],
            ofItemAtPath: url.path
        )
    }

    static func warnIfWorldReadable(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let mode = fileModeBits(atPath: url.path) else { return }
        if mode & 0o004 != 0 {
            emitWarning("Config file is world-readable: \(url.path)")
        }
    }
}
