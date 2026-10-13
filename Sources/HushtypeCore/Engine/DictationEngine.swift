import Darwin
import Foundation

/// Settings snapshot the engine needs for one utterance.
public struct EngineOptions: Sendable {
    public var script: ChineseScript = .simplified
    public var dictionary: [String] = []
    /// Run Whisper next to SenseVoice and let the rewrite reconcile both (more accurate on English
    /// terms; costs ~300 MB RAM and ~0.4 s).
    public var useSecondEngine: Bool = true
    /// Skip the LLM and insert the SenseVoice text as is (offline / privacy mode).
    public var rewriteEnabled: Bool = true
    /// Treat the utterance as an instruction for the selected text (voice command mode).
    public var command: Bool = false
    /// The user's recent edits, rendered for the prompt (see CorrectionMemory).
    public var corrections: String?
    public init() {}
}

public struct DictationOutput: Sendable {
    public var text: String
    public var primary: Transcript
    public var secondary: Transcript?
    public var rewrite: RewriteResult?
    /// Set when the rewrite failed and the raw transcript was used instead.
    public var rewriteError: String?
    public var totalSeconds: TimeInterval
}

/// Audio in, finished text out. Stateless apart from the rewriter; recognizers are passed per call
/// so the app can load and unload them independently (see `EngineHost`).
public final class DictationEngine: @unchecked Sendable {
    public let rewriter: Rewriter

    public init(rewriter: Rewriter) {
        self.rewriter = rewriter
    }

    public func systemPrompt(_ o: EngineOptions, twoHypotheses: Bool) -> String {
        RewritePrompt.system(script: o.script, dictionary: o.dictionary, twoHypotheses: twoHypotheses,
                             corrections: o.corrections)
    }

    public func process(_ samples: [Float], primary: SenseVoiceRecognizer, secondary: WhisperKitRecognizer?,
                        context: DictationContext?, options o: EngineOptions) async -> DictationOutput {
        let t0 = Date()
        let b = o.useSecondEngine && o.rewriteEnabled ? secondary : nil
        async let pa: Transcript = Task.detached(priority: .userInitiated) {
            (try? primary.transcribe(samples, sampleRate: 16000)) ?? Transcript(text: "", engine: primary.engine)
        }.value
        async let pb: Transcript? = b == nil ? nil : (try? await b!.transcribe(samples))
        let (ta, tb) = await (pa, pb)
        var out = await finish(primary: ta, secondary: tb, context: context, options: o)
        out.totalSeconds = Date().timeIntervalSince(t0)
        return out
    }

    /// Rewrite step on transcripts that were produced elsewhere (e.g. by the helper process).
    public func finish(primary ta: Transcript, secondary tb: Transcript?, context: DictationContext?,
                       options o: EngineOptions) async -> DictationOutput {
        let t0 = Date()
        let tb = o.useSecondEngine && o.rewriteEnabled ? tb : nil
        var out = DictationOutput(text: Self.cleanRaw(ta.text), primary: ta, secondary: tb, rewrite: nil,
                                  rewriteError: nil, totalSeconds: 0)
        // Nothing heard by the primary engine: Whisper output here is a silence hallucination.
        guard o.rewriteEnabled, !TextNorm.normalized(ta.text).isEmpty else {
            out.totalSeconds = Date().timeIntervalSince(t0)
            return out
        }
        // Long dictation: clean up in sentence-aligned chunks, in parallel. Keeps each request small
        // (fast, inside every output and proxy limit) and a failure only falls back for one chunk.
        if !o.command, ta.text.count > Self.chunkThreshold {
            let chunks = Self.chunks(of: ta.text, target: Self.chunkSize)
            let system = systemPrompt(o, twoHypotheses: false)
            let results = await withTaskGroup(of: (Int, RewriteResult?).self) { g in
                var next = 0, running = 0
                var collected: [(Int, RewriteResult?)] = []
                func add(_ i: Int) {
                    let piece = chunks[i]
                    // Screen context only helps the first chunk (it's about where the text starts).
                    let user = RewritePrompt.user(primary: piece, secondary: nil, context: i == 0 ? context : nil,
                                                  hints: PhoneticHints.match(transcript: piece, dictionary: o.dictionary))
                    g.addTask { [rewriter] in (i, try? await rewriter.rewrite(system: system, user: user, source: piece)) }
                }
                while next < chunks.count && running < Self.chunkParallelism { add(next); next += 1; running += 1 }
                while let r = await g.next() {
                    collected.append(r)
                    if next < chunks.count { add(next); next += 1 }
                }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            let texts = zip(chunks, results).map { piece, r in r?.text ?? Self.cleanRaw(piece) }
            out.text = texts.joined(separator: "\n\n")
            if results.contains(where: { $0 == nil }) { out.rewriteError = String(localized: "部分内容整理失败，已用原文代替") }
            let ok = results.compactMap { $0 }
            out.rewrite = RewriteResult(text: out.text, outcome: ok.count == results.count ? .ok : .fallback,
                                        seconds: Date().timeIntervalSince(t0),
                                        inputTokens: ok.reduce(0) { $0 + $1.inputTokens },
                                        cachedTokens: ok.reduce(0) { $0 + $1.cachedTokens },
                                        outputTokens: ok.reduce(0) { $0 + $1.outputTokens })
            out.totalSeconds = Date().timeIntervalSince(t0)
            return out
        }
        let system = o.command ? CommandPrompt.system(script: o.script) : systemPrompt(o, twoHypotheses: tb != nil)
        let user = o.command
            ? CommandPrompt.user(instruction: ta.text, secondary: tb?.text, context: context ?? DictationContext())
            : RewritePrompt.user(primary: ta.text, secondary: tb?.text, context: context,
                                 hints: PhoneticHints.match(transcript: ta.text + " " + (tb?.text ?? ""), dictionary: o.dictionary))
        do {
            let retryUser = o.command ? nil : RewritePrompt.user(primary: ta.text, secondary: tb?.text, context: nil,
                hints: PhoneticHints.match(transcript: ta.text + " " + (tb?.text ?? ""), dictionary: o.dictionary))
            let r = try await rewriter.rewrite(system: system, user: user, source: ta.text, guarded: !o.command,
                                               alternates: [tb?.text ?? ""] + o.dictionary, retryUser: retryUser)
            out.rewrite = r
            out.text = r.text
        } catch {
            out.rewriteError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        out.totalSeconds = Date().timeIntervalSince(t0)
        return out
    }

    /// Above this many characters (≈ 8–10 minutes of speech) the transcript is cleaned up in chunks.
    static let chunkThreshold = 2400
    static let chunkSize = 1800
    static let chunkParallelism = 4

    /// Splits at sentence ends (。！？.!? and line breaks) into pieces of roughly `target` characters.
    public static func chunks(of text: String, target: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if cur.count >= target, "。！？!?.\n".contains(ch) {
                out.append(cur.trimmingCharacters(in: .whitespacesAndNewlines))
                cur = ""
            } else if cur.count >= target * 2 {
                // No sentence end in sight (unpunctuated speech): cut at a comma or space if possible.
                if let i = cur.lastIndex(where: { "，,、 ".contains($0) }) {
                    out.append(String(cur[...i]).trimmingCharacters(in: .whitespacesAndNewlines))
                    cur = String(cur[cur.index(after: i)...])
                } else {
                    out.append(cur); cur = ""
                }
            }
        }
        let rest = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty {
            // A short tail joins the previous piece rather than being cleaned up on its own.
            if rest.count < target / 3, let last = out.popLast() { out.append(last + rest) } else { out.append(rest) }
        }
        return out.filter { !$0.isEmpty }
    }

    /// Minimal cleanup used when no rewrite runs: drop SenseVoice tags and stray leading dots.
    static func cleanRaw(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        while t.hasPrefix(".") || t.hasPrefix("。") { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Owns the recognizers and keeps memory low: models load on demand (starting the moment the user
/// presses the hotkey, overlapping with speech) and are released after a period of inactivity.
public actor EngineHost {
    public enum Slot: Sendable { case sense, whisper }

    private let models: ModelManager
    private var sense: Task<SenseVoiceRecognizer?, Never>?
    private var whisper: Task<WhisperKitRecognizer?, Never>?
    private var lastUse = Date()
    public private(set) var lastError: String?

    public init(models: ModelManager) {
        self.models = models
    }

    public var isSenseLoaded: Bool { sense != nil }
    public var isWhisperLoaded: Bool { whisper != nil }

    /// Starts loading whatever is installed and wanted. Returns immediately.
    public func warmUp(whisper wantWhisper: Bool) {
        lastUse = Date()
        if sense == nil, models.hasSenseVoice {
            let m = models
            sense = Task.detached(priority: .userInitiated) {
                try? SenseVoiceRecognizer(modelDir: m.senseVoiceDir, vadModel: m.vadModel, threads: 2)
            }
        }
        if wantWhisper, whisper == nil, models.hasWhisper {
            let dir = models.whisperDir
            whisper = Task.detached(priority: .userInitiated) { try? await WhisperKitRecognizer(modelFolder: dir) }
        }
    }

    /// Waits for SenseVoice (required); waits at most `whisperGrace` seconds for Whisper so a cold
    /// Whisper load never delays the result much — the utterance just runs single-engine.
    public func recognizers(whisper wantWhisper: Bool, whisperGrace: TimeInterval = 1.0)
        async -> (SenseVoiceRecognizer?, WhisperKitRecognizer?) {
        warmUp(whisper: wantWhisper)
        lastUse = Date()
        let a = await sense?.value
        if a == nil { sense = nil; lastError = String(localized: "语音模型加载失败") }
        guard wantWhisper, let w = whisper else { return (a, nil) }
        let b = await Self.value(of: w, within: whisperGrace)
        return (a, b)
    }

    private static func value(of task: Task<WhisperKitRecognizer?, Never>, within seconds: TimeInterval) async
        -> WhisperKitRecognizer? {
        await Race.value(of: task, within: seconds)
    }

    public func touch() { lastUse = Date() }

    /// Non-blocking: which models have finished loading.
    public func readiness() async -> (sense: Bool, whisper: Bool) {
        let a = sense == nil ? nil : await Race.value(of: sense!, within: 0.01)
        let b = whisper == nil ? nil : await Race.value(of: whisper!, within: 0.01)
        return (a != nil, b != nil)
    }

    /// Releases models not used for `idle` seconds. Returns true if anything was freed.
    @discardableResult
    public func unloadIfIdle(_ idle: TimeInterval) async -> Bool {
        guard Date().timeIntervalSince(lastUse) >= idle else { return false }
        return await unloadAll()
    }

    @discardableResult
    public func unloadAll() async -> Bool {
        defer { Self.returnFreedMemoryToSystem() }
        var freed = false
        if let w = whisper {
            whisper = nil
            if let r = await w.value { await r.unload() }
            freed = true
        }
        if sense != nil {
            sense = nil
            freed = true
        }
        return freed
    }

    /// malloc keeps freed model buffers (hundreds of MB) cached in the process; hand them back so
    /// the release actually lowers Hushtype's memory footprint.
    static func returnFreedMemoryToSystem() {
        malloc_zone_pressure_relief(nil, 0)
        // Model teardown finishes on other threads (Core ML, ONNX Runtime); relieve again shortly after.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { malloc_zone_pressure_relief(nil, 0) }
    }

    public func unloadWhisper() async {
        defer { Self.returnFreedMemoryToSystem() }
        guard let w = whisper else { return }
        whisper = nil
        if let r = await w.value { await r.unload() }
    }
}

public enum Race {
    /// Returns the task's value if it is ready within `seconds`, otherwise nil — without waiting
    /// for the task to finish (a task group would block until every child completes, which once
    /// stalled a dictation for a full minute while Whisper compiled).
    public static func value<T: Sendable>(of task: Task<T?, Never>, within seconds: TimeInterval) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            Task {
                let v = await task.value
                if once.claim() { cont.resume(returning: v) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }
}

/// Thread-safe one-shot flag.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
