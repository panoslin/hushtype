import Foundation

/// Third-party LLM services for the cleanup step. All of them speak the OpenAI chat-completions API
/// (`POST <baseURL>/chat/completions`, bearer key); they differ in endpoints, model ids, how
/// reasoning is switched off, and how they report cached tokens. Anthropic Claude is not in this
/// list: it keeps its own request format (see `Rewriter`), and the Hushtype Cloud proxy is Claude-only.
public enum LLMVendor: String, Codable, Sendable, CaseIterable, Identifiable {
    case deepseek, zhipu, moonshot, qwen, doubao, openai, custom
    public var id: String { rawValue }

    public var preset: LLMPreset { LLMPreset.all[self]! }

    /// Shown in the provider picker (brand names are not translated).
    public var title: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .zhipu: return String(localized: "智谱 GLM")
        case .moonshot: return String(localized: "月之暗面 Kimi")
        case .qwen: return String(localized: "通义千问（阿里云百炼）")
        case .doubao: return String(localized: "豆包（火山方舟）")
        case .openai: return "OpenAI"
        case .custom: return String(localized: "其他 OpenAI 兼容服务")
        }
    }

    /// Keychain account for this vendor's key (each vendor keeps its own, so switching back and
    /// forth doesn't lose a key).
    public var keychainAccount: String { "llm-key.\(rawValue)" }
}

/// How a vendor turns off "thinking" (reasoning tokens before the answer). Cleanup must be fast and
/// must never emit reasoning; every vendor has its own switch.
public enum ThinkingSwitch: Sendable, Equatable {
    /// Nothing to send (the model doesn't reason, or the model id already selects a non-reasoning mode).
    case none
    /// `"thinking": {"type": "disabled"}` (DeepSeek V4, Zhipu GLM-4.5+, Kimi K2.6, Doubao Seed).
    case thinkingTypeDisabled
    /// `"enable_thinking": false` (Qwen3 hybrid models on DashScope compatible mode).
    case enableThinkingFalse
    /// `"reasoning_effort": <value>` (OpenAI: the lowest effort the model accepts).
    case reasoningEffort(String)
}

public struct LLMPreset: Sendable {
    public let vendor: LLMVendor
    /// `<baseURL>/chat/completions` is the endpoint. Empty for `.custom`.
    public let baseURL: String
    /// Other official endpoints (e.g. the international region), offered in a menu.
    public let alternateBaseURLs: [String]
    /// Recommended model ids, default first.
    public let models: [String]
    /// Where to create an API key.
    public let keyPage: String?
    /// Largest `max_tokens` the default models accept; requests are clamped to it.
    public let maxOutputTokens: Int
    /// OpenAI's newer models reject `max_tokens` and want `max_completion_tokens`.
    public let usesMaxCompletionTokens: Bool

    public var defaultModel: String { models.first ?? "" }

    /// How to switch reasoning off for a given model of this vendor. Most current models think by
    /// default (DeepSeek V4, GLM-4.5+, Kimi K2.6, Qwen3.x, Doubao Seed, OpenAI GPT-6), so the switch
    /// has to be sent explicitly.
    public func thinkingSwitch(model: String) -> ThinkingSwitch {
        let m = model.lowercased()
        switch vendor {
        case .deepseek, .zhipu, .moonshot, .doubao:
            return .thinkingTypeDisabled
        case .qwen:
            // `enable_thinking` belongs to the Qwen3-family models (qwen3.x-*, qwen-flash/plus/turbo/max).
            return m.hasPrefix("qwen") ? .enableThinkingFalse : .none
        case .openai:
            // gpt-6-luna accepts "none"; the larger GPT-6 models reject it (400) and keep their default.
            if m.contains("luna") { return .reasoningEffort("none") }
            if m.hasPrefix("gpt-5") { return .reasoningEffort("minimal") }
            return .none
        case .custom:
            return .none
        }
    }

    /// Whether to send a low sampling temperature. OpenAI reasoning models and Kimi (fixed at 0.6
    /// without thinking) reject other values; for unknown endpoints the server default is safest.
    public func acceptsTemperature(model: String) -> Bool {
        switch vendor {
        case .deepseek, .zhipu, .qwen, .doubao: return true
        case .moonshot, .openai, .custom: return false
        }
    }

    public static let all: [LLMVendor: LLMPreset] = {
        var d: [LLMVendor: LLMPreset] = [:]
        for p in list { d[p.vendor] = p }
        return d
    }()

    // Endpoints and model ids from each vendor's official API docs, checked 2026-10-14
    // (see docs/typeless-rea-2026-10.md, appendix "第三方模型服务商").
    static let list: [LLMPreset] = [
        // api-docs.deepseek.com: deepseek-chat / deepseek-reasoner are gone; V4 models think by default.
        LLMPreset(vendor: .deepseek, baseURL: "https://api.deepseek.com", alternateBaseURLs: [],
                  models: ["deepseek-flash", "deepseek-v4-pro"], keyPage: "https://platform.deepseek.com/api_keys",
                  maxOutputTokens: 8192, usesMaxCompletionTokens: false),
        // docs.bigmodel.cn: GLM-4.7 / GLM-5.3 can't turn thinking off, so they're not offered.
        LLMPreset(vendor: .zhipu, baseURL: "https://open.bigmodel.cn/api/paas/v4",
                  alternateBaseURLs: ["https://api.z.ai/api/paas/v4"],
                  models: ["glm-4.5-airx", "glm-4.5-air", "glm-4.5-flash"], keyPage: "https://open.bigmodel.cn/usercenter/apikeys",
                  maxOutputTokens: 8192, usesMaxCompletionTokens: false),
        // platform.kimi.com: kimi-k2.6 is the only current model that runs without thinking.
        LLMPreset(vendor: .moonshot, baseURL: "https://api.moonshot.cn/v1",
                  alternateBaseURLs: ["https://api.moonshot.ai/v1"],
                  models: ["kimi-k2.6"], keyPage: "https://platform.moonshot.cn/console/api-keys",
                  maxOutputTokens: 8192, usesMaxCompletionTokens: true),
        // help.aliyun.com model-studio compatible mode; keys are region-bound (Beijing vs Singapore).
        LLMPreset(vendor: .qwen, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                  alternateBaseURLs: ["https://dashscope-intl.aliyuncs.com/compatible-mode/v1"],
                  models: ["qwen3.8-flash", "qwen3.7-plus", "qwen-flash"], keyPage: "https://bailian.console.aliyun.com/?apiKey=1",
                  maxOutputTokens: 8192, usesMaxCompletionTokens: false),
        // docs.volcengine.com/docs/82379: model ids work directly (an ep-… endpoint id is optional).
        LLMPreset(vendor: .doubao, baseURL: "https://ark.cn-beijing.volces.com/api/v3", alternateBaseURLs: [],
                  models: ["doubao-seed-2-1-lite-260915", "doubao-seed-2-1-turbo-260628", "doubao-seed-2-0-mini-260428"],
                  keyPage: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey",
                  maxOutputTokens: 8192, usesMaxCompletionTokens: false),
        // developers.openai.com: gpt-6-luna is the small fast model; max_tokens is deprecated.
        LLMPreset(vendor: .openai, baseURL: "https://api.openai.com/v1", alternateBaseURLs: [],
                  models: ["gpt-6-luna"], keyPage: "https://platform.openai.com/api-keys",
                  maxOutputTokens: 16384, usesMaxCompletionTokens: true),
        LLMPreset(vendor: .custom, baseURL: "", alternateBaseURLs: [], models: [], keyPage: nil,
                  maxOutputTokens: 8192, usesMaxCompletionTokens: false),
    ]
}

/// A configured OpenAI-compatible endpoint.
public struct OpenAICompatible: Sendable, Equatable {
    public var vendor: LLMVendor
    public var baseURL: URL
    public var apiKey: String
    public var model: String

    public var preset: LLMPreset { vendor.preset }

    /// Validates user input. Only https endpoints with a host are accepted (keys and transcripts never
    /// travel in clear text); a pasted full endpoint (".../chat/completions") is reduced to its base.
    public init?(vendor: LLMVendor, baseURL: String, apiKey: String, model: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let mdl = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !mdl.isEmpty, let url = Self.normalizedBaseURL(baseURL) else { return nil }
        self.vendor = vendor
        self.baseURL = url
        self.apiKey = key
        self.model = mdl
    }

    public static func normalizedBaseURL(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        for suffix in ["/chat/completions", "/completions"] where t.lowercased().hasSuffix(suffix) {
            t.removeLast(suffix.count)
        }
        guard let c = URLComponents(string: t), c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, let url = c.url else { return nil }
        return url
    }

    public var endpoint: URL { baseURL.appendingPathComponent("chat/completions") }
}

/// Request building and response parsing for OpenAI-compatible chat completions. Pure functions,
/// unit-tested per vendor.
public enum ChatCompletions {
    public static func body(_ c: OpenAICompatible, system: String, user: String, maxTokens: Int) -> [String: Any] {
        let p = c.preset
        var b: [String: Any] = [
            "model": c.model,
            // System prompt as a system message; every listed vendor supports the role. It goes first
            // and is byte-stable, so vendors with automatic prefix caching (DeepSeek, OpenAI, Kimi,
            // Qwen implicit cache) reuse it without any extra parameter.
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": false,
        ]
        b[p.usesMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = max(1, min(maxTokens, p.maxOutputTokens))
        // Cleanup should be literal, not creative.
        if p.acceptsTemperature(model: c.model) { b["temperature"] = 0.2 }
        switch p.thinkingSwitch(model: c.model) {
        case .none: break
        case .thinkingTypeDisabled: b["thinking"] = ["type": "disabled"]
        case .enableThinkingFalse: b["enable_thinking"] = false
        case .reasoningEffort(let e): b["reasoning_effort"] = e
        }
        // Never tools, never JSON mode: plain text out.
        return b
    }

    public struct Parsed: Equatable { public var text: String; public var input: Int; public var cached: Int; public var output: Int }

    public enum ParseError: Error, Equatable { case refused, malformed(String) }

    public static func parse(_ json: [String: Any]) throws -> Parsed {
        guard let choice = (json["choices"] as? [[String: Any]])?.first else {
            throw ParseError.malformed(errorMessage(json) ?? "no choices")
        }
        if choice["finish_reason"] as? String == "content_filter" { throw ParseError.refused }
        let msg = choice["message"] as? [String: Any] ?? [:]
        var text = ""
        if let s = msg["content"] as? String {
            text = s
        } else if let parts = msg["content"] as? [[String: Any]] {
            // Some gateways return content parts.
            text = parts.compactMap { ($0["type"] as? String ?? "text") == "text" ? $0["text"] as? String : nil }.joined()
        }
        // `reasoning_content` (DeepSeek, Qwen, GLM, Kimi, Doubao) is never part of the answer.
        text = stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, msg["refusal"] as? String != nil { throw ParseError.refused }
        let u = json["usage"] as? [String: Any] ?? [:]
        let details = u["prompt_tokens_details"] as? [String: Any]
        let cached = (details?["cached_tokens"] as? Int)          // OpenAI, Qwen, Doubao, GLM
            ?? (u["prompt_cache_hit_tokens"] as? Int)             // DeepSeek
            ?? (u["cached_tokens"] as? Int)                       // Kimi
            ?? 0
        return Parsed(text: text, input: u["prompt_tokens"] as? Int ?? 0, cached: cached,
                      output: u["completion_tokens"] as? Int ?? 0)
    }

    /// Removes `<think>…</think>` reasoning that some models (and gateways serving them) put inline.
    /// An unterminated opening block means the answer never started (cut off while reasoning); a lone
    /// closing tag means the opening tag was eaten by the template: keep what follows it.
    public static func stripThinking(_ s: String) -> String {
        var t = s
        let open = try! NSRegularExpression(pattern: #"<think(?:ing)?>[\s\S]*?</think(?:ing)?>"#, options: [.caseInsensitive])
        t = open.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
        if let r = t.range(of: "</think>", options: [.caseInsensitive, .backwards]) {
            t = String(t[r.upperBound...])
        }
        if let r = t.range(of: "<think>", options: .caseInsensitive),
           t[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            t = ""
        }
        return t
    }

    /// Error text from either `{"error": {"message": …}}` (OpenAI style) or `{"message": …}` /
    /// `{"error_msg": …}` (some vendors' gateways).
    public static func errorMessage(_ json: [String: Any]) -> String? {
        if let e = json["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let m = json["error"] as? String { return m }
        if let m = json["message"] as? String { return m }
        if let m = json["error_msg"] as? String { return m }
        return nil
    }
}
