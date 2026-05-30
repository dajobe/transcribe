import Foundation
import AudioToolbox
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
    /// Ordered source of truth for audio extensions the CLI treats as loadable
    /// audio formats in directory discovery, fixture smoke tests, and docs.
    ///
    /// Actual decoding support depends on WhisperKit's AVFoundation loading
    /// path for the specific file, codec, and container.
    static let audioFormatExtensions = ["wav", "mp3", "m4a", "flac", "aiff", "caf", "aac"]

    /// File extensions considered audio candidates during directory discovery.
    static let candidateExtensions = Set(audioFormatExtensions)

    /// Human-readable list of candidate audio extensions.
    static let candidateExtensionsDescription = audioFormatExtensions.joined(separator: ", ")

    /// Cheaply validates that a path is an audio container without decoding it.
    ///
    /// WhisperKit's loader can raise uncaught AVFAudio Obj-C exceptions for
    /// some valid AAC/M4A files when it seeks during an early validation pass.
    /// Keep preflight on the container-inspection path and leave full decoding
    /// to the actual transcription load.
    static func validateAudioContainer(fromPath path: String) throws {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw TranscribeError(
                message: "Input file does not exist: \(path)",
                exitCode: .inputFile
            )
        }

        let url = URL(fileURLWithPath: expandedPath)
        var audioFile: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        guard openStatus == noErr, let audioFile else {
            throw TranscribeError(
                message:
                    "Failed to inspect audio container: \(path) (\(describeOSStatus(openStatus))). Candidate extensions: \(candidateExtensionsDescription). Actual support depends on WhisperKit/AVFoundation decoding for this file.",
                exitCode: .inputFile
            )
        }
        defer { AudioFileClose(audioFile) }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyDataFormat,
            &formatSize,
            &format
        )
        guard formatStatus == noErr,
              format.mFormatID != 0,
              format.mSampleRate > 0,
              format.mChannelsPerFrame > 0 else {
            throw TranscribeError(
                message:
                    "Failed to inspect audio format: \(path) (\(describeOSStatus(formatStatus))).",
                exitCode: .inputFile
            )
        }

        var packetCount: UInt64 = 0
        var packetCountSize = UInt32(MemoryLayout<UInt64>.size)
        let packetStatus = AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyAudioDataPacketCount,
            &packetCountSize,
            &packetCount
        )
        if packetStatus == noErr, packetCount == 0 {
            throw TranscribeError(
                message: "Audio file contains no audio packets: \(path)",
                exitCode: .inputFile
            )
        }
    }

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
                message:
                    "Failed to load audio: \(message). Candidate extensions: \(candidateExtensionsDescription). Actual support depends on WhisperKit/AVFoundation decoding for this file.",
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

    private static func describeOSStatus(_ status: OSStatus) -> String {
        guard status != noErr else { return "noErr" }
        let code = UInt32(bitPattern: status)
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
           let text = String(bytes: bytes, encoding: .ascii) {
            return "'\(text)' (\(status))"
        }
        return "\(status)"
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
