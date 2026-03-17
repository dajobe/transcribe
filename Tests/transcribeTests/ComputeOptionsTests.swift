import CoreML
import SpeakerKit
import WhisperKit
import XCTest
@testable import transcribe

final class ComputeOptionsTests: XCTestCase {
    func testAutoUsesRecommendedBackendMix() {
        let options = RuntimeComputeOptions.resolve(
            audioEncoder: .auto,
            textDecoder: .auto,
            segmenter: .auto,
            embedder: .auto
        )

        let whisperDefaults = ModelComputeOptions()
        XCTAssertEqual(options.whisperPreferred.audioEncoderCompute.rawValue, whisperDefaults.audioEncoderCompute.rawValue)
        XCTAssertEqual(options.whisperPreferred.textDecoderCompute.rawValue, whisperDefaults.textDecoderCompute.rawValue)
        XCTAssertNil(options.whisperFallback)
        XCTAssertEqual(options.speakerPreferred.segmenter.rawValue, ModelInfo.segmenter().computeUnits.rawValue)
        XCTAssertEqual(options.speakerPreferred.embedder.rawValue, ModelInfo.embedder().computeUnits.rawValue)
        XCTAssertNil(options.speakerFallback)
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
