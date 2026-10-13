import Foundation

/// Moving Hushtype to another Mac: everything the user built up (history and its audio, dictionary,
/// learned habits, preferences) in one `.hushtypebackup` file. Secrets (API key) stay in the Keychain
/// and are not included.
public enum DataMigration {
    public struct Summary: Sendable {
        public var historyAdded: Int
        public var termsAdded: Int
        public var habits: Int
    }

    public enum MigrationError: Error, LocalizedError {
        case archive, notABackup
        public var errorDescription: String? {
            switch self {
            case .archive: return String(localized: "打包或解包失败")
            case .notABackup: return String(localized: "这不是 Hushtype 的备份文件")
            }
        }
    }

    static let manifestName = "hushtype-backup.json"

    /// Writes `destination` (a zip). `supportDir` is ~/Library/Application Support/Hushtype.
    public static func export(to destination: URL, settings: HushtypeSettings, history: HistoryStore,
                              supportDir: URL, includeAudio: Bool) throws {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("hushtype-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try history.exportDatabase(to: stage.appendingPathComponent("history.sqlite"))
        if includeAudio {
            let audio = history.directory.appendingPathComponent("audio")
            if FileManager.default.fileExists(atPath: audio.path) {
                try FileManager.default.copyItem(at: audio, to: stage.appendingPathComponent("audio"))
            }
        }
        for name in ["corrections.json", "liked.json"] {
            let src = supportDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: stage.appendingPathComponent(name))
            }
        }
        try JSONEncoder().encode(settings).write(to: stage.appendingPathComponent("settings.json"))
        let manifest: [String: Any] = ["format": 1, "createdAt": ISO8601DateFormatter().string(from: Date()),
                                       "host": Host.current().localizedName ?? ""]
        try JSONSerialization.data(withJSONObject: manifest).write(to: stage.appendingPathComponent(manifestName))
        try? FileManager.default.removeItem(at: destination)
        try ditto(["-c", "-k", "--sequesterRsrc", stage.path, destination.path])
    }

    /// Reads a backup and merges it in. History and learned habits are merged; the dictionary is a
    /// union; preferences are taken from the backup except for this Mac's own (microphone, onboarding).
    public static func importBackup(from source: URL, into settings: inout HushtypeSettings, history: HistoryStore,
                                    corrections: CorrectionMemory, supportDir: URL) throws -> Summary {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("hushtype-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try ditto(["-x", "-k", source.path, stage.path])
        guard FileManager.default.fileExists(atPath: stage.appendingPathComponent(manifestName).path) else {
            throw MigrationError.notABackup
        }
        var summary = Summary(historyAdded: 0, termsAdded: 0, habits: 0)
        let db = stage.appendingPathComponent("history.sqlite")
        if FileManager.default.fileExists(atPath: db.path) { summary.historyAdded = try history.importDatabase(from: db) }
        let audio = stage.appendingPathComponent("audio")
        if let files = try? FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil) {
            let dst = history.directory.appendingPathComponent("audio")
            for f in files where !FileManager.default.fileExists(atPath: dst.appendingPathComponent(f.lastPathComponent).path) {
                try? FileManager.default.copyItem(at: f, to: dst.appendingPathComponent(f.lastPathComponent))
            }
        }
        let dec = JSONDecoder()
        if let data = try? Data(contentsOf: stage.appendingPathComponent("corrections.json")),
           let list = try? dec.decode([CorrectionMemory.Correction].self, from: data) {
            for c in list { corrections.add(before: c.before, after: c.after) }
            summary.habits += list.count
        }
        if let data = try? Data(contentsOf: stage.appendingPathComponent("liked.json")),
           let list = try? dec.decode([CorrectionMemory.Correction].self, from: data) {
            for c in list { corrections.like(raw: c.before, result: c.after) }
            summary.habits += list.count
        }
        if let data = try? Data(contentsOf: stage.appendingPathComponent("settings.json")),
           var incoming = try? dec.decode(HushtypeSettings.self, from: data) {
            var terms = settings.dictionary
            for t in incoming.dictionary where !terms.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
                terms.append(t)
                summary.termsAdded += 1
            }
            incoming.dictionary = terms
            incoming.microphoneUID = settings.microphoneUID
            incoming.hasOnboarded = settings.hasOnboarded
            // Where text is sent and what is shared stay this Mac's choice: a backup file (possibly
            // from someone else) must never redirect transcripts to another server or widen sharing.
            incoming.provider = settings.provider
            incoming.proxyURL = settings.proxyURL
            incoming.sendContext = settings.sendContext
            incoming.contextExcluded = Array(Set(settings.contextExcluded).union(incoming.contextExcluded))
            settings = incoming
        }
        return summary
    }

    static func ditto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw MigrationError.archive }
    }
}
