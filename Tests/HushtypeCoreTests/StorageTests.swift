import Foundation
import Testing
@testable import HushtypeCore

/// Retention, audio cap, orphan cleanup and log trimming. Every test works on its own temporary
/// folder: the user's history and eval/data are never touched.
@Suite struct StorageTests {
    let dir: URL
    let store: HistoryStore

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hushtype-storage-test-\(UUID().uuidString)")
        store = try HistoryStore(directory: dir)
    }

    /// An entry `daysAgo` old with a recording of `seconds` (32 KB per second).
    @discardableResult
    func add(daysAgo: Double, seconds: Double? = 1, now: Date) -> HistoryItem {
        let id = UUID().uuidString
        let audio = seconds.flatMap { store.saveAudio([Float](repeating: 0.1, count: Int($0 * 16000)), id: id) }
        let item = HistoryItem(id: id, createdAt: now.addingTimeInterval(-daysAgo * 86400), text: "t", rawText: "r",
                               appName: nil, bundleID: nil, durationSeconds: seconds ?? 0, latencySeconds: 0, outcome: "ok",
                               audioFile: audio)
        store.add(item)
        return item
    }

    func audioOf(_ id: String) -> String? { store.recent(limit: 1000).first { $0.id == id }?.audioFile }

    @Test func textRetentionDeletesEntriesAndTheirAudio() {
        let now = Date()
        let old = add(daysAgo: 40, now: now), fresh = add(daysAgo: 1, now: now)
        let r = store.maintain(.init(textDays: 30, audioDays: nil, audioMaxBytes: nil), now: now, orphanGrace: 0)
        #expect(r.entriesDeleted == 1)
        #expect(store.recent().map(\.id) == [fresh.id])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(old.audioFile!).path))
        #expect(store.usage().audioFiles == 1)
    }

    @Test func audioAgeLimitKeepsTheText() {
        let now = Date()
        let old = add(daysAgo: 10, now: now), fresh = add(daysAgo: 2, now: now)
        let r = store.maintain(.init(textDays: nil, audioDays: 7, audioMaxBytes: nil), now: now, orphanGrace: 0)
        #expect(r.audioDeleted == 1 && r.entriesDeleted == 0)
        #expect(store.recent().count == 2)
        #expect(audioOf(old.id) == nil)
        #expect(audioOf(fresh.id) != nil)
    }

    @Test func sizeCapDeletesOldestRecordingsFirst() {
        let now = Date()
        let a = add(daysAgo: 3, seconds: 2, now: now)    // ~64 KB each
        let b = add(daysAgo: 2, seconds: 2, now: now)
        let c = add(daysAgo: 1, seconds: 2, now: now)
        let r = store.maintain(.init(textDays: nil, audioDays: nil, audioMaxBytes: 140_000), now: now, orphanGrace: 0)
        #expect(r.audioDeleted == 1)
        #expect(audioOf(a.id) == nil)
        #expect(audioOf(b.id) != nil && audioOf(c.id) != nil)
        #expect(store.usage().audioBytes <= 140_000)
        #expect(store.recent().count == 3)
    }

    @Test func orphansAndMissingFilesAreReconciled() throws {
        let now = Date()
        let kept = add(daysAgo: 0, now: now)
        let lost = add(daysAgo: 0, now: now)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(lost.audioFile!))
        let stray = dir.appendingPathComponent("audio/stray.wav")
        try Data(count: 1000).write(to: stray)
        // A brand-new file (a dictation in progress) is not an orphan yet.
        let r0 = store.maintain(.init(textDays: nil, audioDays: nil, audioMaxBytes: nil), now: now, orphanGrace: 600)
        #expect(r0.orphanFilesDeleted == 0)
        #expect(r0.missingAudioCleared == 1)
        #expect(audioOf(lost.id) == nil)
        let r1 = store.maintain(.init(textDays: nil, audioDays: nil, audioMaxBytes: nil), now: now.addingTimeInterval(3600), orphanGrace: 600)
        #expect(r1.orphanFilesDeleted == 1)
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(audioOf(kept.id) != nil)
    }

    @Test func vacuumAfterLargeDeleteShrinksTheDatabase() {
        let now = Date()
        for _ in 0..<400 {
            store.add(HistoryItem(createdAt: now.addingTimeInterval(-50 * 86400), text: String(repeating: "很长的历史文本", count: 200),
                                  rawText: "r", appName: nil, bundleID: nil, durationSeconds: 1, latencySeconds: 0, outcome: "ok"))
        }
        _ = store.maintain(.init(textDays: nil, audioDays: nil, audioMaxBytes: nil), now: now, forceVacuum: true)
        let big = store.usage().databaseBytes
        let r = store.maintain(.init(textDays: 30, audioDays: nil, audioMaxBytes: nil), now: now)
        #expect(r.entriesDeleted == 400)
        #expect(r.vacuumed)
        #expect(store.usage().databaseBytes < big / 4)
    }

    @Test func settingsRoundTripRetention() throws {
        let d = try #require(UserDefaults(suiteName: "hushtype.test.\(UUID().uuidString)"))
        var s = HushtypeSettings()
        #expect(s.audioDays == 7 && s.audioCapMB == 500)
        s.audioDays = nil
        s.audioCapMB = nil
        s.save(d)
        let back = HushtypeSettings.load(d)
        #expect(back.audioDays == nil && back.audioCapMB == nil)
        #expect(back.retention == .init(textDays: 30, audioDays: nil, audioMaxBytes: nil))
    }

    @Test func logFolderIsTrimmed() throws {
        let logs = dir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let now = Date()
        let live = logs.appendingPathComponent(Log.url.lastPathComponent)
        try Data(count: 100).write(to: live)
        let stale = logs.appendingPathComponent("murmur.log")
        try Data(count: 100).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86400)], ofItemAtPath: stale.path)
        for i in 0..<3 { try Data(count: 6_000_000).write(to: logs.appendingPathComponent("extra\(i).log")) }
        let removed = Log.trimDirectory(logs, maxBytes: 10_000_000, maxAgeDays: 30, now: now)
        #expect(removed >= 2)
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(HistoryStore.directorySize(logs) <= 10_000_000 + 100_000)
    }
}
