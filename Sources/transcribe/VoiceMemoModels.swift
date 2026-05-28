import Foundation

enum VoiceMemoTitleSource: String, Codable, Equatable {
    case customLabel = "custom_label"
    case sortingLabel = "sorting_label"
    case encryptedTitle = "encrypted_title"
    case fallback
}

struct VoiceMemoEnhancements: Codable, Equatable {
    let audioFutureFlags: Int?
    let sharedFlags: Int?
    let silenceRemoverEnabled: Bool?
    let skipSilenceEnabled: Bool?
    let studioMixEnabled: Bool?
    let studioMixLevel: Double?

    var isEmpty: Bool {
        audioFutureFlags == nil
            && sharedFlags == nil
            && silenceRemoverEnabled == nil
            && skipSilenceEnabled == nil
            && studioMixEnabled == nil
            && studioMixLevel == nil
    }

    private enum CodingKeys: String, CodingKey {
        case audioFutureFlags = "audio_future_flags"
        case sharedFlags = "shared_flags"
        case silenceRemoverEnabled = "silence_remover_enabled"
        case skipSilenceEnabled = "skip_silence_enabled"
        case studioMixEnabled = "studio_mix_enabled"
        case studioMixLevel = "studio_mix_level"
    }
}

struct VoiceMemoRecording: Equatable {
    let primaryKey: Int
    let uniqueID: String?
    let path: String
    let recordedAt: Date
    let durationSeconds: Double?
    let title: String
    let audioDigestHex: String?
    let flags: Int?
    let folderID: Int?
    let titleSource: VoiceMemoTitleSource
    let titleForSorting: String?
    let enhancements: VoiceMemoEnhancements?

    init(
        primaryKey: Int,
        uniqueID: String?,
        path: String,
        recordedAt: Date,
        durationSeconds: Double?,
        title: String,
        audioDigestHex: String?,
        flags: Int?,
        folderID: Int?,
        titleSource: VoiceMemoTitleSource = .fallback,
        titleForSorting: String? = nil,
        enhancements: VoiceMemoEnhancements? = nil
    ) {
        self.primaryKey = primaryKey
        self.uniqueID = uniqueID
        self.path = path
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.title = title
        self.audioDigestHex = audioDigestHex
        self.flags = flags
        self.folderID = folderID
        self.titleSource = titleSource
        self.titleForSorting = titleForSorting
        self.enhancements = enhancements
    }

    var sourceID: String {
        if let uniqueID, !uniqueID.isEmpty {
            return "voice_memos:\(uniqueID)"
        }
        return "voice_memos:\(URL(fileURLWithPath: path).standardizedFileURL.path)"
    }

    var hasUserTitle: Bool {
        titleSource != .fallback
    }

    func outputRecording() -> VoiceMemoOutputRecording {
        VoiceMemoOutputRecording(
            title: title,
            titleSource: titleSource,
            titleForSorting: titleForSorting,
            recordedAt: iso8601String(recordedAt),
            durationSeconds: durationSeconds,
            uniqueID: uniqueID,
            path: path,
            folderID: folderID,
            flags: flags,
            audioDigestHex: audioDigestHex,
            enhancements: enhancements
        )
    }
}

struct VoiceMemoOutputRecording: Codable, Equatable {
    let title: String
    let titleSource: VoiceMemoTitleSource
    let titleForSorting: String?
    let recordedAt: String
    let durationSeconds: Double?
    let uniqueID: String?
    let path: String?
    let folderID: Int?
    let flags: Int?
    let audioDigestHex: String?
    let enhancements: VoiceMemoEnhancements?

    private enum CodingKeys: String, CodingKey {
        case title
        case titleSource = "title_source"
        case titleForSorting = "title_for_sorting"
        case recordedAt = "recorded_at"
        case durationSeconds = "duration_seconds"
        case uniqueID = "unique_id"
        case path
        case folderID = "folder_id"
        case flags
        case audioDigestHex = "audio_digest"
        case enhancements
    }
}

struct VoiceMemosOutputMetadata: Codable, Equatable {
    let sessionTitle: String
    let recordingCount: Int
    let recordings: [VoiceMemoOutputRecording]

    private enum CodingKeys: String, CodingKey {
        case sessionTitle = "session_title"
        case recordingCount = "recording_count"
        case recordings
    }
}
