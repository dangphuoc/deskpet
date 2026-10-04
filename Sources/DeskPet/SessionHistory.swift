import Foundation

/// Đọc các phiên Claude Code đã lưu trong ~/.claude/projects/<thư mục mã hoá>/<session_id>.jsonl
/// — gồm cả phiên tạo từ DeskPet lẫn phiên chạy `claude` trong terminal.
enum SessionHistory {
    struct Entry: Identifiable {
        let id: String
        let date: Date
        let title: String
    }

    /// Đường dẫn chuẩn hoá (giải symlink, bỏ "/" cuối) — dùng làm khoá và để mã hoá tên thư mục.
    static func normalize(_ folder: String) -> String {
        let path = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
        // realpath giống Claude Code (giữ /private/tmp); resolvingSymlinksInPath lại rút về /tmp.
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Claude Code thay mọi ký tự không phải chữ/số trong đường dẫn bằng "-".
    /// `root` = thư mục cấu hình của hồ sơ (mặc định ~/.claude).
    static func projectDir(for folder: String, root: String? = nil) -> URL {
        let encoded = String(normalize(folder).map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return URL(fileURLWithPath: root ?? NSHomeDirectory() + "/.claude")
            .appendingPathComponent("projects")
            .appendingPathComponent(encoded)
    }

    static func list(folder: String, limit: Int = 40, root: String? = nil) -> [Entry] {
        let fm = FileManager.default
        let dir = projectDir(for: folder, root: root)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let dated = files
            .filter { $0.pathExtension == "jsonl" }
            .map { url -> (URL, Date) in
                let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, d)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        return dated.compactMap { url, date in
            guard let title = title(of: url) else { return nil } // bỏ phiên rỗng
            return Entry(id: url.deletingPathExtension().lastPathComponent, date: date, title: title)
        }
    }

    /// Tiêu đề: tên đặt tay > tên AI đặt > câu hỏi đầu tiên.
    private static func title(of url: URL) -> String? {
        var custom: String?, ai: String?, firstPrompt: String?
        // Chỉ parse JSON những dòng có thể liên quan — file transcript có thể vài MB.
        let keys = ["\"custom-title\"", "\"ai-title\"", "\"type\":\"user\""].map { Data($0.utf8) }
        forEachLine(url, where: { line in
            keys.enumerated().contains { i, k in (i < 2 || firstPrompt == nil) && line.range(of: k) != nil }
        }) { obj in
            switch obj["type"] as? String {
            case "custom-title": custom = obj["customTitle"] as? String ?? custom
            case "ai-title": ai = obj["aiTitle"] as? String ?? ai
            case "user" where firstPrompt == nil:
                if let t = userPrompt(obj) { firstPrompt = t }
            default: break
            }
        }
        let t = custom ?? ai ?? firstPrompt
        return t.map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(90)) }
    }

    /// Dựng lại nội dung chat từ transcript để hiển thị khi resume.
    static func transcript(folder: String, sessionId: String, maxItems: Int = 150, root: String? = nil) -> [ChatItem] {
        let url = projectDir(for: folder, root: root).appendingPathComponent(sessionId + ".jsonl")
        var items: [ChatItem] = []
        forEachLine(url) { obj in
            if obj["isSidechain"] as? Bool == true { return }
            switch obj["type"] as? String {
            case "user":
                if let t = userPrompt(obj) { items.append(ChatItem(kind: .user, text: t)) }
            case "assistant":
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String, !t.isEmpty { items.append(ChatItem(kind: .assistant, text: t)) }
                    case "tool_use":
                        let d = ToolDescriber.describe(name: block["name"] as? String ?? "?",
                                                       input: block["input"] as? [String: Any] ?? [:])
                        items.append(ChatItem(kind: .tool, text: d.title, detail: d.detail, icon: d.icon))
                    default: break
                    }
                }
            default: break
            }
        }
        return Array(items.suffix(maxItems))
    }

    /// Câu người dùng gõ (bỏ tool_result, tin nhắn hệ thống, lệnh slash nội bộ).
    private static func userPrompt(_ obj: [String: Any]) -> String? {
        if obj["isMeta"] as? Bool == true || obj["isSidechain"] as? Bool == true { return nil }
        let content = (obj["message"] as? [String: Any])?["content"]
        var text: String?
        if let s = content as? String {
            text = s
        } else if let blocks = content as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") else { return nil }
        return t
    }

    private static func forEachLine(_ url: URL, where keep: (Data) -> Bool = { _ in true },
                                    _ body: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start, keep(data[start..<end]),
               let obj = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any] {
                body(obj)
            }
            start = end + 1
        }
    }
}

/// Các project đã từng chạy Claude Code (đọc `cwd` từ transcript mới nhất của mỗi thư mục trong ~/.claude/projects).
enum ProjectIndex {
    struct Project: Identifiable {
        var id: String { folder }
        let folder: String
        let lastActivity: Date
        let sessionCount: Int
        var name: String { (folder as NSString).lastPathComponent }
    }

    static func recent(limit: Int = 30, root configRoot: String? = nil) -> [Project] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: configRoot ?? NSHomeDirectory() + "/.claude").appendingPathComponent("projects")
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [Project] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let jsonl = files.filter { $0.pathExtension == "jsonl" }
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
            guard let newest = jsonl.first, let cwd = firstCwd(in: newest.0) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { continue }
            out.append(Project(folder: cwd, lastActivity: newest.1, sessionCount: jsonl.count))
        }
        // Nhiều thư mục mã hoá có thể trỏ về cùng cwd — giữ bản mới nhất.
        var seen = Set<String>()
        return out.sorted { $0.lastActivity > $1.lastActivity }
            .filter { seen.insert($0.folder).inserted }
            .prefix(limit).map { $0 }
    }

    /// Tìm project theo tên (không phân biệt hoa thường, bỏ dấu "-_ ").
    static func search(_ query: String, root: String? = nil) -> [Project] {
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .replacingOccurrences(of: "[-_ .]", with: "", options: .regularExpression)
        }
        let q = norm(query)
        let all = recent(limit: 200, root: root)
        guard !q.isEmpty else { return all }
        return all.filter { norm($0.folder).contains(q) }
    }

    private static func firstCwd(in url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 256 * 1024)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: #""cwd":"((?:[^"\\]|\\.)*)""#, options: .regularExpression) else { return nil }
        let match = String(text[r]).dropFirst(7).dropLast()
        return String(match).replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
