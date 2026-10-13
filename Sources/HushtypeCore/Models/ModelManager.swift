import CryptoKit
import Foundation

/// Downloads and verifies the on-device speech models. Models are fetched from their upstream
/// publishers (k2-fsa/sherpa-onnx GitHub releases, argmaxinc/whisperkit-coreml on Hugging Face) and
/// checked against pinned SHA-256 digests before use.
public final class ModelManager: @unchecked Sendable {
    public struct Progress: Sendable {
        public var fraction: Double
        public var message: String
    }

    public let root: URL
    private let session: URLSession

    public init(root: URL = ModelManager.defaultRoot) {
        self.root = root
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg)
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushtype/Models", isDirectory: true)
    }

    public var senseVoiceDir: URL { root.appendingPathComponent("sense-voice") }
    public var vadModel: URL { root.appendingPathComponent("silero_vad.onnx") }
    public var whisperDir: URL { root.appendingPathComponent("whisperkit/\(Self.whisperVariant)") }

    static let sherpa = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
    static let senseVoiceArchive = (url: "\(sherpa)/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2",
                                    sha256: "7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e",
                                    folder: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
                                    bytes: 162_000_000)
    static let vad = (url: "\(sherpa)/silero_vad.onnx",
                      sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6")
    public static let whisperVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let whisperRepo = "argmaxinc/whisperkit-coreml"
    /// Pinned Hugging Face revision of the WhisperKit model repo.
    static let whisperRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
    static let tokenizerRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"
    static let whisperTokenizer = [
        ("tokenizer.json", "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
        ("tokenizer_config.json", "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
    ]

    public var hasSenseVoice: Bool {
        FileManager.default.fileExists(atPath: senseVoiceDir.appendingPathComponent("model.int8.onnx").path)
            && FileManager.default.fileExists(atPath: vadModel.path)
    }

    public var hasWhisper: Bool {
        FileManager.default.fileExists(atPath: whisperDir.appendingPathComponent(".complete").path)
    }

    /// Bytes on disk used by downloaded models.
    public func diskUsage() -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: SenseVoice + VAD

    public func installSenseVoice(progress: @escaping @Sendable (Progress) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: vadModel.path) {
            let tmp = try await download(URL(string: Self.vad.url)!, expectedSHA256: Self.vad.sha256) { _ in }
            try replace(vadModel, with: tmp)
        }
        guard !hasSenseVoice else { return }
        let tmp = try await download(URL(string: Self.senseVoiceArchive.url)!,
                                     expectedSHA256: Self.senseVoiceArchive.sha256) { f in
            progress(Progress(fraction: f * 0.95, message: String(localized: "下载中文/英文语音模型")))
        }
        progress(Progress(fraction: 0.96, message: String(localized: "解压模型")))
        let staging = root.appendingPathComponent(".staging-sv", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-xjf", tmp.path, "-C", staging.path])
        try? FileManager.default.removeItem(at: tmp)
        let extracted = staging.appendingPathComponent(Self.senseVoiceArchive.folder)
        let dst = senseVoiceDir
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        for f in ["model.int8.onnx", "tokens.txt", "LICENSE"] {
            let s = extracted.appendingPathComponent(f)
            if FileManager.default.fileExists(atPath: s.path) {
                try FileManager.default.moveItem(at: s, to: dst.appendingPathComponent(f))
            }
        }
        try? FileManager.default.removeItem(at: staging)
        progress(Progress(fraction: 1, message: String(localized: "完成")))
    }

    // MARK: WhisperKit

    public func installWhisper(progress: @escaping @Sendable (Progress) -> Void) async throws {
        guard !hasWhisper else { return }
        let api = URL(string: "https://huggingface.co/api/models/\(Self.whisperRepo)/tree/\(Self.whisperRevision)/\(Self.whisperVariant)?recursive=true")!
        let (data, resp) = try await session.data(from: api)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ModelError.listing }
        let files = try JSONDecoder().decode([TreeEntry].self, from: data).filter { $0.type == "file" }
        let total = max(1, files.reduce(Int64(0)) { $0 + ($1.lfs?.size ?? $1.size ?? 0) })
        var done: Int64 = 0
        let staging = root.appendingPathComponent(".staging-whisper", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        for f in files {
            let rel = String(f.path.dropFirst(Self.whisperVariant.count + 1))
            let src = URL(string: "https://huggingface.co/\(Self.whisperRepo)/resolve/\(Self.whisperRevision)/\(f.path)")!
            let size = f.lfs?.size ?? f.size ?? 0
            let base = done
            let tmp = try await download(src, expectedSHA256: f.lfs?.oid) { frac in
                progress(Progress(fraction: Double(base + Int64(Double(size) * frac)) / Double(total),
                                  message: String(localized: "下载英文增强模型（Whisper）")))
            }
            let dst = staging.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tmp, to: dst)
            done += size
        }
        // WhisperKit looks for tokenizer.json inside the model folder first; shipping it there keeps
        // WhisperKit from downloading it into ~/Documents (which would trigger a privacy prompt).
        for (name, sha) in Self.whisperTokenizer {
            let src = URL(string: "https://huggingface.co/openai/whisper-large-v3/resolve/\(Self.tokenizerRevision)/\(name)")!
            let tmp = try await download(src, expectedSHA256: sha) { _ in }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tmp, to: staging.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: whisperDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: whisperDir)
        try FileManager.default.moveItem(at: staging, to: whisperDir)
        FileManager.default.createFile(atPath: whisperDir.appendingPathComponent(".complete").path, contents: Data())
        progress(Progress(fraction: 1, message: String(localized: "完成")))
    }

    struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
        struct LFS: Decodable { let oid: String?; let size: Int64? }
    }

    public func removeWhisper() { try? FileManager.default.removeItem(at: whisperDir) }

    // MARK: helpers

    /// Downloads to a temp file, verifying SHA-256 when a digest is given.
    func download(_ url: URL, expectedSHA256: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (bytes, resp) = try await session.bytes(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, url.lastPathComponent)
        }
        let expected = max(1, http.expectedContentLength)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hushtype-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmp)
        var hasher = SHA256()
        var buf = Data()
        buf.reserveCapacity(1 << 20)
        var written: Int64 = 0
        var lastReport = Date.distantPast
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 1 << 20 {
                hasher.update(data: buf); try fh.write(contentsOf: buf)
                written += Int64(buf.count); buf.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.2 {
                    lastReport = Date(); progress(Double(written) / Double(expected))
                }
            }
        }
        hasher.update(data: buf); try fh.write(contentsOf: buf)
        try fh.close()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let exp = expectedSHA256, digest != exp.lowercased() {
            try? FileManager.default.removeItem(at: tmp)
            throw ModelError.checksum(url.lastPathComponent)
        }
        progress(1)
        return tmp
    }

    private func replace(_ dst: URL, with src: URL) throws {
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: src, to: dst)
    }

    private func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ModelError.extract }
    }
}

public enum ModelError: Error, LocalizedError {
    case http(Int, String), checksum(String), extract, listing
    public var errorDescription: String? {
        switch self {
        case .http(let c, let f): return String(localized: "下载 \(f) 失败（HTTP \(c)）")
        case .checksum(let f): return String(localized: "\(f) 校验失败，已删除，请重试")
        case .extract: return String(localized: "解压模型失败")
        case .listing: return String(localized: "获取模型文件列表失败")
        }
    }
}
