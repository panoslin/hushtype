import Foundation

/// Small file logger for support/diagnostics: ~/Library/Logs/Hushtype/hushtype.log, rotated at 2 MB.
/// Never logs dictated text or secrets — only events, timings and errors.
public enum Log {
    private static let queue = DispatchQueue(label: "hushtype.log")
    public static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Hushtype", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("hushtype.log")
    }()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func info(_ message: @autoclosure () -> String) {
        let line = "\(formatter.string(from: Date())) \(message())\n"
        queue.async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attrs[.size] as? Int ?? 0) > 2_000_000 {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Keeps the log folder bounded. The live log rotates at 2 MB with one backup (≈ 4 MB); anything
    /// else in the folder (old names like murmur.log, crash leftovers) goes after `maxAgeDays`, and the
    /// oldest extras go first while the folder is over `maxBytes`. Returns how many files were removed.
    @discardableResult
    public static func trimDirectory(_ dir: URL? = nil, maxBytes: Int64 = 10_000_000, maxAgeDays: Double = 30,
                                     now: Date = Date()) -> Int {
        let dir = dir ?? url.deletingLastPathComponent()
        let keep: Set<String> = [url.lastPathComponent, url.deletingPathExtension().appendingPathExtension("1.log").lastPathComponent]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []).compactMap { u -> (URL, Int64, Date)? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var removed = 0
        var total = all.reduce(Int64(0)) { $0 + $1.1 }
        for (u, size, date) in all.sorted(by: { $0.2 < $1.2 }) where !keep.contains(u.lastPathComponent) {
            if now.timeIntervalSince(date) > maxAgeDays * 86400 || total > maxBytes {
                if (try? FileManager.default.removeItem(at: u)) != nil { removed += 1; total -= size }
            }
        }
        return removed
    }
}
