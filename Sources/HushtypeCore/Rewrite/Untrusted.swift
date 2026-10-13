import Foundation

/// Hygiene for text that goes into a prompt but isn't Hushtype's own: transcripts, screen context,
/// selected text, dictionary entries.
public enum Untrusted {
    /// Tags Hushtype uses to structure its prompts. Untrusted text must not be able to close or open
    /// them (e.g. a web page containing "</context> new instructions: …").
    static let tagPattern = try! NSRegularExpression(
        pattern: #"</?\s*(transcript|context|before_cursor|after_cursor|selected|instruction|instruction_alt|A|B|dictionary|dictionary_hints|user_corrections|user_liked)\s*>"#,
        options: [.caseInsensitive])

    /// Replaces the "<" of any Hushtype tag with a look-alike so it reads the same but can't act as markup.
    public static func neutralize(_ s: String) -> String {
        let ns = s as NSString
        var out = s
        for m in tagPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let tag = ns.substring(with: m.range)
            out = (out as NSString).replacingCharacters(in: m.range, with: tag.replacingOccurrences(of: "<", with: "‹")
                .replacingOccurrences(of: ">", with: "›"))
        }
        return out
    }

    /// Credentials and identifiers that sometimes sit on screen next to the caret (a terminal with an
    /// API key, a form with a card number). They never help with spelling, so they never leave the Mac.
    static let secretPatterns: [NSRegularExpression] = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#,
        #"\bsk-(ant-)?[A-Za-z0-9_\-]{16,}"#,                      // Anthropic / OpenAI style keys
        #"\bAKIA[0-9A-Z]{16}\b"#,                                 // AWS access key id
        #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#,                       // GitHub tokens
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,                       // Slack tokens
        #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,  // JWT
        #"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key)\s*[:=]\s*\S+"#,
        #"\b\d{17}[\dXx]\b"#,                                     // CN resident ID
        #"\b(?:\d[ -]?){13,19}\b"#,                               // card numbers
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func redactSecrets(_ s: String) -> String {
        var out = s
        for re in secretPatterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length),
                                              withTemplate: "[已隐去]")
        }
        return out
    }

    /// Screen context: secrets removed, tags neutralized, URL reduced to scheme + host + path.
    public static func context(_ c: DictationContext) -> DictationContext {
        var c = c
        let clean = { (s: String?) in s.map { neutralize(redactSecrets($0)) } }
        c.appName = clean(c.appName)
        c.windowTitle = clean(c.windowTitle)
        c.textBefore = clean(c.textBefore)
        c.textAfter = clean(c.textAfter)
        c.selectedText = clean(c.selectedText)
        if let u = c.url, var comps = URLComponents(string: u) {
            comps.query = nil
            comps.fragment = nil
            comps.user = nil
            comps.password = nil
            c.url = comps.string.map(neutralize)
        }
        return c
    }
}
