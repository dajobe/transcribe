import Foundation
import WhisperKit

enum AudioLoaderError: Error {
    case fileNotFound(String)
    case loadFailed(String)
}

struct AudioLoadLimits: Equatable {
    /// Maximum decoded audio size in megabytes. `0` disables the hard cap.
    let maxAudioMB: Int

    static let `default` = AudioLoadLimits(maxAudioMB: TranscriptionDefaults.maxAudioMB)
    static let warnFileSizeBytes = 500 * 1024 * 1024

    var maxUncompressedBytes: Int? {
        guard maxAudioMB > 0 else { return nil }
        return maxAudioMB * 1024 * 1024
    }
}

enum AudioLoader {
    /// Supported audio file extensions (lowercase, without leading dot).
    static let supportedExtensions: Set<String> = ["mp3", "wav", "m4a", "flac", "aiff", "caf"]

    /// Supported audio formats for error messages (from WhisperKit/AVFoundation).
    static let supportedFormats = "mp3, wav, m4a, flac, aiff, caf"

    static func uncompressedByteCount(forSampleCount count: Int) -> Int {
        count * MemoryLayout<Float>.size
    }

    /// Loads audio from a file path into 16 kHz mono Float samples.
    /// - Throws: TranscribeError with exitCode .inputFile on failure.
    static func loadAudio(
        fromPath path: String,
        limits: AudioLoadLimits = .default
    ) throws -> [Float] {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw TranscribeError(
                message: "Input file does not exist: \(path)",
                exitCode: .inputFile
            )
        }

        try warnIfLargeFile(at: expandedPath)

        do {
            let audio = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: expandedPath,
                channelMode: .sumChannels(nil)
            )
            try enforceUncompressedLimit(sampleCount: audio.count, path: expandedPath, limits: limits)
            return audio
        } catch let error as TranscribeError {
            throw error
        } catch {
            let message: String
            if let whisperError = error as? WhisperError {
                message = String(describing: whisperError)
            } else {
                message = error.localizedDescription
            }
            throw TranscribeError(
                message: "Failed to load audio: \(message). Supported formats: \(supportedFormats).",
                exitCode: .inputFile
            )
        }
    }

    private static func warnIfLargeFile(at path: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > Int64(AudioLoadLimits.warnFileSizeBytes) else { return }
        let mb = Double(bytes) / (1024 * 1024)
        emitWarning(
            String(format: "Large input file (%.0f MB on disk): %@. Decoding may use substantial memory.", mb, path)
        )
    }

    private static func enforceUncompressedLimit(
        sampleCount: Int,
        path: String,
        limits: AudioLoadLimits
    ) throws {
        guard let maxBytes = limits.maxUncompressedBytes else { return }
        let bytes = uncompressedByteCount(forSampleCount: sampleCount)
        guard bytes > maxBytes else { return }
        let actualMB = Double(bytes) / (1024 * 1024)
        throw TranscribeError(
            message: String(
                format: "Decoded audio exceeds --max-audio-mb limit (%d MB): %.0f MB for %@. Use --max-audio-mb 0 to disable.",
                limits.maxAudioMB,
                actualMB,
                path
            ),
            exitCode: .inputFile
        )
    }
}
