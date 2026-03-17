import CoreML
import SpeakerKit
import WhisperKit
import XCTest
@testable import transcribe

final class ComputeOptionsTests: XCTestCase {
    func testAutoPrefersGPUWhenAvailable() {
        let options = RuntimeComputeOptions.resolve(
            audioEncoder: .auto,
            textDecoder: .auto,
            segmenter: .auto,
            embedder: .auto
        )

        let whisperDefaults = ModelComputeOptions()
        let expectedWhisper = RuntimeComputeOptions.canPreferGPU ? MLComputeUnits.cpuAndGPU : whisperDefaults.audioEncoderCompute
        let expectedSpeakerSegmenter = RuntimeComputeOptions.canPreferGPU ? MLComputeUnits.cpuAndGPU : ModelInfo.segmenter().computeUnits
        let expectedSpeakerEmbedder = RuntimeComputeOptions.canPreferGPU ? MLComputeUnits.cpuAndGPU : ModelInfo.embedder().computeUnits

        XCTAssertEqual(options.whisperPreferred.audioEncoderCompute.rawValue, expectedWhisper.rawValue)
        XCTAssertEqual(options.whisperPreferred.textDecoderCompute.rawValue, expectedWhisper.rawValue)
        XCTAssertEqual(options.speakerPreferred.segmenter.rawValue, expectedSpeakerSegmenter.rawValue)
        XCTAssertEqual(options.speakerPreferred.embedder.rawValue, expectedSpeakerEmbedder.rawValue)
    }

    func testExplicitComputeDisablesFallbackForThatChoice() {
        let options = RuntimeComputeOptions.resolve(
            audioEncoder: .cpuOnly,
            textDecoder: .cpuOnly,
            segmenter: .cpuOnly,
            embedder: .cpuOnly
        )

        XCTAssertEqual(options.whisperPreferred.audioEncoderCompute.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.whisperPreferred.textDecoderCompute.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertNil(options.whisperFallback)
        XCTAssertEqual(options.speakerPreferred.segmenter.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.speakerPreferred.embedder.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertNil(options.speakerFallback)
    }
}
