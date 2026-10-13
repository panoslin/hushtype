import CoreML
import Foundation
import WhisperKit

/// Whisper large-v3-turbo on the Neural Engine via WhisperKit (Core ML). Uses ~300 MB resident and
/// decodes a short utterance in ~0.4 s on Apple silicon. The first load after install specializes
/// the model for this Mac (one-time, ~2 min); later loads take ~2 s.
///
/// Runs on CPU + Neural Engine only — never the GPU — so dictation does not compete with games,
/// video or other GPU work.
public final class WhisperKitRecognizer: @unchecked Sendable {
    public let engine = "whisper"
    private let pipe: WhisperKit
    private let options = DecodingOptions(task: .transcribe, language: nil, temperature: 0,
                                          usePrefillPrompt: true, detectLanguage: true,
                                          skipSpecialTokens: true, withoutTimestamps: true,
                                          chunkingStrategy: .vad)

    public static let computeOptions = ModelComputeOptions(melCompute: .cpuOnly,
                                                           audioEncoderCompute: .cpuAndNeuralEngine,
                                                           textDecoderCompute: .cpuAndNeuralEngine)

    public init(modelFolder: URL) async throws {
        let cfg = WhisperKitConfig(modelFolder: modelFolder.path, tokenizerFolder: modelFolder,
                                   computeOptions: Self.computeOptions, verbose: false, logLevel: .error,
                                   prewarm: true, load: true, download: false)
        pipe = try await WhisperKit(cfg)
    }

    public func transcribe(_ samples: [Float]) async throws -> Transcript {
        let t0 = Date()
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text, language: results.first?.language, engine: engine,
                          seconds: Date().timeIntervalSince(t0))
    }

    /// Frees the Core ML models. The object must not be used afterwards.
    public func unload() async {
        await pipe.unloadModels()
    }
}
