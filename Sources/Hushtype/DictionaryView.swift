import AppKit
import HushtypeCore
import SwiftUI
import UniformTypeIdentifiers

/// Candidates waiting for the user to confirm before they enter the dictionary.
@MainActor
final class ImportReview: ObservableObject {
    struct Item: Identifiable, Hashable {
        var id: String { term }
        let term: String
        let detail: String
        var selected = true
    }
    @Published var items: [Item] = []
    @Published var title = ""
    @Published var isPresented = false
    @Published var working: String?
}

struct DictionaryTab: View {
    @ObservedObject var app: AppModel
    @StateObject private var review = ImportReview()
    @Local private var newTerm = ""
    @Local private var query = ""
    @Local private var pasteText = ""
    @Local private var showPaste = false
    @Local private var showLinks = false
    @Local private var linkText = ""

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? app.settings.dictionary : app.settings.dictionary.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        SettingsPage(title: String(localized: "词典"),
                     subtitle: String(localized: "人名、产品名、术语的正确写法。识别出读音相近的词时，会按这里的写法整理。")) {
            // Hundreds of terms: a grouped Form builds every row up front (≈0.5 s for 500 terms), so the
            // list is a LazyVStack that only builds what is on screen, styled like the grouped form.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        TextField("", text: $newTerm, prompt: Text(String(localized: "添加词条，例如 Kubernetes、李想（可一次输入多个，用逗号隔开）")))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(add)
                        Button(String(localized: "添加"), action: add).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                        Menu {
                            Button(String(localized: "从 Typeless 导入…")) { importFromTypeless() }
                                .disabled(!DictionaryImport.typelessInstalled)
                            Button(String(localized: "从知识库 / 笔记文件夹导入…")) { importFromFolder() }
                            Button(String(localized: "从文档链接导入…")) { showLinks = true }
                            Button(String(localized: "从文件导入（Word / PDF / Markdown / CSV / TXT）…")) { importFromFile() }
                            Button(String(localized: "粘贴词表…")) { showPaste = true }
                            Divider()
                            Button(String(localized: "导出为 CSV…")) { exportCSV() }.disabled(app.settings.dictionary.isEmpty)
                        } label: {
                            Text(String(localized: "导入"))
                        }
                        .fixedSize()
                    }
                    .padding(.vertical, 10)
                    if let w = review.working {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(w).foregroundStyle(.secondary) }
                            .padding(.bottom, 8)
                    }
                    Text(String(localized: "\(app.settings.dictionary.count) 个词条"))
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 14).padding(.bottom, 6)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("", text: $query, prompt: Text(String(localized: "搜索词条"))).labelsHidden().textFieldStyle(.plain)
                    }
                    .padding(.vertical, 9)
                    if app.settings.dictionary.isEmpty {
                        Rectangle().fill(DS.line).frame(height: 1)
                        Text(String(localized: "手动添加，或从 Typeless 导入你常用的专有名词。")).foregroundStyle(.secondary)
                            .padding(.vertical, 9)
                    }
                    ForEach(filtered, id: \.self) { term in
                        Rectangle().fill(DS.line).frame(height: 1)
                        TermRow(term: term) { app.settings.dictionary.removeAll { $0 == term } }
                            .padding(.vertical, 9)
                    }
                }
                .padding(.horizontal, 26).padding(.vertical, 12)
            }
        }
        .sheet(isPresented: $review.isPresented) { ImportReviewSheet(review: review, onAdd: addAll) }
        .sheet(isPresented: $showLinks) {
            LinkSheet(text: $linkText) {
                showLinks = false
                importFromLinks(linkText)
            } onCancel: { showLinks = false }
        }
        .sheet(isPresented: $showPaste) {
            PasteSheet(text: $pasteText) {
                showPaste = false
                presentReview(title: String(localized: "粘贴的词表"),
                              terms: DictionaryImport.parse(pasteText).map { ($0, "") })
                pasteText = ""
            } onCancel: { showPaste = false }
        }
    }

    private func add() {
        addAll(DictionaryImport.parse(newTerm))
        newTerm = ""
    }

    private func addAll(_ terms: [String]) {
        for t in terms where !app.settings.dictionary.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            app.settings.dictionary.append(t)
        }
    }

    /// Finding Chinese names needs the cleanup LLM, which means sending note excerpts off the Mac: ask first.
    private func allowCloudScan(_ what: String) -> Bool {
        let a = NSAlert()
        let service = app.cleanupServiceName
        a.messageText = String(localized: "用 \(service) 帮你找专有名词？")
        a.informativeText = String(localized: "会把\(what)的部分文字（最多约 15 万字）发送给 \(service) 识别人名、产品名等，不会保存。\n只在本机识别的话，只能找出英文名词。")
        a.addButton(withTitle: String(localized: "用 \(service) 识别"))
        a.addButton(withTitle: String(localized: "只在本机识别"))
        return a.runModal() == .alertFirstButtonReturn
    }

    private func presentReview(title: String, terms: [(String, String)]) {
        let existing = Set(app.settings.dictionary.map { $0.lowercased() })
        review.items = terms.filter { !existing.contains($0.0.lowercased()) }.map { ImportReview.Item(term: $0.0, detail: $0.1) }
        review.title = title
        review.isPresented = true
    }

    private func importFromTypeless() {
        let backend = app.rewriter.backend != nil && allowCloudScan(String(localized: "Typeless 历史")) ? app.rewriter.backend : nil
        review.working = String(localized: "正在读取 Typeless 的历史记录…")
        Task {
            let texts = await Task.detached { DictionaryImport.typelessTexts() }.value
            var counts: [String: Int] = [:]
            for (t, c) in DictionaryImport.heuristicCandidates(from: texts) { counts[t] = c }
            if backend != nil {
                review.working = String(localized: "正在从 \(texts.count) 条记录里找专有名词…")
                let llm = await DictionaryImport.llmCandidates(from: texts, rewriter: Rewriter(backend: backend, model: .haiku))
                let all = texts.joined(separator: "\n")
                for t in llm where counts[t] == nil { counts[t] = all.components(separatedBy: t).count - 1 }
            }
            review.working = nil
            let sorted = counts.sorted { $0.value > $1.value }.map { ($0.key, String(localized: "出现 \($0.value) 次")) }
            presentReview(title: String(localized: "从 Typeless 找到的词（\(texts.count) 条记录）"), terms: sorted)
        }
    }

    /// Cold-start the dictionary from the user's own notes (an Obsidian vault, a docs folder…).
    private func importFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "扫描")
        panel.message = String(localized: "选择你的知识库或笔记文件夹，Hushtype 会找出里面的专有名词")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let backend = app.rewriter.backend != nil && allowCloudScan(String(localized: "「\(url.lastPathComponent)」里笔记")) ? app.rewriter.backend : nil
        review.working = String(localized: "正在读取 \(url.lastPathComponent) 里的笔记…")
        Task {
            let texts = await Task.detached { DictionaryImport.folderTexts(url) }.value
            var counts: [String: Int] = [:]
            for (t, c) in DictionaryImport.heuristicCandidates(from: texts, minCount: 3) { counts[t] = c }
            if backend != nil {
                review.working = String(localized: "正在从 \(texts.count) 篇笔记里找专有名词（包括中文名字）…")
                let llm = await DictionaryImport.llmCandidates(from: texts.shuffled(), rewriter: Rewriter(backend: backend, model: .haiku),
                                                               maxChars: 150_000)
                let all = texts.joined(separator: "\n")
                for t in llm where counts[t] == nil { counts[t] = max(1, all.components(separatedBy: t).count - 1) }
            }
            review.working = nil
            let sorted = counts.sorted { $0.value > $1.value }.prefix(400).map { ($0.key, String(localized: "出现 \($0.value) 次")) }
            presentReview(title: String(localized: "从「\(url.lastPathComponent)」找到的词（\(texts.count) 篇笔记）"), terms: Array(sorted))
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DictionaryImport.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        // A word list (one term per line / CSV) is taken as is; a document is scanned for names.
        if urls.count == 1, ["csv", "txt"].contains(urls[0].pathExtension.lowercased()),
           let text = try? String(contentsOf: urls[0], encoding: .utf8),
           text.split(separator: "\n").allSatisfy({ $0.count <= 60 }) {
            presentReview(title: urls[0].lastPathComponent, terms: DictionaryImport.parse(text).map { ($0, "") })
            return
        }
        let texts = urls.compactMap(DictionaryImport.fileText)
        scan(texts, title: urls.count == 1 ? urls[0].lastPathComponent : String(localized: "\(urls.count) 个文件"), what: String(localized: "这些文档"))
    }

    private func importFromLinks(_ raw: String) {
        let links = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.hasPrefix("http") }
        guard !links.isEmpty else { return }
        review.working = String(localized: "正在读取 \(links.count) 个链接…")
        Task {
            var texts: [String] = []
            var problems: [String] = []
            for l in links {
                do { texts.append(try await DictionaryImport.linkText(l)) }
                catch { problems.append((error as? LocalizedError)?.errorDescription ?? String(localized: "\(l) 读取失败")) }
            }
            review.working = nil
            if texts.isEmpty {
                presentReview(title: problems.first ?? String(localized: "没有读到内容"), terms: [])
                return
            }
            scan(texts, title: String(localized: "\(texts.count) 个链接") + (problems.isEmpty ? "" : String(localized: "（\(problems.count) 个没读到）")), what: String(localized: "这些文档"))
        }
    }

    /// Shared by file and link import: local English-term pass, then (with consent) Claude for names.
    private func scan(_ texts: [String], title: String, what: String) {
        let backend = app.rewriter.backend != nil && allowCloudScan(what) ? app.rewriter.backend : nil
        review.working = String(localized: "正在从文档里找专有名词…")
        Task {
            var counts: [String: Int] = [:]
            for (t, c) in DictionaryImport.heuristicCandidates(from: texts, minCount: 2) { counts[t] = c }
            if backend != nil {
                let llm = await DictionaryImport.llmCandidates(from: texts, rewriter: Rewriter(backend: backend, model: .haiku),
                                                               maxChars: 150_000)
                let all = texts.joined(separator: "\n")
                for t in llm where counts[t] == nil { counts[t] = max(1, all.components(separatedBy: t).count - 1) }
            }
            review.working = nil
            let sorted = counts.sorted { $0.value > $1.value }.prefix(400).map { ($0.key, String(localized: "出现 \($0.value) 次")) }
            presentReview(title: String(localized: "从\(title)找到的词"), terms: Array(sorted))
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = String(localized: "Hushtype 词典.csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = "word\n" + app.settings.dictionary.map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: "\n")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct ImportReviewSheet: View {
    @ObservedObject var review: ImportReview
    var onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(review.title).font(.headline)
            if review.items.isEmpty {
                Text(String(localized: "没有找到新的词条（已有的不会重复添加）。")).foregroundStyle(.secondary)
            } else {
                Text(String(localized: "勾选要加入词典的词。")).font(.callout).foregroundStyle(.secondary)
                List {
                    ForEach($review.items) { $item in
                        Toggle(isOn: $item.selected) {
                            HStack {
                                Text(item.term)
                                Spacer()
                                Text(item.detail).foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                }
                .frame(minHeight: 300)
                HStack {
                    Button(String(localized: "全选")) { for i in review.items.indices { review.items[i].selected = true } }
                    Button(String(localized: "全不选")) { for i in review.items.indices { review.items[i].selected = false } }
                }
                .buttonStyle(.link)
            }
            HStack {
                Spacer()
                Button(String(localized: "取消")) { dismiss() }
                Button(String(localized: "加入 \(review.items.filter(\.selected).count) 个词")) {
                    onAdd(review.items.filter(\.selected).map(\.term))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(review.items.allSatisfy { !$0.selected })
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// One dictionary term; the delete button appears on hover.
struct TermRow: View {
    var term: String
    var onDelete: () -> Void
    @Local private var hovering = false

    var body: some View {
        HStack {
            Text(term)
            Spacer()
            Button(String(localized: "删除"), action: onDelete).buttonStyle(.borderless).foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
        }
        .contentShape(Rectangle())
        .onHover { if hovering != $0 { hovering = $0 } }
        .contextMenu { Button(String(localized: "删除"), action: onDelete) }
    }
}

struct LinkSheet: View {
    @Binding var text: String
    var onImport: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "从文档链接导入")).font(.headline)
            Text(String(localized: "每行一个链接。支持设为「知道链接的人可查看」的 Google 文档 / 表格 / 幻灯片，以及普通网页。飞书、Notion 等需要登录的文档，请导出成 Word / Markdown / PDF 后用「从文件导入」。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button(String(localized: "取消"), action: onCancel)
                Button(String(localized: "读取"), action: onImport).keyboardShortcut(.defaultAction)
                    .disabled(!text.contains("http"))
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct PasteSheet: View {
    @Binding var text: String
    var onImport: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "粘贴词表")).font(.headline)
            Text(String(localized: "每行一个，或用逗号隔开。可以直接粘贴从 Typeless 词典页复制的内容。"))
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button(String(localized: "取消"), action: onCancel)
                Button(String(localized: "下一步"), action: onImport).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
