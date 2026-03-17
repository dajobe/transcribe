import Foundation

/// A single word with timing (for optional word-level output).
public struct WordSegment: Sendable {
    public let word: String
    public let start: Double
    public let end: Double

    public init(word: String, start: Double, end: Double) {
        self.word = word
        self.start = start
        self.end = end
    }
}

/// A transcript segment: speaker (optional), time range, text, optional words.
public struct TranscriptSegment: Sendable {
    public var speaker: String?
    public let start: Double
    public let end: Double
    public let text: String
    public let words: [WordSegment]?

    public init(speaker: String?, start: Double, end: Double, text: String, words: [WordSegment]?) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}
