import Foundation

/// Where rewrite requests go.
public enum RewriteBackend: Sendable, Equatable {
    /// The user's own Anthropic API key, sent straight to api.anthropic.com.
    case anthropic(apiKey: String)
    /// A Hushtype Cloud (or self-hosted) proxy that speaks the Anthropic Messages API at
    /// `<baseURL>/v1/messages` and authenticates the user with a bearer token. The proxy holds the
    /// real API key; see `server/` for the reference implementation.
    case proxy(baseURL: URL, token: String)
    /// A third-party service with an OpenAI-compatible chat-completions API (DeepSeek, GLM, Kimi,
    /// Qwen, Doubao, OpenAI, or any https endpoint the user enters). See `LLMProviders.swift`.
    case openAICompatible(OpenAICompatible)

    /// Short name for logs and the "test connection" result (never includes the key).
    public var label: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .proxy(let u, _): return u.host ?? "proxy"
        case .openAICompatible(let c): return "\(c.vendor.rawValue)/\(c.model)"
        }
    }
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
    /// The request ran out of time (not retried: the user has already waited the whole budget).
    case timeout(String)

    /// Shown and also matched by the app to pick the right message.
    public static var networkPrefix: String { String(localized: "网络错误") }
    public static var quotaMessage: String { String(localized: "今天的整理额度用完了") }

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "还没有配置 API key")
        case .http(401, _), .http(403, _): return String(localized: "API key 无效或已失效")
        case .http(402, _): return String(localized: "整理服务账户余额不足")
        case .http(429, let m) where m.contains("daily limit"): return Self.quotaMessage
        case .http(429, _): return String(localized: "请求太频繁，稍后再试")
        case .http(let c, let m): return String(localized: "改写服务出错（\(c)）：\(m)")
        case .refused: return String(localized: "改写服务拒绝了这段内容")
        case .network(let m), .timeout(let m): return Self.networkPrefix + "：" + m
        }
    }

    /// For the log: the kind of failure, never the message (it may quote content).
    var logLabel: String {
        switch self {
        case .notConfigured: return "not configured"
        case .http(let c, _): return "HTTP \(c)"
        case .refused: return "refused"
        case .network: return "network"
        case .timeout: return "timeout"
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
            // No proxies from the environment, no cookies, no cache: requests carry a key.
            cfg.httpCookieStorage = nil
            cfg.urlCache = nil
            cfg.timeoutIntervalForRequest = 600
            cfg.httpMaximumConnectionsPerHost = 4
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Writes the system prompt into the API cache so the first real request after a pause is fast.
    /// Called when recording starts; the user is still talking while it completes.
    public func prewarm(system: String) async {
        switch backend {
        case .anthropic, .proxy:
            _ = try? await send(system: system, user: "预热", maxTokens: 0, effort: "low")
        case .openAICompatible(let c):
            // No zero-token requests here, and their prefix caches fill on first real use. Just open the
            // TLS connection (a cheap authenticated GET) so the request after release doesn't pay for it.
            var req = URLRequest(url: c.baseURL.appendingPathComponent("models"))
            req.timeoutInterval = 10
            req.setValue("Bearer \(c.apiKey)", forHTTPHeaderField: "Authorization")
            _ = try? await session.data(for: req, delegate: NoRedirects.shared)
        case nil:
            break
        }
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

    /// The HTTP request for one call, for any backend. Internal for tests.
    func makeRequest(system: String, user: String, maxTokens: Int, effort: String) throws -> URLRequest {
        guard let backend else { throw RewriteError.notConfigured }
        var req: URLRequest
        let body: [String: Any]
        switch backend {
        case .anthropic(let key):
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = requestBody(system: system, user: user, maxTokens: maxTokens, effort: effort)
        case .proxy(let base, let token):
            req = URLRequest(url: base.appendingPathComponent("v1/messages"))
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = requestBody(system: system, user: user, maxTokens: maxTokens, effort: effort)
        case .openAICompatible(let c):
            req = URLRequest(url: c.endpoint)
            req.setValue("Bearer \(c.apiKey)", forHTTPHeaderField: "Authorization")
            body = ChatCompletions.body(c, system: system, user: user, maxTokens: maxTokens)
        }
        guard req.url?.scheme == "https" else { throw RewriteError.notConfigured }
        req.httpMethod = "POST"
        // Short dictations should fail fast; a long one may legitimately take a minute or more.
        req.timeoutInterval = max(20, Double(maxTokens) / 150)
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Turns an HTTP response into text and token counts. Internal for tests.
    func parse(data: Data, status: Int) throws -> Response {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let openAI: Bool
        if case .openAICompatible = backend { openAI = true } else { openAI = false }
        guard status == 200 else {
            let msg = (openAI ? ChatCompletions.errorMessage(json) : ((json["error"] as? [String: Any])?["message"] as? String))
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw RewriteError.http(status, scrub(msg))
        }
        if openAI {
            do {
                let p = try ChatCompletions.parse(json)
                return Response(text: p.text, input: p.input, cached: p.cached, output: p.output)
            } catch ChatCompletions.ParseError.refused {
                throw RewriteError.refused
            } catch ChatCompletions.ParseError.malformed(let m) {
                throw RewriteError.http(status, scrub(m))
            }
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

    /// Error messages are shown in the UI and written to the log; some services echo the key (or a
    /// prefix of it) back in "invalid key" errors. Keep them short and key-free.
    func scrub(_ m: String) -> String {
        var t = m
        let secret: String?
        switch backend {
        case .anthropic(let k): secret = k
        case .proxy(_, let k): secret = k
        case .openAICompatible(let c): secret = c.apiKey
        case nil: secret = nil
        }
        if let k = secret, k.count >= 8 {
            t = t.replacingOccurrences(of: k, with: "[已隐去]")
            t = t.replacingOccurrences(of: String(k.prefix(12)), with: "[已隐去]")
        }
        return String(Untrusted.redactSecrets(t).prefix(200))
    }

    /// Pause before the single retry of a transient failure.
    var retryDelay: TimeInterval = 0.6

    func send(system: String, user: String, maxTokens: Int, effort: String) async throws -> Response {
        let req = try makeRequest(system: system, user: user, maxTokens: maxTokens, effort: effort)
        var attempt = 0
        while true {
            attempt += 1
            do {
                let data: Data
                let resp: URLResponse
                do {
                    (data, resp) = try await session.data(for: req, delegate: NoRedirects.shared)
                } catch {
                    if (error as? URLError)?.code == .cancelled || Task.isCancelled { throw CancellationError() }
                    if (error as? URLError)?.code == .timedOut { throw RewriteError.timeout(error.localizedDescription) }
                    throw RewriteError.network(error.localizedDescription)
                }
                return try parse(data: data, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
            } catch let e as RewriteError where attempt == 1 && Self.isTransient(e) && !Task.isCancelled {
                // One quick retry: a dropped connection (Wi-Fi roaming, the Mac waking up) or an
                // overloaded server usually succeeds a moment later, and is much better than inserting
                // the uncleaned transcript.
                Log.info("rewrite: transient failure (\(e.logLabel)), retrying once")
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1e9))
            }
        }
    }

    /// Worth one retry: network drops, server errors, overload. Not: bad key, quota, refusals, timeouts
    /// (a timeout already used the whole budget the user is waiting on).
    static func isTransient(_ e: RewriteError) -> Bool {
        switch e {
        case .network: return true
        case .timeout: return false
        case .http(let c, let m): return c >= 500 || c == 408 || (c == 429 && !m.contains("daily limit"))
        case .notConfigured, .refused: return false
        }
    }
}

/// Requests carry an API key: never follow a redirect (it could point at another host, or at http).
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
