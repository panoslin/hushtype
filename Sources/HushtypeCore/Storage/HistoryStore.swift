import Foundation
import SQLite3

public struct HistoryItem: Identifiable, Sendable, Equatable {
    public let id: String
    public var createdAt: Date
    public var text: String
    public var rawText: String
    public var appName: String?
    public var bundleID: String?
    public var durationSeconds: Double
    public var latencySeconds: Double
    public var outcome: String
    /// Relative path (inside the store directory) of the saved audio, when audio retention is on.
    public var audioFile: String?
    /// The user's verdict on this result: 1 = good, -1 = bad, 0 = not rated.
    public var rating: Int = 0

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), text: String, rawText: String,
                appName: String?, bundleID: String?, durationSeconds: Double, latencySeconds: Double,
                outcome: String, audioFile: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.rawText = rawText
        self.appName = appName
        self.bundleID = bundleID
        self.durationSeconds = durationSeconds
        self.latencySeconds = latencySeconds
        self.outcome = outcome
        self.audioFile = audioFile
    }
}

/// Local dictation history in SQLite. Nothing here leaves the Mac.
public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "hushtype.history")
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("audio"),
                                                withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { throw StoreError.open(path) }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
        CREATE TABLE IF NOT EXISTS history (
          id TEXT PRIMARY KEY, created_at REAL NOT NULL, text TEXT NOT NULL, raw_text TEXT NOT NULL,
          app_name TEXT, bundle_id TEXT, duration REAL NOT NULL, latency REAL NOT NULL,
          outcome TEXT NOT NULL, audio_file TEXT);
        CREATE INDEX IF NOT EXISTS idx_history_created ON history(created_at DESC);
        """)
        // v2: rating column (older databases are migrated in place).
        try? exec("ALTER TABLE history ADD COLUMN rating INTEGER NOT NULL DEFAULT 0;")
    }

    deinit { sqlite3_close(db) }

    public enum StoreError: Error { case open(String), sql(String) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw StoreError.sql(m)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public func add(_ item: HistoryItem) {
        queue.sync {
            var st: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO history (id, created_at, text, raw_text, app_name, bundle_id, duration, latency, outcome, audio_file, rating) VALUES (?,?,?,?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(st) }
            func text(_ i: Int32, _ s: String?) {
                if let s { sqlite3_bind_text(st, i, s, -1, Self.transient) } else { sqlite3_bind_null(st, i) }
            }
            text(1, item.id)
            sqlite3_bind_double(st, 2, item.createdAt.timeIntervalSince1970)
            text(3, item.text); text(4, item.rawText); text(5, item.appName); text(6, item.bundleID)
            sqlite3_bind_double(st, 7, item.durationSeconds)
            sqlite3_bind_double(st, 8, item.latencySeconds)
            text(9, item.outcome); text(10, item.audioFile)
            sqlite3_bind_int(st, 11, Int32(item.rating))
            sqlite3_step(st)
        }
    }

    public func recent(limit: Int = 200, search: String? = nil) -> [HistoryItem] {
        queue.sync {
            var st: OpaquePointer?
            let q = (search ?? "").trimmingCharacters(in: .whitespaces)
            let sql = q.isEmpty
                ? "SELECT \(Self.columns) FROM history ORDER BY created_at DESC LIMIT ?"
                : "SELECT \(Self.columns) FROM history WHERE text LIKE ? OR raw_text LIKE ? ORDER BY created_at DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(st) }
            if q.isEmpty {
                sqlite3_bind_int(st, 1, Int32(limit))
            } else {
                let like = "%\(q)%"
                sqlite3_bind_text(st, 1, like, -1, Self.transient)
                sqlite3_bind_text(st, 2, like, -1, Self.transient)
                sqlite3_bind_int(st, 3, Int32(limit))
            }
            var out: [HistoryItem] = []
            func col(_ i: Int32) -> String? {
                sqlite3_column_text(st, i).map { String(cString: $0) }
            }
            while sqlite3_step(st) == SQLITE_ROW {
                out.append(HistoryItem(id: col(0) ?? "", createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                                       text: col(2) ?? "", rawText: col(3) ?? "", appName: col(4), bundleID: col(5),
                                       durationSeconds: sqlite3_column_double(st, 6),
                                       latencySeconds: sqlite3_column_double(st, 7), outcome: col(8) ?? "",
                                       audioFile: col(9)))
                out[out.count - 1].rating = Int(sqlite3_column_int(st, 10))
            }
            return out
        }
    }

    static let columns = "id, created_at, text, raw_text, app_name, bundle_id, duration, latency, outcome, audio_file, rating"

    /// Replaces an entry's text after it was cleaned up again.
    public func updateText(id: String, text: String, outcome: String) {
        queue.sync {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE history SET text = ?, outcome = ? WHERE id = ?", -1, &st, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(st, 1, text, -1, Self.transient)
            sqlite3_bind_text(st, 2, outcome, -1, Self.transient)
            sqlite3_bind_text(st, 3, id, -1, Self.transient)
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
    }

    public func setRating(id: String, _ rating: Int) {
        queue.sync {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE history SET rating = ? WHERE id = ?", -1, &st, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(st, 1, Int32(rating))
            sqlite3_bind_text(st, 2, id, -1, Self.transient)
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
    }

    public func delete(id: String) {
        let audio = recent(limit: 10_000).first { $0.id == id }?.audioFile
        queue.sync {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM history WHERE id = ?", -1, &st, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(st, 1, id, -1, Self.transient)
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
        if let a = audio { try? FileManager.default.removeItem(at: directory.appendingPathComponent(a)) }
    }

    /// Deletes items older than `days` (0 = keep nothing, nil = keep forever) and their audio.
    public func prune(olderThanDays days: Int?) {
        guard let days else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let old = recent(limit: 100_000).filter { $0.createdAt.timeIntervalSince1970 < cutoff }
        for item in old { delete(id: item.id) }
    }

    /// Consistent copy of the database (safe while in use).
    public func exportDatabase(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try queue.sync {
            let path = url.path.replacingOccurrences(of: "'", with: "''")
            try exec("VACUUM INTO '\(path)';")
        }
    }

    /// Merges another Hushtype history database into this one; entries already present are kept.
    /// Returns how many entries were added.
    @discardableResult
    public func importDatabase(from url: URL) throws -> Int {
        let before = recent(limit: 1_000_000).count
        try queue.sync {
            let path = url.path.replacingOccurrences(of: "'", with: "''")
            try exec("ATTACH DATABASE '\(path)' AS src;")
            defer { try? exec("DETACH DATABASE src;") }
            // Older exports may lack newer columns; copy the shared ones.
            try exec("""
            INSERT OR IGNORE INTO history (id, created_at, text, raw_text, app_name, bundle_id, duration, latency, outcome, audio_file)
            SELECT id, created_at, text, raw_text, app_name, bundle_id, duration, latency, outcome, audio_file FROM src.history;
            """)
        }
        return recent(limit: 1_000_000).count - before
    }

    public func deleteAll() {
        queue.sync { try? exec("DELETE FROM history;") }
        let audio = directory.appendingPathComponent("audio")
        try? FileManager.default.removeItem(at: audio)
        try? FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    }

    /// Saves 16 kHz mono samples as a WAV next to the database; returns the relative path.
    public func saveAudio(_ samples: [Float], id: String) -> String? {
        let rel = "audio/\(id).wav"
        let url = directory.appendingPathComponent(rel)
        guard (try? WAV.write(samples, sampleRate: 16000, to: url)) != nil else { return nil }
        return rel
    }

    public func stats(since: Date) -> (count: Int, words: Int, seconds: Double) {
        let items = recent(limit: 100_000).filter { $0.createdAt >= since }
        let words = items.reduce(0) { $0 + WordCount.count($1.text) }
        return (items.count, words, items.reduce(0) { $0 + $1.durationSeconds })
    }
}

/// Counts CJK characters individually and Latin words by whitespace, like most editors do.
public enum WordCount {
    public static func count(_ s: String) -> Int {
        var n = 0
        var inWord = false
        for u in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(u.value) || (0x3040...0x30FF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value) {
                n += 1; inWord = false
            } else if CharacterSet.alphanumerics.contains(u) {
                if !inWord { n += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return n
    }
}

public enum WAV {
    public static func write(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.reserveCapacity(d.count + samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        try d.write(to: url, options: .atomic)
    }
}
