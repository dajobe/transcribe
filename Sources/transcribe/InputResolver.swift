import ArgumentParser
import AVFoundation
import Foundation

/// The result of inspecting the positional `audioFile` argument: either a
/// single audio file or a directory of sequential audio clips to be
/// concatenated and transcribed as one logical recording.
enum ResolvedInput: Equatable {
    case file(path: String)
    case directory(path: String, files: [String])
}

/// How directory inputs are ordered before concatenation.
enum InputSortOrder: String, CaseIterable, ExpressibleByArgument {
    /// Embedded recording timestamp (e.g. M4A creation_time atom). Falls
    /// back to file modification time, then natural-sort filename, when the
    /// embedded date is missing — which keeps a deterministic order even
    /// across mixed-format directories.
    case recorded
    /// Natural-sort by filename: handles "Note 1, Note 2, …, Note 10".
    case name
    /// File modification time, oldest first.
    case mtime
}

enum InputResolver {
    /// Resolves a user-supplied path into a single-file or directory input.
    /// - Parameter sort: directory ordering policy (default: `.recorded`).
    /// - Throws: `TranscribeError(.inputFile, ...)` for missing paths,
    ///   non-readable directories, or directories with no supported audio files.
    static func resolve(_ rawArg: String, sort: InputSortOrder = .recorded) async throws -> ResolvedInput {
        let expanded = (rawArg as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            throw TranscribeError(
                message: "Input does not exist: \(rawArg)",
                exitCode: .inputFile
            )
        }

        if !isDir.boolValue {
            return .file(path: expanded)
        }

        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: expanded)
        } catch {
            throw TranscribeError(
                message: "Cannot read input directory: \(rawArg): \(error.localizedDescription)",
                exitCode: .inputFile
            )
        }

        let candidates = entries
            .filter { !$0.hasPrefix(".") }
            .filter { name in
                let ext = (name as NSString).pathExtension.lowercased()
                guard !ext.isEmpty,
                    AudioLoader.supportedExtensions.contains(ext) else { return false }
                let full = (expanded as NSString).appendingPathComponent(name)
                var entryIsDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &entryIsDir) else {
                    return false
                }
                return !entryIsDir.boolValue
            }
            .map { (expanded as NSString).appendingPathComponent($0) }

        if candidates.isEmpty {
            throw TranscribeError(
                message:
                    "No audio files found in directory: \(rawArg). Supported formats: \(AudioLoader.supportedFormats).",
                exitCode: .inputFile
            )
        }

        let sortedFiles = try await sortPaths(candidates, by: sort)
        return .directory(path: expanded, files: sortedFiles)
    }

    /// Output basename for a resolved input.
    /// - For files: `meeting.mp3` -> `meeting` (existing behaviour).
    /// - For directories: `~/voicenotes/2026-meeting/` -> `2026-meeting`. No
    ///   extension stripping (preserves `2026.04.notes` etc.).
    static func basename(for resolved: ResolvedInput) -> String {
        switch resolved {
        case .file(let path):
            return outputBasename(audioPath: path)
        case .directory(let path, _):
            return outputBasename(directoryPath: path)
        }
    }

    // MARK: - Sorting

    private struct SortKey {
        let path: String
        let recorded: Date?
        let mtime: Date?
        let name: String
    }

    /// Builds a sort key for each path according to `mode`, then sorts.
    /// All modes use a stable fallback chain (recorded → mtime → natural-sort
    /// filename) so the order remains deterministic when the primary key is
    /// missing or tied.
    private static func sortPaths(_ paths: [String], by mode: InputSortOrder) async throws -> [String] {
        var keys: [SortKey] = []
        keys.reserveCapacity(paths.count)
        for path in paths {
            let recorded: Date? = (mode == .recorded) ? await loadRecordedDate(path: path) : nil
            let mtime = (mode == .recorded || mode == .mtime) ? mtimeForPath(path) : nil
            let name = (path as NSString).lastPathComponent
            keys.append(SortKey(path: path, recorded: recorded, mtime: mtime, name: name))
        }

        keys.sort { lhs, rhs in
            switch mode {
            case .name:
                return lhs.name.compare(rhs.name, options: .numeric) == .orderedAscending
            case .mtime:
                if let l = lhs.mtime, let r = rhs.mtime, l != r {
                    return l < r
                }
                if (lhs.mtime == nil) != (rhs.mtime == nil) {
                    return lhs.mtime != nil
                }
                return lhs.name.compare(rhs.name, options: .numeric) == .orderedAscending
            case .recorded:
                if let l = lhs.recorded, let r = rhs.recorded, l != r {
                    return l < r
                }
                if (lhs.recorded == nil) != (rhs.recorded == nil) {
                    return lhs.recorded != nil
                }
                if let l = lhs.mtime, let r = rhs.mtime, l != r {
                    return l < r
                }
                return lhs.name.compare(rhs.name, options: .numeric) == .orderedAscending
            }
        }

        return keys.map(\.path)
    }

    /// Reads the embedded creation timestamp from an M4A/MP4 (or other
    /// AVFoundation-supported) container. Returns nil when the file has no
    /// such metadata or AVFoundation rejects the file.
    private static func loadRecordedDate(path: String) async -> Date? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        do {
            guard let item = try await asset.load(.creationDate) else { return nil }
            return try await item.load(.dateValue)
        } catch {
            return nil
        }
    }

    private static func mtimeForPath(_ path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}
