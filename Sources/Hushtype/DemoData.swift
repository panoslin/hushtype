import Foundation
import HushtypeCore

/// Sample data for `--qa-demo` (README screenshots): a believable dictionary and history that
/// contain nothing from the user's own dictations.
@MainActor
enum DemoData {
    static func reset() {
        try? FileManager.default.removeItem(at: AppModel.supportDir)
        try? FileManager.default.createDirectory(at: AppModel.supportDir.appendingPathComponent("History"), withIntermediateDirectories: true)
        AppModel.defaults.removePersistentDomain(forName: "app.hushtype.demo")
    }

    static func settings() -> HushtypeSettings {
        var s = HushtypeSettings()
        s.hasOnboarded = true
        s.dictionary = ["Hushtype", "Kubernetes", "PostgreSQL", "Figma", "OKR", "TypeScript", "Claude Code",
                        "SwiftUI", "李想", "王晓雨", "陈默", "Q3 路线图", "增长飞轮", "灰度发布", "A/B 测试",
                        "Notion", "Linear", "Vercel", "React Native", "GraphQL"]
        return s
    }

    static func fill(_ history: HistoryStore) {
        let now = Date()
        let items: [(Double, String, String, String, Double, Double)] = [
            (2, "明天下午四点开会，记得带上 Q3 路线图和上周的 A/B 测试结果。", "嗯明天下午三点不对四点开会然后记得带上那个 Q3 路线图还有上周的 A/B 测试结果", "飞书", 6.2, 1.8),
            (5, "Hi Sarah, thanks for the quick turnaround. I've reviewed the Figma file and left a few comments on the onboarding flow.", "hi sarah thanks for the quick turnaround i've reviewed the figma file and left a few comments on the onboarding flow", "Mail", 8.4, 2.1),
            (9, "帮我把 Kubernetes 的部署脚本改成灰度发布：先放 10% 流量，观察半小时没有报错再全量。", "帮我把 kubernetes 的部署脚本改成那个灰度发布就是先放百分之十的流量观察半个小时没有报错再全量", "Claude Code", 9.7, 2.4),
            (14, "周报：本周完成了支付页重构，转化率提升 3.2%；下周开始做 React Native 版本。", "周报本周完成了支付页重构转化率提升了百分之三点二下周开始做 react native 版本", "Notion", 11.3, 2.6),
            (19, "晚上一起吃火锅吗？我七点左右到。", "晚上一起吃火锅吗我七点左右到", "微信", 3.1, 1.2),
            (24, "把这个 PostgreSQL 查询加上索引，按 created_at 倒序，只取最近 50 条。", "把这个 postgresql 查询加上索引按 created at 倒序只取最近五十条", "Terminal", 5.6, 1.7),
        ]
        for (minutesAgo, text, raw, app, dur, lat) in items.reversed() {
            history.add(HistoryItem(createdAt: now.addingTimeInterval(-minutesAgo * 60), text: text, rawText: raw,
                                    appName: app, bundleID: nil, durationSeconds: dur, latencySeconds: lat, outcome: "ok"))
        }
    }
}
