import Foundation

/// Where rewrite requests go.
public enum RewriteBackend: Sendable, Equatable {
    /// The user's own Anthropic API key, sent straight to api.anthropic.com.
    case anthropic(apiKey: String)
    /// A Hushtype Cloud (or self-hosted) proxy that speaks the Anthropic Messages API at
    /// `<baseURL>/v1/messages` and authenticates the user with a bearer token. The proxy holds the
    /// real API key; see `server/` for the reference implementation.
    case proxy(baseURL: URL, token: String)
}

public enum RewriteModel: String, Codable, Sendable, CaseIterable {
    /// Validated default: best accuracy on mixed Chinese/English dictation.
    case sonnet = "claude-sonnet-5-5"
    /// Faster and ~20x cheaper, noticeably weaker cleanup.
    case haiku = "claude-haiku-5-5"
}

public struct RewriteResult: Sendable {
    public enum Outcome: String, Sendable { case ok, retried, fallback, skipped }
    public var text: String
    public var outcome: Outcome
    public var seconds: TimeInterval
    public var inputTokens: Int
    public var cachedTokens: Int
    public var outputTokens: Int
}

public enum RewriteError: Error, LocalizedError, Equatable {
    case notConfigured
    case http(Int, String)
    case refused
    case network(String)

    /// Shown and also matched by the app to pick the right message.
    public static var networkPrefix: String { String(localized: "网络错误") }
    public static var quotaMessage: String { String(localized: "今天的整理额度用完了") }

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "还没有配置 API key")
        case .http(401, _): return String(localized: "API key 无效或已失效")
        case .http(429, let m) where m.contains("daily limit"): return Self.quotaMessage
        case .http(429, _): return String(localized: "请求太频繁，稍后再试")
        case .http(let c, let m): return String(localized: "改写服务出错（\(c)）：\(m)")
        case .refused: return String(localized: "改写服务拒绝了这段内容")
        case .network(let m): return Self.networkPrefix + "：" + m
        }
    }
}

/// Turns raw transcripts into finished text with Claude.
public final class Rewriter: @unchecked Sendable {
    public var backend: RewriteBackend?
    public var model: RewriteModel
    private let session: URLSession

    public init(backend: RewriteBackend?, model: RewriteModel = .sonnet, session: URLSession? = nil) {
        self.backend = backend
        self.model = model
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 600
            cfg.httpMaximumConnectionsPerHost = 4
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Writes the system prompt into the API cache so the first real request after a pause is fast.
    /// Called when recording starts; the user is still talking while it completes.
    public func prewarm(system: String) async {
        _ = try? await send(system: system, user: String(localized: "预热"), maxTokens: 0, effort: "low")
    }

    /// - Parameter guarded: apply the "answered instead of transcribed" guard (dictation mode only;
    ///   a command's output may legitimately be much longer than the instruction).
    /// - Parameters:
    ///   - alternates: the other hypothesis of the same audio, then dictionary terms (for the drift check).
    ///   - retryUser: the request without screen context, used for the retry when the output drifted.
    public func rewrite(system: String, user: String, source: String, guarded: Bool = true,
                        alternates: [String] = [], retryUser: String? = nil) async throws -> RewriteResult {
        let t0 = Date()
        if TextNorm.normalized(source).isEmpty {
            return RewriteResult(text: "", outcome: .skipped, seconds: 0, inputTokens: 0, cachedTokens: 0, outputTokens: 0)
        }
        // Long dictations need room: roughly 1.5 output tokens per input character, capped by the model.
        let budget = min(64_000, max(guarded ? 8192 : 16000, source.count * 3 / 2))
        var r = try await send(system: system, user: user, maxTokens: budget, effort: guarded ? "low" : "medium")
        var outcome = RewriteResult.Outcome.ok
        let drifted = { (t: String) in
            RewriteGuard.drifted(t, sources: [source] + alternates.prefix(1), allowed: Array(alternates.dropFirst()))
        }
        if guarded, RewriteGuard.isBad(r.text, source: source) || drifted(r.text) {
            // Drift usually comes from the screen context, so that retry goes without it.
            let again = drifted(r.text) ? (retryUser ?? user) : user
            let second = try await send(system: system, user: again, maxTokens: budget, effort: "medium")
            outcome = .retried
            r = Response(text: second.text, input: r.input + second.input, cached: r.cached + second.cached,
                         output: r.output + second.output)
            if RewriteGuard.isBad(r.text, source: source) || drifted(r.text) {
                r.text = source
                outcome = .fallback
            }
        }
        return RewriteResult(text: r.text, outcome: outcome, seconds: Date().timeIntervalSince(t0),
                             inputTokens: r.input, cachedTokens: r.cached, outputTokens: r.output)
    }

    struct Response { var text: String; var input: Int; var cached: Int; var output: Int }

    func requestBody(system: String, user: String, maxTokens: Int, effort: String) -> [String: Any] {
        [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            // Sonnet 5.5 turns thinking off with `between_tools`; Haiku 5.5 with `disabled`.
            "thinking": ["type": model == .sonnet ? "between_tools" : "disabled"],
            "output_config": ["effort": effort],
            "messages": [["role": "user", "content": user]],
        ]
    }

    func send(system: String, user: String, maxTokens: Int, effort: String) async throws -> Response {
        guard let backend else { throw RewriteError.notConfigured }
        var req: URLRequest
        switch backend {
        case .anthropic(let key):
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        case .proxy(let base, let token):
            req = URLRequest(url: base.appendingPathComponent("v1/messages"))
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpMethod = "POST"
        // Short dictations should fail fast; a long one may legitimately take a minute or more.
        req.timeoutInterval = max(20, Double(maxTokens) / 150)
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: requestBody(system: system, user: user,
                                                                              maxTokens: maxTokens, effort: effort))
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw RewriteError.network(error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw RewriteError.http(status, msg)
        }
        if json["stop_reason"] as? String == "refusal" { throw RewriteError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = json["usage"] as? [String: Any] ?? [:]
        return Response(text: text, input: usage["input_tokens"] as? Int ?? 0,
                        cached: usage["cache_read_input_tokens"] as? Int ?? 0,
                        output: usage["output_tokens"] as? Int ?? 0)
    }
}
