import Foundation
import XCTest
@testable import transcribe

final class AudioLoaderTests: XCTestCase {
    func testUncompressedByteCountUsesFloatSize() {
        XCTAssertEqual(AudioLoader.uncompressedByteCount(forSampleCount: 1000), 4000)
    }

    func testAudioLoadLimitsDefaultMatchesTranscriptionDefaults() {
        XCTAssertEqual(AudioLoadLimits.default.maxAudioMB, TranscriptionDefaults.maxAudioMB)
    }

    func testMaxUncompressedBytesDisabledWhenZero() {
        let limits = AudioLoadLimits(maxAudioMB: 0)
        XCTAssertNil(limits.maxUncompressedBytes)
    }

    func testMaxUncompressedBytesScalesMegabytes() {
        let limits = AudioLoadLimits(maxAudioMB: 2)
        XCTAssertEqual(limits.maxUncompressedBytes, 2 * 1024 * 1024)
    }
}
