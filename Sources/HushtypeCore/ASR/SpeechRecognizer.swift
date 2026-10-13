import Foundation

/// One recognition hypothesis for an utterance.
public struct Transcript: Sendable, Equatable {
    public var text: String
    public var language: String?
    /// Name of the engine that produced it, e.g. "sensevoice" or "whisper".
    public var engine: String
    public var seconds: TimeInterval

    public init(text: String, language: String? = nil, engine: String, seconds: TimeInterval = 0) {
        self.text = text
        self.language = language
        self.engine = engine
        self.seconds = seconds
    }
}

/// Converts 16 kHz mono float samples into text. Implementations must be safe to call from a
/// background queue; callers serialize calls per instance.
public protocol SpeechRecognizer: AnyObject, Sendable {
    var engine: String { get }
    func transcribe(_ samples: [Float], sampleRate: Int) throws -> Transcript
}

public enum ASRError: Error, LocalizedError {
    case modelMissing(String)
    case initFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let p): return String(localized: "语音模型文件缺失：\(p)")
        case .initFailed(let m): return String(localized: "语音识别引擎初始化失败：\(m)")
        }
    }
}
