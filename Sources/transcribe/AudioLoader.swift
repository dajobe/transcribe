import Foundation
import WhisperKit

enum AudioLoaderError: Error {
    case fileNotFound(String)
    case loadFailed(String)
}

enum AudioLoader {
    /// Supported audio formats for error messages (from WhisperKit/AVFoundation).
    static let supportedFormats = "mp3, wav, m4a, flac, aiff, caf"

    /// Loads audio from a file path into 16 kHz mono Float samples.
    /// - Throws: TranscribeError with exitCode .inputFile on failure.
    static func loadAudio(fromPath path: String) throws -> [Float] {
    let expandedPath = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expandedPath) else {
        throw TranscribeError(
            message: "Input file does not exist: \(path)",
            exitCode: .inputFile
        )
    }

    do {
        let audio = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: expandedPath,
            channelMode: .sumChannels(nil)
        )
        return audio
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
}
