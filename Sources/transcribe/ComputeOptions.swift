import ArgumentParser
import CoreML
#if canImport(Metal)
import Metal
#endif
import SpeakerKit
import WhisperKit

enum ComputeUnitsOption: String, CaseIterable, ExpressibleByArgument {
    case auto
    case all
    case cpuOnly
    case cpuAndGPU
    case cpuAndNeuralEngine

    var resolvedValue: MLComputeUnits? {
        switch self {
        case .auto:
            return nil
        case .all:
            return .all
        case .cpuOnly:
            return .cpuOnly
        case .cpuAndGPU:
            return .cpuAndGPU
        case .cpuAndNeuralEngine:
            return .cpuAndNeuralEngine
        }
    }
}

extension MLComputeUnits {
    var displayName: String {
        switch self {
        case .all:
            return "all"
        case .cpuOnly:
            return "cpuOnly"
        case .cpuAndGPU:
            return "cpuAndGPU"
        case .cpuAndNeuralEngine:
            return "cpuAndNeuralEngine"
        @unknown default:
            return "unknown(\(rawValue))"
        }
    }
}

struct RuntimeComputeOptions {
    struct SpeakerComputeOptions {
        let segmenter: MLComputeUnits
        let embedder: MLComputeUnits

        var summary: String {
            "segmenter=\(segmenter.displayName), embedder=\(embedder.displayName), clusterer=\(MLComputeUnits.cpuOnly.displayName)"
        }
    }

    let whisperPreferred: ModelComputeOptions
    let whisperFallback: ModelComputeOptions?
    let speakerPreferred: SpeakerComputeOptions
    let speakerFallback: SpeakerComputeOptions?

    static var canPreferGPU: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif canImport(Metal)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }

    static func resolve(
        audioEncoder: ComputeUnitsOption,
        textDecoder: ComputeUnitsOption,
        segmenter: ComputeUnitsOption,
        embedder: ComputeUnitsOption
    ) -> RuntimeComputeOptions {
        let whisperDefaults = ModelComputeOptions()
        let speakerSegmenterDefault = ModelInfo.segmenter().computeUnits
        let speakerEmbedderDefault = ModelInfo.embedder().computeUnits
        let gpuDefault: MLComputeUnits = canPreferGPU ? .cpuAndGPU : .cpuOnly

        let whisperPreferred = ModelComputeOptions(
            audioEncoderCompute: audioEncoder.resolvedValue ?? (canPreferGPU ? gpuDefault : whisperDefaults.audioEncoderCompute),
            textDecoderCompute: textDecoder.resolvedValue ?? (canPreferGPU ? gpuDefault : whisperDefaults.textDecoderCompute)
        )
        let whisperFallback = ModelComputeOptions(
            audioEncoderCompute: audioEncoder.resolvedValue ?? whisperDefaults.audioEncoderCompute,
            textDecoderCompute: textDecoder.resolvedValue ?? whisperDefaults.textDecoderCompute
        )

        let speakerPreferred = SpeakerComputeOptions(
            segmenter: segmenter.resolvedValue ?? (canPreferGPU ? gpuDefault : speakerSegmenterDefault),
            embedder: embedder.resolvedValue ?? (canPreferGPU ? gpuDefault : speakerEmbedderDefault)
        )
        let speakerFallback = SpeakerComputeOptions(
            segmenter: segmenter.resolvedValue ?? speakerSegmenterDefault,
            embedder: embedder.resolvedValue ?? speakerEmbedderDefault
        )

        return RuntimeComputeOptions(
            whisperPreferred: whisperPreferred,
            whisperFallback: whisperPreferred.sameValues(as: whisperFallback) ? nil : whisperFallback,
            speakerPreferred: speakerPreferred,
            speakerFallback: speakerPreferred.sameValues(as: speakerFallback) ? nil : speakerFallback
        )
    }

    static func whisperSummary(_ whisper: ModelComputeOptions) -> String {
        "mel=\(whisper.melCompute.displayName), encoder=\(whisper.audioEncoderCompute.displayName), decoder=\(whisper.textDecoderCompute.displayName), prefill=\(whisper.prefillCompute.displayName)"
    }
}

private extension ModelComputeOptions {
    func sameValues(as other: ModelComputeOptions) -> Bool {
        melCompute.rawValue == other.melCompute.rawValue &&
            audioEncoderCompute.rawValue == other.audioEncoderCompute.rawValue &&
            textDecoderCompute.rawValue == other.textDecoderCompute.rawValue &&
            prefillCompute.rawValue == other.prefillCompute.rawValue
    }
}

private extension RuntimeComputeOptions.SpeakerComputeOptions {
    func sameValues(as other: RuntimeComputeOptions.SpeakerComputeOptions) -> Bool {
        segmenter.rawValue == other.segmenter.rawValue &&
            embedder.rawValue == other.embedder.rawValue
    }
}
