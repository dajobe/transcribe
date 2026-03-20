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
        XCTAssertEqual(options.whisperFallback?.melCompute.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.whisperFallback?.audioEncoderCompute.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.whisperFallback?.textDecoderCompute.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.whisperFallback?.prefillCompute.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.speakerPreferred.segmenter.rawValue, ModelInfo.segmenter().computeUnits.rawValue)
        XCTAssertEqual(options.speakerPreferred.embedder.rawValue, ModelInfo.embedder().computeUnits.rawValue)
        XCTAssertEqual(options.speakerFallback?.segmenter.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.speakerFallback?.embedder.rawValue, MLComputeUnits.cpuOnly.rawValue)
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
        XCTAssertEqual(options.whisperFallback?.audioEncoderCompute.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.whisperFallback?.textDecoderCompute.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.whisperFallback?.melCompute.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.whisperFallback?.prefillCompute.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.speakerPreferred.segmenter.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.speakerPreferred.embedder.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertNil(options.speakerFallback)
    }

    func testMixedExplicitAndAutoPreservesExplicitValuesInFallback() {
        let options = RuntimeComputeOptions.resolve(
            audioEncoder: .cpuAndGPU,
            textDecoder: .auto,
            segmenter: .cpuAndGPU,
            embedder: .auto
        )

        XCTAssertEqual(options.whisperFallback?.audioEncoderCompute.rawValue, MLComputeUnits.cpuAndGPU.rawValue)
        XCTAssertEqual(options.whisperFallback?.textDecoderCompute.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(options.speakerFallback?.segmenter.rawValue, MLComputeUnits.cpuAndGPU.rawValue)
        XCTAssertEqual(options.speakerFallback?.embedder.rawValue, MLComputeUnits.cpuOnly.rawValue)
    }
}
