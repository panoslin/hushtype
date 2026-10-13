import Foundation
import PDFKit
import SQLite3
#if canImport(AppKit)
import AppKit
#endif

/// Bringing existing vocabulary into Hushtype's personal dictionary.
public enum DictionaryImport {
    /// Terms from pasted text or a CSV/TXT file: one per line or separated by commas, tabs, 、 or ；.
    /// Quotes are stripped; a header like "word" / "term" / "词" is ignored; for multi-column CSV rows
    /// the first column is the term.
    public static func parse(_ text: String) -> [String] {
        let headers: Set<String> = ["word", "words", "term", "terms", "phrase", "词", "词条", "单词"]
        var out: [String] = []
        var seen = Set<String>()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // A CSV row with several columns: keep the first one.
            let cells: [Substring]
            if line.contains(",") && line.split(separator: ",").count > 1 && line.contains("\"") {
                cells = [line.split(separator: ",").first ?? Substring(line)]
            } else {
                cells = line.split(whereSeparator: { ",，\t、；;".contains($0) })
            }
            for c in cells {
                let t = c.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’")))
                guard !t.isEmpty, t.count <= 60, !headers.contains(t.lowercased()) else { continue }
                if seen.insert(t.lowercased()).inserted { out.append(t) }
            }
        }
        return out
    }

    public static var typelessDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Typeless/typeless.db")
    }

    public static var typelessInstalled: Bool { FileManager.default.fileExists(atPath: typelessDatabase.path) }

    /// Finished texts from Typeless's local history (read-only). Typeless keeps its dictionary on its
    /// servers, but its finished texts already use the dictionary's spellings — so the terms a user
    /// relies on can be recovered from them.
    public static func typelessTexts(limit: Int = 2000) -> [String] {
        var db: OpaquePointer?
        let uri = "file:\(typelessDatabase.path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var out: [String] = []
        for table in ["history_v2", "history"] {
            var st: OpaquePointer?
            let sql = "SELECT refined_text FROM \(table) WHERE refined_text IS NOT NULL AND refined_text != '' ORDER BY created_at DESC LIMIT \(limit)"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { continue }
            while sqlite3_step(st) == SQLITE_ROW {
                if let c = sqlite3_column_text(st, 0) { out.append(String(cString: c)) }
            }
            sqlite3_finalize(st)
        }
        return out
    }

    /// Text of the notes in a folder (e.g. an Obsidian vault): .md / .txt / .markdown, skipping hidden
    /// folders, attachments and very large files. Markdown syntax that would produce noise (links,
    /// code blocks, URLs, front matter) is stripped.
    public static func folderTexts(_ root: URL, maxFiles: Int = 3000, maxChars: Int = 3_000_000) -> [String] {
        let exts = supportedExtensions
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        var total = 0
        for case let url as URL in e {
            if ["node_modules", ".git", ".obsidian", ".trash"].contains(url.lastPathComponent) { e.skipDescendants(); continue }
            guard exts.contains(url.pathExtension.lowercased()),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 20_000_000,
                  let t = fileText(url) else { continue }
            out.append(t)
            total += t.count
            if out.count >= maxFiles || total >= maxChars { break }
        }
        return out
    }

    /// Files whose text can be read: notes, exports from Feishu / Notion / Google Docs / Word, PDFs.
    public static let supportedExtensions: Set<String> = ["md", "markdown", "txt", "csv", "html", "htm", "rtf", "docx", "doc", "odt", "pdf"]

    /// Plain text of one file, or nil when it can't be read.
    public static func fileText(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return (try? String(contentsOf: url, encoding: .utf8)).map(cleanMarkdown)
        case "txt", "csv":
            return try? String(contentsOf: url, encoding: .utf8)
        case "html", "htm":
            return (try? String(contentsOf: url, encoding: .utf8)).map(htmlToText)
        case "pdf":
            return PDFDocument(url: url)?.string
        case "rtf", "docx", "doc", "odt":
            #if canImport(AppKit)
            let types: [String: NSAttributedString.DocumentType] = ["rtf": .rtf, "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument]
            let t = types[url.pathExtension.lowercased()]!
            return (try? NSAttributedString(url: url, options: [.documentType: t], documentAttributes: nil))?.string
            #else
            return nil
            #endif
        default:
            return nil
        }
    }

    /// Visible text of an HTML page (scripts, styles and tags removed, common entities decoded).
    public static func htmlToText(_ html: String) -> String {
        var t = html
        for p in [#"(?is)<(script|style|noscript|svg)[^>]*>.*?</\1>"#, #"(?s)<!--.*?-->"#] {
            t = t.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|div|li|h[1-6]|tr)>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }

    public enum LinkError: Error, LocalizedError {
        case needsLogin(String), unreadable(String), notFound(String)
        public var errorDescription: String? {
            switch self {
            case .needsLogin(let h): return String(localized: "\(h) 的文档需要登录才能读取：请把文档设为「知道链接的人可查看」，或导出成 Word / Markdown / PDF 后用「从文件导入」")
            case .notFound(let h): return String(localized: "\(h) 上的这个链接打不开：文档不存在，或者没有共享给「知道链接的人」")
            case .unreadable(let h): return String(localized: "读不到 \(h) 的正文（页面靠脚本渲染）：请导出成 Word / Markdown / PDF 后用「从文件导入」")
            }
        }
    }

    /// Text behind a shared document link. Google Docs / Sheets / Slides links shared as "anyone with
    /// the link" are read through their plain-text export; other pages are read as HTML.
    public static func linkText(_ raw: String, session: URLSession = .shared) async throws -> String {
        guard var url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased(),
              url.scheme == "https" else { throw LinkError.unreadable(raw) }
        let parts = url.pathComponents
        if host == "docs.google.com", let i = parts.firstIndex(of: "d"), i + 1 < parts.count {
            let id = parts[i + 1]
            switch parts.dropFirst().first {
            case "document": url = URL(string: "https://docs.google.com/document/d/\(id)/export?format=txt")!
            case "spreadsheets": url = URL(string: "https://docs.google.com/spreadsheets/d/\(id)/export?format=csv")!
            case "presentation": url = URL(string: "https://docs.google.com/presentation/d/\(id)/export/txt")!
            default: break
            }
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let finalHost = http?.url?.host?.lowercased() ?? host
        // Private Google docs redirect to the sign-in page; Feishu / Lark serve a login wall.
        if http?.statusCode == 401 || http?.statusCode == 403 || finalHost.contains("accounts.google.com") {
            throw LinkError.needsLogin(host)
        }
        if let code = http?.statusCode, code >= 400 { throw LinkError.notFound(host) }
        let body = String(decoding: data.prefix(5_000_000), as: UTF8.self)
        let isHTML = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html")
        let text = isHTML ? htmlToText(body) : body
        let meaningful = TextNorm.normalized(text).count
        if meaningful < 40 {
            if ["feishu.cn", "larksuite.com", "larkoffice.com", "notion.so", "notion.site"].contains(where: finalHost.hasSuffix) {
                throw text.contains("登录") || text.lowercased().contains("login") ? LinkError.needsLogin(host) : LinkError.unreadable(host)
            }
            throw LinkError.unreadable(host)
        }
        return text
    }

    static func cleanMarkdown(_ s: String) -> String {
        var t = s
        let patterns = [
            #"(?s)^---\n.*?\n---\n"#,          // front matter
            #"(?s)```.*?```"#,                    // code blocks
            #"`[^`\n]*`"#,                        // inline code
            #"https?://\S+"#,                    // URLs
            #"!?\[\[([^\]|]*\|)?"#, #"\]\]"#,  // wiki links → keep the label
            #"!?\[([^\]]*)\]\([^)]*\)"#,        // [label](url) → label (handled below)
        ]
        for (i, p) in patterns.enumerated() {
            t = t.replacingOccurrences(of: p, with: i == patterns.count - 1 ? "$1" : " ", options: .regularExpression)
        }
        return t
    }

    /// Heuristic candidates: Latin-script names and terms that look deliberate (capitals, camelCase,
    /// acronyms, digits), seen at least twice. Works offline; `llmCandidates` adds Chinese names.
    public static func heuristicCandidates(from texts: [String], minCount: Int = 2) -> [(term: String, count: Int)] {
        var counts: [String: Int] = [:]
        let pattern = try! NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_.-])([A-Z][A-Za-z0-9]*(?:[ .-][A-Z][A-Za-z0-9]+)*|[a-z]+[A-Z][A-Za-z0-9]*|[A-Za-z]*[0-9][A-Za-z0-9-]*[A-Za-z][A-Za-z0-9-]*)(?![A-Za-z0-9_])"#)
        for t in texts {
            let ns = t as NSString
            for m in pattern.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let w = ns.substring(with: m.range(at: 1))
                guard w.count >= 2, !commonWords.contains(w.lowercased()) else { continue }
                counts[w, default: 0] += 1
            }
        }
        return counts.filter { $0.value >= minCount }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// Model-assisted extraction (finds Chinese names and terms too). Sends recent finished texts in
    /// chunks to the rewrite service; returns terms that literally occur in the texts.
    public static func llmCandidates(from texts: [String], rewriter: Rewriter, maxChars: Int = 60_000) async -> [String] {
        var budget = maxChars
        var chunk = ""
        var chunks: [String] = []
        for t in texts {
            guard budget > 0 else { break }
            budget -= t.count
            chunk += t + "\n"
            if chunk.count > 12_000 { chunks.append(chunk); chunk = "" }
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        let system = extractionSystem
        _ = """
        下面是一位用户过去语音输入的文字。找出其中的专有名词和术语：人名、公司名、产品名、地名、项目名、技术术语、缩写，以及中英混写的特殊写法（如 iCloud、JSONL、Claude Code）。
        普通词语不要。按原文写法输出，去重。只输出 JSON 字符串数组。
        """
        var found: [String] = []
        let all = texts.joined(separator: "\n")
        for c in chunks {
            guard let r = try? await rewriter.rewrite(system: system, user: c, source: c, guarded: false),
                  let data = r.text.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { continue }
            for t in arr.map({ $0.trimmingCharacters(in: .whitespaces) }) where !t.isEmpty && t.count <= 40 && all.contains(t) {
                if !found.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { found.append(t) }
            }
        }
        return found
    }

    public static let extractionSystem = """
    下面是一位用户过去语音输入的文字。找出其中的专有名词和术语：人名、公司名、产品名、地名、项目名、技术术语、缩写，以及中英混写的特殊写法（如 iCloud、JSONL、Claude Code）。
    普通词语不要。按原文写法输出，去重。只输出 JSON 字符串数组。
    """

    static let commonWords: Set<String> = [
        "the", "and", "for", "you", "this", "that", "with", "ok", "okay", "yes", "no", "hello", "hi", "so",
        "but", "if", "then", "we", "i", "it", "is", "are", "my", "me", "a", "an", "of", "to", "in", "on", "at",
        "what", "how", "why", "when", "now", "also", "just", "first", "next", "then", "thanks", "thank",
    ]
}
