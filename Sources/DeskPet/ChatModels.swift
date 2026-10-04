import Foundation

struct ChatItem: Identifiable {
    enum Kind { case user, assistant, tool, permission, question, error, info }
    enum Decision { case pending, allowed, denied, cancelled }

    let id = UUID()
    var kind: Kind
    var text: String
    var detail: String = ""
    var icon: String = ""
    var requestId: String = ""
    var decision: Decision = .pending
    /// Diff hiển thị khi Claude xin quyền sửa/ghi file.
    var diff: [DiffLine] = []
    /// Câu hỏi của AskUserQuestion.
    var questions: [AskQuestion] = []
    /// Câu trả lời đã chọn (hiển thị sau khi gửi).
    var answerSummary: String = ""
}

struct AskQuestion: Identifiable {
    struct Option: Identifiable, Hashable {
        var id: String { label }
        let label: String
        let description: String
    }
    var id: String { question }
    let question: String
    let header: String
    let options: [Option]
    let multiSelect: Bool

    static func parse(_ input: [String: Any]) -> [AskQuestion] {
        (input["questions"] as? [[String: Any]] ?? []).map { q in
            AskQuestion(
                question: q["question"] as? String ?? "",
                header: q["header"] as? String ?? "",
                options: (q["options"] as? [[String: Any]] ?? []).map {
                    Option(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
                },
                multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }
}

struct TodoItem: Identifiable {
    enum State: String { case pending, inProgress = "in_progress", completed }
    let id = UUID()
    /// id của task (TaskCreate) — rỗng với TodoWrite.
    var key: String = ""
    var content: String
    var activeForm: String
    var state: State

    static func parse(_ input: [String: Any]) -> [TodoItem] {
        (input["todos"] as? [[String: Any]] ?? []).map {
            TodoItem(content: $0["content"] as? String ?? "",
                     activeForm: $0["activeForm"] as? String ?? "",
                     state: State(rawValue: $0["status"] as? String ?? "") ?? .pending)
        }
    }
}

struct DiffLine: Identifiable {
    enum Kind { case header, context, added, removed, gap }
    let id = UUID()
    let kind: Kind
    let text: String

    /// Diff theo dòng (LCS của Swift) + rút gọn ngữ cảnh quanh chỗ đổi.
    static func make(old: String, new: String, context: Int = 3, limit: Int = 200) -> [DiffLine] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var full: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { full.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
            else if j < b.count, inserted.contains(j) { full.append(DiffLine(kind: .added, text: b[j])); j += 1 }
            else { if i < a.count { full.append(DiffLine(kind: .context, text: a[i])) }; i += 1; j += 1 }
        }
        // Chỉ giữ `context` dòng quanh mỗi thay đổi.
        let changed = full.indices.filter { full[$0].kind != .context }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(full.count - 1, c + context) { keep.insert(k) } }
        var out: [DiffLine] = []
        var last = -1
        for k in full.indices where keep.contains(k) {
            if last >= 0 && k > last + 1 { out.append(DiffLine(kind: .gap, text: "…")) }
            out.append(full[k]); last = k
        }
        return Array(out.prefix(limit))
    }

    static func forTool(name: String, input: [String: Any]) -> [DiffLine] {
        func str(_ k: String) -> String { (input[k] as? String) ?? "" }
        switch name {
        case "Edit":
            return [DiffLine(kind: .header, text: str("file_path"))] + make(old: str("old_string"), new: str("new_string"))
        case "MultiEdit":
            var out = [DiffLine(kind: .header, text: str("file_path"))]
            for (n, e) in (input["edits"] as? [[String: Any]] ?? []).enumerated() {
                if n > 0 { out.append(DiffLine(kind: .gap, text: "…")) }
                out += make(old: e["old_string"] as? String ?? "", new: e["new_string"] as? String ?? "")
            }
            return out
        case "Write":
            let lines = str("content").components(separatedBy: "\n")
            var out = [DiffLine(kind: .header, text: str("file_path") + " (file mới / ghi đè)")]
            out += lines.prefix(120).map { DiffLine(kind: .added, text: $0) }
            if lines.count > 120 { out.append(DiffLine(kind: .gap, text: "… còn \(lines.count - 120) dòng")) }
            return out
        default:
            return []
        }
    }
}

/// Diễn giải một lần gọi tool thành câu tiếng Việt ngắn gọn + icon.
enum ToolDescriber {
    static func describe(name: String, input: [String: Any]) -> (title: String, detail: String, icon: String) {
        func str(_ k: String) -> String { (input[k] as? String) ?? "" }
        func file(_ k: String = "file_path") -> String { (str(k) as NSString).lastPathComponent }

        switch name {
        case "Read": return ("Đọc file", file(), "doc.text")
        case "Write": return ("Ghi file", file(), "square.and.pencil")
        case "Edit", "MultiEdit": return ("Sửa file", file(), "pencil")
        case "NotebookEdit": return ("Sửa notebook", file("notebook_path"), "book")
        case "Bash":
            let cmd = str("command").components(separatedBy: "\n").first ?? ""
            return ("Chạy lệnh", cmd, "terminal")
        case "Glob": return ("Tìm file", str("pattern"), "magnifyingglass")
        case "Grep": return ("Tìm trong code", str("pattern"), "text.magnifyingglass")
        case "WebFetch": return ("Đọc trang web", str("url"), "globe")
        case "WebSearch": return ("Tìm trên web", str("query"), "globe")
        case "Task", "Agent": return ("Giao việc cho agent phụ", str("description"), "person.2")
        case "TodoWrite": return ("Cập nhật danh sách việc", "", "checklist")
        default:
            if name.hasPrefix("mcp__deskpet__") {
                switch name.dropFirst("mcp__deskpet__".count) {
                case "open_url": return ("Mở trang web", str("url"), "safari")
                case "open_app": return ("Mở ứng dụng", str("name"), "app.badge")
                case "play_youtube": return ("Mở YouTube", str("query"), "play.rectangle.fill")
                case "open_search": return ("Tìm trên Google", str("query"), "magnifyingglass")
                case "list_sessions": return ("Xem các phiên", "", "rectangle.stack")
                case "list_profiles": return ("Xem hồ sơ tài khoản", "", "person.2.crop.square.stack")
                case "get_session": return ("Xem phiên", str("session"), "rectangle.stack")
                case "find_projects": return ("Tìm project", str("query"), "folder.badge.questionmark")
                case "list_project_sessions": return ("Xem phiên cũ", (str("folder") as NSString).lastPathComponent, "clock.arrow.circlepath")
                case "start_session": return ("Mở phiên mới", (str("folder") as NSString).lastPathComponent, "plus.rectangle.on.rectangle")
                case "send_to_session": return ("Nhắn cho phiên", str("session"), "paperplane")
                case "focus_session": return ("Mở phiên cho bạn xem", str("session"), "eye")
                case "clear_session": return ("Clear phiên", str("session"), "eraser")
                case "rename_session": return ("Đặt tên phiên", str("name"), "character.cursor.ibeam")
                case "remote_control": return ("Bật Remote Control", str("session"), "dot.radiowaves.left.and.right")
                case "screenshot": return ("Chụp màn hình", "", "camera.viewfinder")
                case "list_windows": return ("Xem cửa sổ đang mở", "", "macwindow.on.rectangle")
                case "mouse_click":
                    let n = (input["count"] as? Int) == 2 ? "Double-click" : (str("button") == "right" ? "Click chuột phải" : "Click")
                    return (n, "(\(input["x"] ?? "?"), \(input["y"] ?? "?"))", "cursorarrow.click")
                case "scroll": return ("Cuộn", "\(input["amount"] ?? "")", "scroll")
                case "type_text": return ("Gõ chữ", String(str("text").prefix(60)), "keyboard")
                case "key_press": return ("Bấm phím", str("keys"), "command")
                case "quit_app": return (input["force"] as? Bool == true ? "Buộc thoát app" : "Thoát app", str("name"), "xmark.app")
                case "run_applescript": return ("Chạy AppleScript", str("script").components(separatedBy: "\n").first ?? "", "applescript")
                case "system_status": return ("Xem trạng thái máy", "", "info.circle")
                case "set_volume": return ("Chỉnh âm lượng", input["level"].map { "\($0)%" } ?? (input["muted"] as? Bool == true ? "tắt tiếng" : "bật tiếng"), "speaker.wave.2")
                case "set_dark_mode": return (input["on"] as? Bool == false ? "Tắt dark mode" : "Bật dark mode", "", "circle.lefthalf.filled")
                case "lock_screen": return ("Khoá màn hình", "", "lock")
                case "sleep_display": return ("Tắt màn hình", "", "display")
                default: break
                }
            }
            if name.hasPrefix("mcp__") {
                // mcp__<server>__<tool>
                let parts = name.components(separatedBy: "__")
                return ("Công cụ MCP", parts.dropFirst().joined(separator: " · "), "puzzlepiece")
            }
            return (name, "", "wrench.and.screwdriver")
        }
    }

    /// Nội dung chi tiết hiển thị trong hộp thoại xin quyền.
    static func permissionDetail(name: String, input: [String: Any]) -> String {
        func str(_ k: String) -> String { (input[k] as? String) ?? "" }
        func clip(_ s: String, _ n: Int = 600) -> String { s.count > n ? String(s.prefix(n)) + "\n…" : s }
        switch name {
        case "Bash":
            let desc = str("description")
            return (desc.isEmpty ? "" : "# \(desc)\n") + "$ " + clip(str("command"))
        case "mcp__deskpet__run_applescript":
            return clip(str("script"))
        case "mcp__deskpet__type_text":
            return clip(str("text"))
        case "Write":
            return str("file_path") + "\n\n" + clip(str("content"), 400)
        case "Edit":
            return str("file_path") + "\n\n- " + clip(str("old_string"), 250) + "\n+ " + clip(str("new_string"), 250)
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
                  let s = String(data: data, encoding: .utf8) else { return "" }
            return clip(s)
        }
    }
}
