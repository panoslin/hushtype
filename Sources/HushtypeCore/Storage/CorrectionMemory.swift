import Foundation

/// The user's own edits to what Hushtype typed ("Hushtype wrote X, I changed it to Y"). The most recent
/// ones are shown to the rewrite model as examples of this user's preferences, so phrasing, formatting
/// and term choices the user keeps fixing stop recurring. Stored locally only.
public final class CorrectionMemory: @unchecked Sendable {
    public struct Correction: Codable, Equatable, Sendable {
        public var before: String
        public var after: String
        public var date: Date
    }

    private let url: URL
    private let likedURL: URL
    private let lock = NSLock()
    private var items: [Correction]
    /// Results the user rated 👍 (raw transcript → accepted text): positive examples of their style.
    private var liked: [Correction]
    public static let likedCapacity = 30
    public static let likedExamples = 3
    public static let capacity = 60
    /// How many examples go into the prompt (kept small: they are re-sent with every request).
    public static let promptExamples = 6

    public init(directory: URL) {
        url = directory.appendingPathComponent("corrections.json")
        likedURL = directory.appendingPathComponent("liked.json")
        items = (try? JSONDecoder().decode([Correction].self, from: Data(contentsOf: url))) ?? []
        liked = (try? JSONDecoder().decode([Correction].self, from: Data(contentsOf: likedURL))) ?? []
    }

    public var all: [Correction] { lock.lock(); defer { lock.unlock() }; return items }

    /// How often each not-yet-learned term / punctuation habit has come up in the user's edits.
    /// Something is only learned once it repeats, so a one-off edit (or a model misread) doesn't stick.
    private struct Pending: Codable { var terms: [String: Int] = [:]; var styles: [String: Int] = [:] }
    private lazy var pending: Pending = (try? JSONDecoder().decode(Pending.self, from: Data(contentsOf: pendingURL))) ?? Pending()
    private var pendingURL: URL { url.deletingLastPathComponent().appendingPathComponent("pending.json") }
    /// Edits needed before a term goes into the dictionary or a punctuation habit becomes an example.
    public static let repeatsToLearn = 2

    /// Counts one more sighting; returns true (and forgets the count) once it reaches `repeatsToLearn`.
    public func sighting(term: String) -> Bool { bump(\.terms, term.lowercased()) }
    public func sighting(style key: String) -> Bool { bump(\.styles, key) }

    private func bump(_ path: WritableKeyPath<Pending, [String: Int]>, _ key: String) -> Bool {
        lock.lock()
        var counts = pending[keyPath: path]
        let n = (counts[key] ?? 0) + 1
        if n >= Self.repeatsToLearn { counts[key] = nil } else { counts[key] = n }
        if counts.count > 500 { counts = counts.filter { $0.value > 1 } }   // bound the file
        pending[keyPath: path] = counts
        let snap = pending
        lock.unlock()
        try? JSONEncoder().encode(snap).write(to: pendingURL, options: .atomic)
        return n >= Self.repeatsToLearn
    }

    public func add(before: String, after: String) {
        let b = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, !a.isEmpty, b != a, b.count <= 600, a.count <= 600 else { return }
        lock.lock()
        items.removeAll { $0.before == b }
        items.append(Correction(before: b, after: a, date: Date()))
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        let snapshot = items
        lock.unlock()
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    public var allLiked: [Correction] { lock.lock(); defer { lock.unlock() }; return liked }

    /// 👍: keep this (raw → result) pair as an example of what the user wants.
    public func like(raw: String, result: String) {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines), t = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, !t.isEmpty, r.count <= 400, t.count <= 400 else { return }
        lock.lock()
        liked.removeAll { $0.after == t }
        liked.append(Correction(before: r, after: t, date: Date()))
        if liked.count > Self.likedCapacity { liked.removeFirst(liked.count - Self.likedCapacity) }
        let snap = liked
        lock.unlock()
        try? JSONEncoder().encode(snap).write(to: likedURL, options: .atomic)
    }

    public func unlike(result: String) {
        lock.lock()
        liked.removeAll { $0.after == result.trimmingCharacters(in: .whitespacesAndNewlines) }
        let snap = liked
        lock.unlock()
        try? JSONEncoder().encode(snap).write(to: likedURL, options: .atomic)
    }

    public func clear() {
        lock.lock(); items.removeAll(); liked.removeAll(); pending = Pending(); lock.unlock()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: pendingURL)
        try? FileManager.default.removeItem(at: likedURL)
    }

    /// Prompt section with the most recent corrections, or nil when there are none.
    public func promptSection() -> String? {
        var parts: [String] = []
        let recent = all.suffix(Self.promptExamples)
        if !recent.isEmpty {
            let lines = recent.map { "- 原来整理成：\(Untrusted.neutralize($0.before))\n  用户改成：\(Untrusted.neutralize($0.after))" }.joined(separator: "\n")
            parts.append("""
            <user_corrections>
            这位用户最近手动修改过的整理结果。从中学习他的偏好（用词、写法、标点、分段、专有名词），在新的整理里直接按他的习惯来；不要照抄这些句子的内容。
            \(lines)
            </user_corrections>
            """)
        }
        let good = allLiked.suffix(Self.likedExamples)
        if !good.isEmpty {
            let lines = good.map { "- 逐字稿：\(Untrusted.neutralize($0.before))\n  整理成：\(Untrusted.neutralize($0.after))" }.joined(separator: "\n")
            parts.append("""
            <user_liked>
            这位用户标记为「整理得好」的例子，代表他想要的整理力度和风格；保持一致，但不要照抄内容。
            \(lines)
            </user_liked>
            """)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
