import Foundation

/// Learns dictionary terms from the user's own corrections: after Hushtype inserts text, it looks at
/// the same field a little later, and if the user fixed a word (e.g. "Clawd" → "Claude"), the
/// corrected spelling goes into the personal dictionary.
public enum EditLearner {
    /// The user's edited version of the inserted text, recovered by stripping the unchanged text that
    /// surrounded the insertion point. Nil when the surroundings changed too (can't localize the edit).
    /// `before`/`after` are the (budget-trimmed) texts that surrounded the caret at dictation time.
    public static func editedRegion(now value: String, before: String, after: String) -> String? {
        var start = value.startIndex
        if !before.isEmpty {
            guard let r = value.range(of: before) else { return nil }
            start = r.upperBound
        }
        var end = value.endIndex
        if !after.isEmpty {
            guard let r = value.range(of: after, range: start..<value.endIndex) else { return nil }
            end = r.lowerBound
        }
        return String(value[start..<end])
    }

    /// Where the inserted text is now and what it says: fuzzy-matched inside the field's current text,
    /// so it still works when the app reflows it (terminal line wrapping, box borders around a TUI
    /// input like Claude Code's, editors re-rendering) and when the text around it changes.
    /// - Parameters:
    ///   - hint: caret offset (UTF-16) right after insertion, to search near it in long documents.
    /// - Returns: the matched text (layout noise removed) and its edit distance from `inserted`
    ///   (ignoring whitespace); nil when the field is too long to search or nothing is close.
    public static func locate(inserted: String, in value: String, hint: Int? = nil) -> (text: String, cost: Int)? {
        let pattern = Array(inserted).filter { !isLayout($0) }
        guard !pattern.isEmpty, pattern.count <= 2000 else { return nil }
        let all = Array(value)
        let pad = pattern.count * 2 + 1500
        var windows: [Range<Int>] = []
        if all.count <= pad * 2 { windows = [0..<all.count] } else {
            if let h = hint {
                // UTF-16 offset → approximate character offset is fine for a window centre.
                let c = min(all.count, max(0, h))
                windows.append(max(0, c - pad)..<min(all.count, c + pad))
            }
            windows.append(max(0, all.count - pad * 2)..<all.count)   // terminals: newest output at the end
        }
        var best: (text: String, cost: Int)?
        for w in windows {
            guard let r = align(pattern, in: all, window: w) else { continue }
            if best == nil || r.cost < best!.cost { best = r }
            if r.cost == 0 { break }
        }
        return best
    }

    /// Whitespace and box-drawing characters: layout, not content.
    static func isLayout(_ c: Character) -> Bool {
        if c.isWhitespace { return true }
        guard let u = c.unicodeScalars.first?.value else { return false }
        return (0x2500...0x259F).contains(u) || u == 0x23F5 /* ⏵ */
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(u) || (0xFF00...0xFFEF).contains(u)
    }

    /// Approximate substring match (Sellers): the pattern must be consumed, the text start/end are free.
    static func align(_ p: [Character], in all: [Character], window: Range<Int>) -> (text: String, cost: Int)? {
        var idx: [Int] = []          // content characters of the window → index in `all`
        idx.reserveCapacity(window.count)
        for i in window where !isLayout(all[i]) { idx.append(i) }
        let t = idx.map { all[$0] }
        guard !t.isEmpty else { return nil }
        let m = p.count, n = t.count
        var prev = [Int](repeating: 0, count: n + 1), cur = prev
        var prevStart = Array(0...n), curStart = prevStart
        for i in 1...m {
            cur[0] = i; curStart[0] = 0
            for j in 1...n {
                let sub = prev[j - 1] + (p[i - 1] == t[j - 1] ? 0 : 1)
                let del = prev[j] + 1, ins = cur[j - 1] + 1
                if sub <= del && sub <= ins { cur[j] = sub; curStart[j] = prevStart[j - 1] }
                else if del <= ins { cur[j] = del; curStart[j] = prevStart[j] }
                else { cur[j] = ins; curStart[j] = curStart[j - 1] }
            }
            swap(&prev, &cur); swap(&prevStart, &curStart)
        }
        var bestJ = 1
        for j in 1...n where prev[j] < prev[bestJ] { bestJ = j }
        var s = prevStart[bestJ], e = bestJ
        guard s < e else { return nil }
        // An edit at either end ("我们明天…" → "Zyntrax天…") makes the cheapest match start mid-word;
        // never cut through a word: widen to the whole word on both sides.
        func word(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        while s > 0, word(t[s - 1]), word(t[s]), idx[s - 1] + 1 == idx[s] { s -= 1 }
        while e < n, word(t[e - 1]), word(t[e]), idx[e - 1] + 1 == idx[e] { e += 1 }
        let raw = Array(all[idx[s]...idx[e - 1]])
        return (clean(raw), prev[bestJ])
    }

    /// Undo the app's layout: drop borders, join wrapped lines (no space between CJK characters).
    static func clean(_ raw: [Character]) -> String {
        var out: [Character] = []
        var i = 0
        while i < raw.count {
            let c = raw[i]
            if isLayout(c) {
                var j = i, sawBreak = false
                while j < raw.count, isLayout(raw[j]) { if raw[j].isNewline || !raw[j].isWhitespace { sawBreak = true }; j += 1 }
                let prevC = out.last, nextC = j < raw.count ? raw[j] : nil
                if sawBreak, let a = prevC, let b = nextC, isCJK(a) || isCJK(b) { /* wrapped CJK: no space */ }
                else if prevC != nil, nextC != nil { out.append(" ") }
                i = j
            } else { out.append(c); i += 1 }
        }
        return String(out)
    }

    public enum Verdict: Equatable, Sendable {
        case unchanged, layoutOnly, tooLarge, correction
    }

    /// Cheap pre-filter before asking the model: the edit must be small (a fix, not a rewrite).
    public static func classify(inserted: String, edited: String) -> Verdict {
        guard inserted != edited, !edited.isEmpty else { return .unchanged }
        let a = Array(inserted).filter { !isLayout($0) }, b = Array(edited).filter { !isLayout($0) }
        guard a != b else { return .layoutOnly }   // only spacing / line wrapping differs
        // A misheard term can be fixed by replacing a long phrase ("cooper netties" → "Kubernetes"),
        // so allow up to half the text to change, but not a wholesale rewrite.
        guard abs(a.count - b.count) <= max(12, a.count / 2) else { return .tooLarge }
        let d = levenshtein(a, b)
        guard d > 0 && d <= max(6, a.count / 2) else { return .tooLarge }
        // A real fix leaves most of the text in place around it. Different text that merely looks similar
        // (the next message typed into a chat / terminal box, "还得再上一版本" vs "型生成的那版本") shares
        // little more than a word at one end.
        var pre = 0; while pre < min(a.count, b.count), a[pre] == b[pre] { pre += 1 }
        var suf = 0; while suf < min(a.count, b.count) - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        if a.count < 24 { return (pre >= 1 && suf >= 1) || pre + suf >= a.count / 2 ? .correction : .tooLarge }
        return pre + suf >= a.count * 2 / 5 || d <= 4 ? .correction : .tooLarge
    }

    /// Terminals expose the whole scrollback as one "field" and redraw it (prompts, echoes, wrapping):
    /// watching it for edits only produces false corrections.
    public static func isTerminal(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        let terminals = ["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp-stable",
                         "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio",
                         "io.tabby", "com.termius-dmg.mac"]
        return terminals.contains(id)
    }

    public static func looksLikeCorrection(inserted: String, edited: String) -> Bool {
        classify(inserted: inserted, edited: edited) == .correction
    }

    /// Punctuation, symbols and layout: how the text is formatted, not what it says.
    static func isFormat(_ c: Character) -> Bool {
        isLayout(c) || c.isPunctuation || c.isSymbol
    }

    /// What one edit teaches, split by kind so formatting changes don't pass for content preferences.
    public struct Split: Equatable, Sendable {
        /// `before` with only the word/content changes applied (layout and punctuation kept as before); nil if none.
        public var content: String?
        /// `before` with only the punctuation changes applied; nil if none.
        public var punctuation: String?
        /// `before` with both content and punctuation changes applied (layout kept as before).
        public var both: String?
        /// A word gained or changed symbols ("Nodejs" → "Node.js", "C" → "C++"): a term fix, not punctuation.
        public var touchesWord = false
        /// Stable key for the punctuation change ("-。", "-，+、"), to count how often the user repeats it.
        public var punctuationKey: String?
    }

    public static func split(before: String, after: String) -> Split {
        let a = Array(before), b = Array(after)
        guard a.count <= 1500, b.count <= 1500 else { return Split() }
        let ops = editScript(a, b)
        func apply(_ keep: (Character) -> Bool) -> String {
            var out: [Character] = []
            for op in ops {
                switch op {
                case .same(let c): out.append(c)
                case .delete(let c): if !keep(c) { out.append(c) }
                case .insert(let c): if keep(c) { out.append(c) }
                }
            }
            return String(out)
        }
        let isPunct = { (c: Character) in isFormat(c) && !isLayout(c) }
        let content = apply { !isFormat($0) }
        let punct = apply(isPunct)
        let both = apply { !isLayout($0) }
        var removed: [Character] = [], added: [Character] = []
        for op in ops {
            if case .delete(let c) = op, isPunct(c) { removed.append(c) }
            if case .insert(let c) = op, isPunct(c) { added.append(c) }
        }
        let key = (removed.isEmpty ? "" : "-" + String(removed.sorted())) + (added.isEmpty ? "" : "+" + String(added.sorted()))
        // Latin words that contain a symbol and are new in the edit (spaces and CJK separate words).
        func words(_ t: String) -> Set<Substring> {
            Set(t.split { isLayout($0) || isCJK($0) }.filter { w in
                w.contains { isFormat($0) } && w.contains { $0.isLetter || $0.isNumber }
            }.map { $0.trimmingCharacters(in: .punctuationCharacters)[...] }.filter { w in w.contains { isFormat($0) } })
        }
        return Split(content: content == before ? nil : content,
                     punctuation: punct == before ? nil : punct,
                     both: both == before ? nil : both,
                     touchesWord: !words(after).subtracting(words(before)).isEmpty,
                     punctuationKey: key.isEmpty ? nil : key)
    }

    enum Op { case same(Character), delete(Character), insert(Character) }

    /// Character-level edit script (substitution = delete + insert), in text order.
    static func editScript(_ a: [Character], _ b: [Character]) -> [Op] {
        let n = a.count, m = b.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    d[i][j] = a[i - 1] == b[j - 1] ? d[i - 1][j - 1] : min(d[i - 1][j], d[i][j - 1], d[i - 1][j - 1]) + 1
                }
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1], d[i][j] == d[i - 1][j - 1] {
                ops.append(.same(a[i - 1])); i -= 1; j -= 1
            } else if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + 1 {
                ops.append(.insert(b[j - 1])); ops.append(.delete(a[i - 1])); i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                ops.append(.delete(a[i - 1])); i -= 1
            } else {
                ops.append(.insert(b[j - 1])); j -= 1
            }
        }
        return ops.reversed()
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    public static let system = """
    用户用语音输入了一段文字，插入后又手动改了几个字。比较「原文」和「改后」，找出用户纠正的专有名词或术语（人名、产品名、公司名、技术词、英文单词的拼写等），输出它们**改后**的正确写法。
    只输出 JSON 字符串数组，例如 ["Claude", "李想"]。普通措辞、标点、语气的修改不算，没有就输出 []。
    """

    /// Asks the model which terms were corrected. Returns [] on any failure.
    public static func correctedTerms(inserted: String, edited: String, rewriter: Rewriter) async -> [String] {
        let user = "<原文>\(inserted)</原文>\n<改后>\(edited)</改后>"
        guard let r = try? await rewriter.rewrite(system: system, user: user, source: user, guarded: false),
              let data = r.text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 40 && edited.contains($0) }
    }
}
