import CSherpaOnnx
import Foundation

/// Owns C strings for the lifetime of a sherpa-onnx config struct.
private final class CStrings {
    private var ptrs: [UnsafeMutablePointer<CChar>] = []
    func make(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        ptrs.append(p)
        return UnsafePointer(p)
    }
    deinit { ptrs.forEach { free($0) } }
}

/// SenseVoice (zh/en/ja/ko/yue) via sherpa-onnx. Long recordings are split with Silero VAD,
/// because SenseVoice is trained on short segments and degrades past ~30 s.
public final class SenseVoiceRecognizer: SpeechRecognizer, @unchecked Sendable {
    public let engine = "sensevoice"
    private let recognizer: OpaquePointer
    private let vadModelPath: String?
    private let lock = NSLock()

    /// - Parameters:
    ///   - modelDir: directory with `model.int8.onnx` and `tokens.txt`.
    ///   - vadModel: path to `silero_vad.onnx`; when nil, audio is decoded in one pass.
    public init(modelDir: URL, vadModel: URL?, threads: Int = 2) throws {
        let model = modelDir.appendingPathComponent("model.int8.onnx").path
        let tokens = modelDir.appendingPathComponent("tokens.txt").path
        for p in [model, tokens] where !FileManager.default.fileExists(atPath: p) {
            throw ASRError.modelMissing(p)
        }
        let s = CStrings()
        var c = SherpaOnnxOfflineRecognizerConfig()
        c.feat_config.sample_rate = 16000
        c.feat_config.feature_dim = 80
        c.model_config.sense_voice.model = s.make(model)
        c.model_config.sense_voice.language = s.make("auto")
        c.model_config.sense_voice.use_itn = 1
        c.model_config.tokens = s.make(tokens)
        c.model_config.num_threads = Int32(threads)
        c.model_config.provider = s.make("cpu")
        c.decoding_method = s.make("greedy_search")
        guard let r = SherpaOnnxCreateOfflineRecognizer(&c) else {
            throw ASRError.initFailed("SenseVoice")
        }
        recognizer = r
        if let v = vadModel, FileManager.default.fileExists(atPath: v.path) {
            vadModelPath = v.path
        } else {
            vadModelPath = nil
        }
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    public func transcribe(_ samples: [Float], sampleRate: Int) throws -> Transcript {
        lock.lock(); defer { lock.unlock() }
        let t0 = Date()
        let segments: [[Float]]
        if let vad = vadModelPath, samples.count > sampleRate * 25 {
            segments = Self.split(samples, sampleRate: sampleRate, vadModel: vad)
        } else {
            segments = [samples]
        }
        var texts: [String] = []
        var lang: String?
        for seg in segments where !seg.isEmpty {
            let (t, l) = decode(seg, sampleRate: sampleRate)
            if !t.isEmpty { texts.append(t) }
            if lang == nil { lang = l }
        }
        return Transcript(text: Self.join(texts), language: lang, engine: engine,
                          seconds: Date().timeIntervalSince(t0))
    }

    private func decode(_ seg: [Float], sampleRate: Int) -> (String, String?) {
        let r = recognizer
        guard let stream = SherpaOnnxCreateOfflineStream(r) else { return ("", nil) }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        seg.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), buf.baseAddress, Int32(buf.count))
        }
        SherpaOnnxDecodeOfflineStream(r, stream)
        guard let res = SherpaOnnxGetOfflineStreamResult(stream) else { return ("", nil) }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(res) }
        let text = res.pointee.text.map { String(cString: $0) } ?? ""
        var lang = res.pointee.lang.map { String(cString: $0) }
        // SenseVoice reports e.g. "<|zh|>"
        lang = lang?.trimmingCharacters(in: CharacterSet(charactersIn: "<|>"))
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), lang?.isEmpty == true ? nil : lang)
    }

    /// Join segment texts: no separator between CJK, a space between Latin words.
    static func join(_ parts: [String]) -> String {
        var out = ""
        for p in parts {
            if let last = out.unicodeScalars.last, let first = p.unicodeScalars.first,
               last.properties.isAlphabetic && last.value < 0x2E80,
               first.properties.isAlphabetic && first.value < 0x2E80 {
                out += " "
            }
            out += p
        }
        return out
    }

    static func split(_ samples: [Float], sampleRate: Int, vadModel: String) -> [[Float]] {
        let s = CStrings()
        var c = SherpaOnnxVadModelConfig()
        c.silero_vad.model = s.make(vadModel)
        c.silero_vad.threshold = 0.5
        c.silero_vad.min_silence_duration = 0.4
        c.silero_vad.min_speech_duration = 0.25
        c.silero_vad.max_speech_duration = 20
        c.silero_vad.window_size = 512
        c.sample_rate = Int32(sampleRate)
        c.num_threads = 1
        c.provider = s.make("cpu")
        guard let vad = SherpaOnnxCreateVoiceActivityDetector(&c, 60) else { return [samples] }
        defer { SherpaOnnxDestroyVoiceActivityDetector(vad) }
        var segments: [[Float]] = []
        func drain() {
            while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                if let seg = SherpaOnnxVoiceActivityDetectorFront(vad) {
                    let n = Int(seg.pointee.n)
                    segments.append(Array(UnsafeBufferPointer(start: seg.pointee.samples, count: n)))
                    SherpaOnnxDestroySpeechSegment(seg)
                }
                SherpaOnnxVoiceActivityDetectorPop(vad)
            }
        }
        samples.withUnsafeBufferPointer { buf in
            var i = 0
            while i < buf.count {
                let n = min(512, buf.count - i)
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buf.baseAddress! + i, Int32(n))
                i += n
                drain()
            }
        }
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        drain()
        return segments.isEmpty ? [samples] : merge(segments, sampleRate: sampleRate)
    }

    /// Merge short adjacent VAD segments up to ~15 s so the model sees enough context.
    static func merge(_ segs: [[Float]], sampleRate: Int) -> [[Float]] {
        let limit = sampleRate * 15
        var out: [[Float]] = []
        var cur: [Float] = []
        for s in segs {
            if !cur.isEmpty && cur.count + s.count > limit {
                out.append(cur); cur = []
            }
            cur += s
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// Whisper (turbo / large-v3) via sherpa-onnx. A second, independent hypothesis that is better at
/// English terms; the rewrite step reconciles it with SenseVoice. Whisper decodes at most 30 s per
/// pass, so audio is VAD-split like SenseVoice.
public final class WhisperRecognizer: SpeechRecognizer, @unchecked Sendable {
    public let engine = "whisper"
    private let recognizer: OpaquePointer
    private let vadModelPath: String?
    private let lock = NSLock()

    public init(modelDir: URL, prefix: String = "turbo", vadModel: URL?, threads: Int = 4) throws {
        let enc = modelDir.appendingPathComponent("\(prefix)-encoder.int8.onnx").path
        let dec = modelDir.appendingPathComponent("\(prefix)-decoder.int8.onnx").path
        let tokens = modelDir.appendingPathComponent("\(prefix)-tokens.txt").path
        for p in [enc, dec, tokens] where !FileManager.default.fileExists(atPath: p) {
            throw ASRError.modelMissing(p)
        }
        let s = CStrings()
        var c = SherpaOnnxOfflineRecognizerConfig()
        c.feat_config.sample_rate = 16000
        c.feat_config.feature_dim = 128
        c.model_config.whisper.encoder = s.make(enc)
        c.model_config.whisper.decoder = s.make(dec)
        c.model_config.whisper.language = s.make("")
        c.model_config.whisper.task = s.make("transcribe")
        c.model_config.whisper.tail_paddings = -1
        c.model_config.tokens = s.make(tokens)
        c.model_config.num_threads = Int32(threads)
        c.model_config.provider = s.make("cpu")
        c.decoding_method = s.make("greedy_search")
        guard let r = SherpaOnnxCreateOfflineRecognizer(&c) else { throw ASRError.initFailed("Whisper") }
        recognizer = r
        vadModelPath = vadModel.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    public func transcribe(_ samples: [Float], sampleRate: Int) throws -> Transcript {
        lock.lock(); defer { lock.unlock() }
        let t0 = Date()
        let segments: [[Float]]
        if let vad = vadModelPath, samples.count > sampleRate * 28 {
            segments = SenseVoiceRecognizer.split(samples, sampleRate: sampleRate, vadModel: vad)
        } else {
            segments = [samples]
        }
        var texts: [String] = []
        var lang: String?
        for seg in segments where !seg.isEmpty {
            guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { continue }
            seg.withUnsafeBufferPointer {
                SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), $0.baseAddress, Int32($0.count))
            }
            SherpaOnnxDecodeOfflineStream(recognizer, stream)
            if let res = SherpaOnnxGetOfflineStreamResult(stream) {
                let t = res.pointee.text.map { String(cString: $0) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !t.isEmpty { texts.append(t) }
                if lang == nil, let l = res.pointee.lang { lang = String(cString: l) }
                SherpaOnnxDestroyOfflineRecognizerResult(res)
            }
            SherpaOnnxDestroyOfflineStream(stream)
        }
        return Transcript(text: SenseVoiceRecognizer.join(texts), language: lang, engine: engine,
                          seconds: Date().timeIntervalSince(t0))
    }
}
