import AppKit

/// `DeskPet --mcp` — MCP server (stdio, JSON-RPC theo dòng) mà phiên trợ lý của Claude Code khởi chạy.
/// Tool vô hại: mở web/app/YouTube, đọc trạng thái phiên (state.json do app ghi), gửi lệnh điều phối
/// phiên cho app qua DistributedNotificationCenter.
enum DeskPetMCP {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--mcp") else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let reply = handle(msg) { send(reply) }
        }
        exit(0)
    }

    private static func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        print(s)
    }

    private static func handle(_ msg: [String: Any]) -> [String: Any]? {
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        guard id != nil else { return nil } // notification (vd. notifications/initialized)
        func result(_ r: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id!, "result": r] }

        switch method {
        case "initialize":
            let params = msg["params"] as? [String: Any]
            return result([
                "protocolVersion": params?["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "deskpet", "version": "1.0"],
            ])
        case "ping":
            return result([String: Any]())
        case "tools/list":
            return result(["tools": tools + ComputerControl.tools])
        case "tools/call":
            let params = msg["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            if let g = ControlGroup.of(tool: name) {
                // Kiểm tra lại ở đây phòng khi luật allow của Claude Code cho chạy thẳng không qua DeskPet.
                if ControlPolicy.mode(g) == .off {
                    return result(["content": [["type": "text", "text": ControlPolicy.offMessage(g)]], "isError": true])
                }
                let (content, isError) = ComputerControl.call(name, args)
                return result(["content": content, "isError": isError])
            }
            let (text, isError) = call(name, args)
            return result(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return ["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    // MARK: - Tool definitions

    private static func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }
    private static let str: [String: Any] = ["type": "string"]

    /// Tool cơ bản (vô hại) — phiên trợ lý được chạy không cần hỏi. Tool điều khiển máy theo Cài đặt.
    static var baseToolNames: [String] { tools.compactMap { $0["name"] as? String } }

    private static let tools: [[String: Any]] = [
        ["name": "open_url", "description": "Mở một trang web (http/https/mailto) trong trình duyệt mặc định.",
         "inputSchema": schema(["url": str], required: ["url"])],
        ["name": "open_app", "description": "Mở một ứng dụng macOS theo tên, vd. \"Mail\", \"Calendar\", \"Spotify\", \"Google Chrome\".",
         "inputSchema": schema(["name": str], required: ["name"])],
        ["name": "play_youtube", "description": "Tìm trên YouTube và mở video đầu tiên khớp từ khoá (để nghe nhạc, xem video).",
         "inputSchema": schema(["query": str], required: ["query"])],
        ["name": "open_search", "description": "Mở trang kết quả tìm kiếm Google cho người dùng xem.",
         "inputSchema": schema(["query": str], required: ["query"])],
        ["name": "list_sessions", "description": "Liệt kê mọi phiên Claude Code trên máy: phiên trong DeskPet (tiêu đề, thư mục, trạng thái Rảnh/Đang làm/Chờ cho phép/Chờ trả lời/Xong/Lỗi, việc đang chờ, tin nhắn cuối) và phiên đang chạy ngoài DeskPet trong Terminal/iTerm/IDE (chỉ xem được).",
         "inputSchema": schema([:])],
        ["name": "get_session", "description": "Xem nội dung gần đây (tối đa 12 mục) và todo của một phiên — kể cả phiên chạy ngoài DeskPet. `session` là id hoặc một phần tiêu đề/tên thư mục; bỏ trống = phiên hiện tại.",
         "inputSchema": schema(["session": str])],
        ["name": "list_profiles", "description": "Liệt kê các hồ sơ tài khoản Claude Code (tên, thư mục cấu hình, hồ sơ mặc định).",
         "inputSchema": schema([:])],
        ["name": "find_projects", "description": "Tìm thư mục project từng chạy Claude Code theo tên (bỏ trống để liệt kê gần đây). `profile`: tên hồ sơ tài khoản (bỏ trống = mặc định).",
         "inputSchema": schema(["query": str, "profile": str])],
        ["name": "list_project_sessions", "description": "Liệt kê các phiên Claude Code cũ của một thư mục (id, thời gian, tiêu đề) để có thể tiếp tục. `profile`: tên hồ sơ (bỏ trống = mặc định).",
         "inputSchema": schema(["folder": str, "profile": str], required: ["folder"])],
        ["name": "start_session", "description": "Mở một phiên Claude Code mới trong DeskPet để làm việc trong `folder` (đường dẫn tuyệt đối, hoặc đúng tên thư mục project như service-bank-v3_clone). `prompt` là yêu cầu gửi ngay (tuỳ chọn). Đặt `continue_latest`=true để nối tiếp phiên gần nhất của thư mục, hoặc `resume_session_id` để tiếp tục phiên cụ thể. Phiên mới vẫn hỏi người dùng trước khi sửa file/chạy lệnh.",
         "inputSchema": schema(["folder": str, "prompt": str, "title": str, "resume_session_id": str,
                                "continue_latest": ["type": "boolean"],
                                "profile": ["type": "string", "description": "Tên hồ sơ tài khoản Claude Code (bỏ trống = mặc định)"]],
                               required: ["folder"])],
        ["name": "send_to_session", "description": "Gõ thay người dùng vào một phiên Claude Code: tin nhắn thường hoặc lệnh slash như /compact, /model sonnet, /cost, /context, /rename <tên>, /<skill>. `session`: id, một phần tiêu đề hoặc tên thư mục project; bỏ trống = phiên hiện tại. Tự xử lý: phiên trong DeskPet → gõ vào đó (đang bận thì xếp hàng); phiên đang chạy trong iTerm/Terminal → gõ thẳng vào tab đó; chưa có phiên nào chạy cho project đó → mở phiên trong DeskPet nối tiếp phiên gần nhất rồi gửi.",
         "inputSchema": schema(["session": str, "message": str], required: ["message"])],
        ["name": "focus_session", "description": "Mở bảng phiên của DeskPet tới phiên chỉ định để người dùng xem / cho phép. Bỏ trống `session` = phiên hiện tại.",
         "inputSchema": schema(["session": str])],
        ["name": "clear_session", "description": "Giống /clear trong terminal: phiên bắt đầu lại với ngữ cảnh sạch (lịch sử cũ vẫn lưu, resume được). Bỏ trống `session` = phiên hiện tại.",
         "inputSchema": schema(["session": str])],
        ["name": "remote_control", "description": "Bật Remote Control cho một phiên: mở phiên đó trong Terminal (claude --resume … --remote-control <tên phiên>) để người dùng điều khiển tiếp từ app Claude trên điện thoại / claude.ai. Bỏ trống `session` = phiên hiện tại.",
         "inputSchema": schema(["session": str])],
        ["name": "rename_session", "description": "Đặt tên hiển thị cho phiên. Bỏ trống `session` = phiên hiện tại.",
         "inputSchema": schema(["session": str, "name": str], required: ["name"])],
    ]

    // MARK: - Tool implementations

    private static func call(_ name: String, _ a: [String: Any]) -> (String, Bool) {
        func s(_ k: String) -> String { (a[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch name {
        case "open_url":
            guard let url = URL(string: s("url")), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else {
                return ("Chỉ mở được link http, https hoặc mailto.", true)
            }
            NSWorkspace.shared.open(url)
            return ("Đã mở \(url.absoluteString)", false)

        case "open_app":
            let appName = s("name")
            guard !appName.isEmpty else { return ("Thiếu tên app.", true) }
            let ok = run("/usr/bin/open", ["-a", appName])
            return ok ? ("Đã mở \(appName)", false) : ("Không tìm thấy app \"\(appName)\".", true)

        case "play_youtube":
            let q = s("query")
            let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            let searchURL = URL(string: "https://www.youtube.com/results?search_query=\(enc)")!
            if let vid = firstYouTubeVideo(searchURL), let watch = URL(string: "https://www.youtube.com/watch?v=\(vid)") {
                NSWorkspace.shared.open(watch)
                return ("Đang phát trên YouTube: \(watch.absoluteString)", false)
            }
            NSWorkspace.shared.open(searchURL)
            return ("Đã mở kết quả tìm kiếm YouTube cho \"\(q)\".", false)

        case "open_search":
            let q = s("query").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            NSWorkspace.shared.open(URL(string: "https://www.google.com/search?q=\(q)")!)
            return ("Đã mở Google.", false)

        case "list_sessions":
            let sessions = loadSessions()
            let external = externalSection()
            if sessions.isEmpty { return ("Chưa có phiên nào trong DeskPet." + external, false) }
            let current = loadState()["current_session_id"] as? String
            let lines = sessions.map { d -> String in
                let mark = (d["id"] as? String) == current ? " ← phiên hiện tại" : ""
                var line = "- [\(d["status"] ?? "?")] \(d["title"] ?? "") — \(d["folder"] ?? "") (id: \(d["id"] ?? ""), hoạt động: \(d["last_activity"] ?? ""))\(mark)"
                if let w = d["waiting_for"] as? String { line += "\n    chờ: \(w)" }
                if let last = (d["recent_messages"] as? [[String: String]])?.last(where: { $0["role"] == "assistant" })?["text"] {
                    line += "\n    trả lời cuối: \(last.prefix(200))"
                }
                return line
            }
            return ("Phiên trong DeskPet:\n" + lines.joined(separator: "\n") + external, false)

        case "get_session":
            if let d = findSession(s("session")) { return (json(d), false) }
            if let e = findExternal(s("session")) {
                let items = ExternalSessions.recent(e).map { "[\($0.kind)] \($0.text.prefix(600))\($0.detail.isEmpty ? "" : " — \($0.detail)")" }
                return ("""
                Phiên chạy ngoài DeskPet (trong \(e.app), chỉ xem được): \(e.title)
                Thư mục: \(e.folder) · trạng thái: \(e.statusLabel) · claude_session_id: \(e.sessionId ?? "?")
                Nội dung gần đây:
                \(items.isEmpty ? "(chưa có)" : items.joined(separator: "\n"))
                """, false)
            }
            return ("Không tìm thấy phiên \"\(s("session"))\".", true)

        case "list_profiles":
            let st = AppSettings.shared
            return (st.profiles.map { "- \($0.name) (\($0.displayDir))\($0.id == st.defaultProfileId ? " ← mặc định" : "")" }
                .joined(separator: "\n"), false)

        case "find_projects":
            guard let profile = profile(s("profile")) else { return ("Không có hồ sơ \"\(s("profile"))\". Dùng list_profiles.", true) }
            let found = ProjectIndex.search(s("query"), root: profile.rootPath).prefix(15)
            if found.isEmpty { return ("Không tìm thấy project nào khớp.", false) }
            let f = RelativeDateTimeFormatter()
            return (found.map { "- \($0.folder) (\($0.sessionCount) phiên, hoạt động \(f.localizedString(for: $0.lastActivity, relativeTo: Date())))" }
                .joined(separator: "\n"), false)

        case "list_project_sessions":
            guard let profile = profile(s("profile")) else { return ("Không có hồ sơ \"\(s("profile"))\". Dùng list_profiles.", true) }
            let list = SessionHistory.list(folder: s("folder"), limit: 15, root: profile.rootPath)
            if list.isEmpty { return ("Thư mục này chưa có phiên Claude Code nào.", false) }
            let iso = ISO8601DateFormatter()
            return (list.map { "- \($0.id) · \(iso.string(from: $0.date)) · \($0.title)" }.joined(separator: "\n"), false)

        case "start_session":
            guard let profile = profile(s("profile")) else { return ("Không có hồ sơ \"\(s("profile"))\". Dùng list_profiles.", true) }
            let folder: String
            switch resolveFolder(s("folder"), root: profile.rootPath) {
            case .success(let f): folder = f
            case .failure(let msg): return (msg.text, true)
            }
            let id = UUID().uuidString
            var cmd: [String: Any] = ["action": "start_session", "id": id, "folder": folder, "profile_id": profile.id.uuidString]
            for k in ["prompt", "title", "resume_session_id"] where !s(k).isEmpty { cmd[k] = s(k) }
            if a["continue_latest"] as? Bool == true { cmd["continue_latest"] = true }
            post(cmd)
            return ("Đã mở phiên mới (id: \(id)) trong \(folder), tài khoản: \(profile.name)." + (s("prompt").isEmpty ? "" : " Đã gửi yêu cầu."), false)

        case "send_to_session":
            guard !s("message").isEmpty else { return ("Thiếu message.", true) }
            guard let d = findSession(s("session")), let id = d["id"] as? String else {
                // Phiên đang chạy ngoài DeskPet (iTerm/Terminal) → gõ thẳng vào tab đó.
                if let e = findExternal(s("session")) {
                    switch ExternalSessions.send(s("message"), to: e) {
                    case .success(let msg): return (msg, false)
                    case .failure(let err): return (err.text, true)
                    }
                }
                // Không có phiên nào chạy cho thư mục đó → mở trong DeskPet, nối tiếp phiên gần nhất, gửi luôn.
                guard !s("session").isEmpty, let profile = profile("") else {
                    return ("Không tìm thấy phiên \"\(s("session"))\".", true)
                }
                switch resolveFolder(s("session"), root: profile.rootPath) {
                case .success(let folder):
                    let newId = UUID().uuidString
                    post(["action": "start_session", "id": newId, "folder": folder, "profile_id": profile.id.uuidString,
                          "continue_latest": true, "prompt": s("message")])
                    return ("Không có phiên nào đang chạy ở \(folder) — đã mở phiên trong DeskPet (nối tiếp phiên gần nhất, id: \(newId)) và gửi: \(s("message"))", false)
                case .failure(let msg):
                    return ("Không tìm thấy phiên đang chạy \"\(s("session"))\". \(msg.text)", true)
                }
            }
            post(["action": "send_to_session", "id": id, "message": s("message")])
            let busy = d["busy"] as? Bool == true
            return (busy ? "Phiên \(d["title"] ?? id) đang bận — đã xếp hàng, sẽ chạy khi xong lượt hiện tại."
                         : "Đã gõ vào phiên \(d["title"] ?? id): \(s("message"))", false)

        case "focus_session":
            guard let d = findSession(s("session")), let id = d["id"] as? String else {
                return ("Không tìm thấy phiên \"\(s("session"))\".", true)
            }
            post(["action": "focus_session", "id": id])
            return ("Đã mở phiên \(d["title"] ?? id) cho người dùng.", false)

        case "clear_session":
            guard let d = findSession(s("session")), let id = d["id"] as? String else {
                return ("Không tìm thấy phiên \"\(s("session"))\".", true)
            }
            post(["action": "clear_session", "id": id])
            return ("Đã clear phiên \(d["title"] ?? id) — tin nhắn tiếp theo bắt đầu ngữ cảnh mới.", false)

        case "remote_control":
            guard let d = findSession(s("session")), let id = d["id"] as? String else {
                return ("Không tìm thấy phiên \"\(s("session"))\".", true)
            }
            post(["action": "remote_control", "id": id])
            return ("Đã mở phiên \(d["title"] ?? id) trong Terminal với Remote Control. Người dùng điều khiển tiếp từ app Claude trên điện thoại hoặc claude.ai; trong lúc đó DeskPet không gõ vào phiên này.", false)

        case "rename_session":
            guard !s("name").isEmpty else { return ("Thiếu tên mới.", true) }
            guard let d = findSession(s("session")), let id = d["id"] as? String else {
                return ("Không tìm thấy phiên \"\(s("session"))\".", true)
            }
            post(["action": "rename_session", "id": id, "name": s("name")])
            return ("Đã đổi tên phiên \(d["title"] ?? id) thành \"\(s("name"))\".", false)

        default:
            return ("Tool không tồn tại: \(name)", true)
        }
    }

    // MARK: - Helpers

    struct ToolError: Error { let text: String }

    /// Đường dẫn tuyệt đối / ~ → dùng luôn; chỉ có tên (vd. "service-bank-v3_clone") → tìm project trùng tên.
    /// Tên hồ sơ rỗng → hồ sơ mặc định; không tìm thấy → nil.
    private static func profile(_ name: String) -> AccountProfile? {
        name.isEmpty ? AppSettings.shared.defaultProfile : AppSettings.shared.profile(named: name)
    }

    private static func resolveFolder(_ raw: String, root: String? = nil) -> Result<String, ToolError> {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            return .failure(ToolError(text: "Thiếu `folder`. Dùng find_projects để lấy đường dẫn tuyệt đối của project."))
        }
        func isDir(_ p: String) -> Bool {
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }
        if input.hasPrefix("/") || input.hasPrefix("~") {
            let path = SessionHistory.normalize(input)
            return isDir(path) ? .success(path) : .failure(ToolError(text: "Thư mục không tồn tại: \(path)."))
        }
        let projects = ProjectIndex.search(input, root: root)
        let exact = projects.filter { $0.name.lowercased() == input.lowercased() }
        if exact.count == 1 { return .success(exact[0].folder) }
        if exact.isEmpty && projects.count == 1 { return .success(projects[0].folder) }
        let list = (exact.isEmpty ? projects : exact).prefix(8).map { "- \($0.folder)" }.joined(separator: "\n")
        return .failure(ToolError(text: list.isEmpty
            ? "Không tìm thấy project tên \"\(input)\". Hỏi người dùng đường dẫn đầy đủ."
            : "\"\(input)\" khớp nhiều project, hãy chọn đường dẫn đầy đủ:\n\(list)"))
    }

    private static func loadSessions() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: SessionManager.stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return obj["sessions"] as? [[String: Any]] ?? []
    }

    private static func loadState() -> [String: Any] {
        guard let data = try? Data(contentsOf: SessionManager.stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// `key` rỗng / "current" / "hiện tại" → phiên hiện tại.
    private static func findSession(_ key: String) -> [String: Any]? {
        let all = loadSessions()
        let k0 = key.lowercased()
        if k0.isEmpty || ["current", "hiện tại", "phiên này", "phiên đó", "nó"].contains(k0) {
            guard let cur = loadState()["current_session_id"] as? String else { return nil }
            return all.first { ($0["id"] as? String) == cur }
        }
        if let exact = all.first(where: { ($0["id"] as? String)?.lowercased() == key.lowercased() }) { return exact }
        let k = key.lowercased()
        return all.first { (($0["title"] as? String) ?? "").lowercased().contains(k) }
            ?? all.first { (($0["folder"] as? String) ?? "").lowercased().contains(k) }
    }

    /// Phần "phiên ngoài DeskPet" của list_sessions.
    private static func externalSection() -> String {
        let ext = ExternalSessions.running()
        guard !ext.isEmpty else { return "\n\nKhông có phiên Claude Code nào chạy ngoài DeskPet." }
        let f = RelativeDateTimeFormatter()
        let lines = ext.map { e -> String in
            var line = "- [\(e.statusLabel)] \(e.title) — \(e.folder) (trong \(e.app), pid \(e.pid)"
            if let d = e.lastActivity { line += ", hoạt động \(f.localizedString(for: d, relativeTo: Date()))" }
            line += ")"
            if let last = ExternalSessions.recent(e, limit: 6).last(where: { $0.kind == .assistant })?.text {
                line += "\n    trả lời cuối: \(last.prefix(200))"
            }
            return line
        }
        return "\n\nPhiên Claude Code chạy ngoài DeskPet (send_to_session gõ được vào phiên trong iTerm/Terminal; IDE thì chỉ xem):\n"
            + lines.joined(separator: "\n")
    }

    private static func findExternal(_ key: String) -> ExternalSessions.Info? {
        let k = key.lowercased()
        guard !k.isEmpty else { return nil }
        let all = ExternalSessions.running()
        return all.first { $0.sessionId?.lowercased() == k }
            ?? all.first { $0.title.lowercased().contains(k) }
            ?? all.first { $0.folder.lowercased().contains(k) }
    }

    private static func post(_ cmd: [String: Any]) {
        var cmd = cmd
        // MCP được chạy bởi claude con của một DeskPet cụ thể (thừa hưởng DESKPET_SUPPORT_DIR) — chỉ gửi cho DeskPet đó.
        cmd["target"] = SessionManager.supportDir.path
        guard let data = try? JSONSerialization.data(withJSONObject: cmd),
              let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            SessionManager.commandNotification, object: json, userInfo: nil, deliverImmediately: true)
    }

    private static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func firstYouTubeVideo(_ url: URL) -> String? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("vi,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let sem = DispatchSemaphore(value: 0)
        var html = ""
        URLSession.shared.dataTask(with: req) { data, _, _ in
            html = String(decoding: data ?? Data(), as: UTF8.self)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        guard let r = html.range(of: #""videoId":"[A-Za-z0-9_-]{11}""#, options: .regularExpression) else { return nil }
        return String(html[r].dropFirst(11).dropLast())
    }
}
