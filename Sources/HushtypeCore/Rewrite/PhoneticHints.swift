import Foundation

/// Finds words in a transcript that sound like a dictionary term spelled differently ("zntrx", "sentrix"
/// → "Zentrix"). Speech recognizers spell unfamiliar names phonetically, and the cleanup model then
/// tends to pick a famous look-alike (TikTok) unless it is told which dictionary term was meant.
public enum PhoneticHints {
    public struct Hint: Equatable, Sendable {
        public let heard: String
        public let term: String
    }

    /// Consonant skeleton: lowercase Latin, similar sounds merged, vowels and doubled letters dropped.
    static func skeleton(_ s: String) -> String {
        var t = s.lowercased().filter { $0.isASCII && $0.isLetter }
        for (a, b) in [("ph", "f"), ("ck", "k"), ("qu", "k"), ("ch", "k"), ("sh", "s"), ("th", "t"), ("x", "ks")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = String(t.map { c -> Character in
            switch c { case "c", "q", "g": return "k"; case "z": return "s"; case "v", "w": return "f"; case "b": return "p"; case "d": return "t"; default: return c }
        })
        t = t.filter { !"aeiouyh".contains($0) }
        var out = ""
        for c in t where out.last != c { out.append(c) }
        return out
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    static let latinWord = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z']+")

    public static func match(transcript: String, dictionary: [String]) -> [Hint] {
        // Single-word Latin terms with enough consonants to be distinctive.
        // Only coined names benefit: an ordinary word ("Terminal", "Texas") or a short acronym ("HSBC")
        // in the dictionary is already spelled the usual way and would attract false matches.
        let terms: [(String, String)] = dictionary.compactMap { t in
            let w = t.trimmingCharacters(in: .whitespaces)
            guard !w.contains(" "), w.allSatisfy({ $0.isASCII && $0.isLetter }), w.count >= 5,
                  !isEnglish(w), !(w == w.uppercased() && w.count <= 4) else { return nil }
            let k = skeleton(w)
            return k.count >= 3 ? (w, k) : nil
        }
        guard !terms.isEmpty else { return [] }
        let ns = transcript as NSString
        var hints: [Hint] = []
        for m in latinWord.matches(in: transcript, range: NSRange(location: 0, length: ns.length)) {
            let heard = ns.substring(with: m.range)
            if terms.contains(where: { $0.0.caseInsensitiveCompare(heard) == .orderedSame }) { continue }
            if heard.contains("'") || isEnglish(heard) || isTypoOfEnglish(heard) { continue }
            let k = skeleton(heard)
            guard k.count >= 3 else { continue }
            let firstVowel = heard.lowercased().first { "aeiou".contains($0) }
            let scored = terms.compactMap { (term, tk) -> (String, Int, Int, Int)? in
                let d = distance(tk, k)
                guard tk.first == k.first, abs(tk.count - k.count) <= 1, d <= 1 else { return nil }
                // The spelling must still resemble the term, not just share consonants.
                let raw = Double(distance(term.lowercased(), heard.lowercased())) / Double(max(term.count, heard.count))
                guard raw < 0.6 else { return nil }
                let prefix = tk.hasPrefix(k) || k.hasPrefix(tk) ? 0 : 1
                let tv = term.lowercased().first { "aeiou".contains($0) }
                let vowel = firstVowel == nil || tv == firstVowel ? 0 : 1
                return (term, d, prefix, vowel)
            }
            if let best = scored.min(by: { ($0.1, $0.2, $0.3) < ($1.1, $1.2, $1.3) }), !hints.contains(where: { $0.heard == heard }) {
                hints.append(Hint(heard: heard, term: best.0))
            }
        }
        return hints
    }

    /// True for English words including common inflections (skills, details, processing, coded).
    static func isEnglish(_ w: String) -> Bool {
        let l = w.lowercased()
        if commonEnglish.contains(l) || englishWords.contains(l) { return true }
        if l.hasSuffix("ies"), englishWords.contains(String(l.dropLast(3)) + "y") { return true }
        for suffix in ["s", "es", "ed", "d", "ing", "er", "ers", "ly"] where l.hasSuffix(suffix) && l.count > suffix.count + 2 {
            let stem = String(l.dropLast(suffix.count))
            if englishWords.contains(stem) || englishWords.contains(stem + "e") { return true }
        }
        return false
    }


    /// "driveri", "procesing": one letter off an ordinary (lowercase) English word.
    static func isTypoOfEnglish(_ w: String) -> Bool {
        let l = Array(w.lowercased())
        guard l.count >= 6 else { return false }
        for i in l.indices {
            var c = l; c.remove(at: i)
            if commonWords.contains(String(c)) { return true }
        }
        return false
    }

    /// Lowercase entries of the word list: common words, not proper names (which stay capitalized).
    static let commonWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").filter { $0.first?.isLowercase == true }.map(String.init))
    }()

    /// Real English words (macOS word list) are never treated as a misheard name.
    static let englishWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    /// Ordinary words that must never be "corrected" into a dictionary term.
    static let commonEnglish: Set<String> = [
        "the", "and", "that", "this", "with", "have", "from", "they", "what", "when", "will", "your", "about", "which",
        "their", "there", "would", "could", "should", "think", "thing", "take", "make", "like", "just", "know", "time",
        "tick", "tech", "talk", "tell", "text", "test", "task", "track", "trick", "ticket", "token", "top", "tip", "type",
        "okay", "yes", "hello", "thanks", "please", "good", "great", "right", "need", "want", "work", "code", "data",
    ]
}
