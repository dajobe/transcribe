import Foundation

/// The result of inspecting the positional `audioFile` argument: either a
/// single audio file or a directory of sequential audio clips to be
/// concatenated and transcribed as one logical recording.
enum ResolvedInput: Equatable {
    case file(path: String)
    case directory(path: String, files: [String])
}

enum InputResolver {
    /// Resolves a user-supplied path into a single-file or directory input.
    /// - Throws: `TranscribeError(.inputFile, ...)` for missing paths,
    ///   non-readable directories, or directories with no supported audio files.
    static func resolve(_ rawArg: String) throws -> ResolvedInput {
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

        let audioFiles = entries
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
            .sorted { a, b in
                a.compare(b, options: .numeric) == .orderedAscending
            }
            .map { (expanded as NSString).appendingPathComponent($0) }

        if audioFiles.isEmpty {
            throw TranscribeError(
                message:
                    "No audio files found in directory: \(rawArg). Supported formats: \(AudioLoader.supportedFormats).",
                exitCode: .inputFile
            )
        }

        return .directory(path: expanded, files: audioFiles)
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
}
