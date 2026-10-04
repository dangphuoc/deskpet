import Foundation

/// Một phiên Claude Code chạy trong DeskPet.
///
/// Mỗi phiên giữ một tiến trình sống liên tục:
///   claude -p --input-format stream-json --output-format stream-json --verbose
///          --include-partial-messages --permission-prompt-tool stdio --permission-mode default
///          [--resume <session_id>]
/// Mỗi tin nhắn là một dòng JSON ghi vào stdin; mỗi lượt kết thúc bằng message `result`,
/// tiến trình vẫn sống để lượt sau phản hồi nhanh. Rảnh lâu thì đóng stdin cho tiến trình tự thoát,
/// lần nhắn sau sẽ chạy lại với --resume.
///
/// Xin quyền: khi Claude muốn dùng tool chưa được phép, CLI gửi `control_request` (`can_use_tool`)
/// và chờ app trả `control_response` với `behavior: allow|deny` — giao thức Agent SDK dùng.
final class SessionRunner: ObservableObject, Identifiable {
    enum Status: Equatable {
        case idle, working, needsPermission, needsAnswer, done, error

        var label: String {
            switch self {
            case .idle: return "Rảnh"
            case .working: return "Đang làm"
            case .needsPermission: return "Chờ cho phép"
            case .needsAnswer: return "Chờ trả lời"
            case .done: return "Xong"
            case .error: return "Lỗi"
            }
        }
        var needsAttention: Bool { self == .needsPermission || self == .needsAnswer }
    }

    enum Event { case started, permission(String), question(String), finished(success: Bool), changed }

    let id: UUID
    let isAssistant: Bool
    @Published var title: String
    @Published private(set) var folder: String
    @Published private(set) var sessionId: String?
    /// Hồ sơ tài khoản Claude Code mà phiên chạy bằng.
    @Published private(set) var profileId: UUID
    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var statusText = "Sẵn sàng"
    @Published private(set) var todos: [TodoItem] = []
    @Published private(set) var lastActivity: Date
    @Published var unread = false
    /// Phiên đang được mở trong Terminal (có thể kèm Remote Control) — DeskPet không gõ trùng vào.
    @Published private(set) var openedInTerminal = false
    @Published private(set) var remoteControlOn = false

    var onEvent: ((SessionRunner, Event) -> Void)?
    /// Tham số bổ sung khi khởi chạy (phiên trợ lý dùng để gắn MCP DeskPet + system prompt).
    var extraArgs: () -> [String] = { [] }
    var model: () -> String = { "" }
    enum AutoDecision { case allow, deny(String) }
    /// Tự quyết yêu cầu quyền không cần hỏi (trợ lý: theo mức quyền điều khiển máy). nil = hỏi người dùng.
    var autoDecide: (_ tool: String, _ input: [String: Any]) -> AutoDecision? = { _, _ in nil }

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var stderrTail = ""
    private var turnActive = false
    private var userStopped = false
    private var turnHadText = false
    private var idleTimer: Timer?
    /// Tin gửi tới khi phiên đang bận — chạy lần lượt sau mỗi lượt (như gõ tiếp trong terminal).
    private var queued: [(text: String, byVoice: Bool)] = []
    /// Lượt gần nhất do người dùng NÓI (giọng nói) hay gõ — chỉ đọc to câu trả lời khi nói.
    private(set) var lastTurnByVoice = false
    /// Lượt hiện tại là /clear → xong thì dọn khung chat.
    private var clearing = false
    /// Vị trí trong `items` lúc bắt đầu lượt gần nhất — để lấy đúng câu trả lời của lượt đó.
    private var turnStartIndex = 0
    private static let idleShutdown: TimeInterval = 15 * 60

    private var currentMessageId: String?
    private var streamedMessageIds = Set<String>()
    private var seenToolIds = Set<String>()
    private var openAssistantIndex: Int?
    private var pendingInputs: [String: [String: Any]] = [:]
    /// Input của các tool_use gần đây (để ghép với kết quả, vd. activeForm của TaskCreate).
    private var toolInputs: [String: [String: Any]] = [:]
    /// Tool nội bộ không cần hiện thành dòng trong chat.
    private static let hiddenTools: Set<String> = ["ToolSearch", "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList",
                                                   "TaskGet", "AskUserQuestion"]

    init(id: UUID = UUID(), title: String, folder: String, sessionId: String?, isAssistant: Bool = false,
         lastActivity: Date = Date(), profileId: UUID = AppSettings.shared.defaultProfileId) {
        self.id = id
        self.profileId = profileId
        self.title = title
        self.folder = folder
        self.sessionId = sessionId
        self.isAssistant = isAssistant
        self.lastActivity = lastActivity
    }

    var profile: AccountProfile { AppSettings.shared.profile(profileId) }
    var isBusy: Bool { turnActive }
    var isRunning: Bool { process?.isRunning == true }
    var folderName: String { (folder as NSString).lastPathComponent }
    var lastUserText: String? { items.last(where: { $0.kind == .user })?.text }
    var lastAssistantText: String? { items.last(where: { $0.kind == .assistant })?.text }
    /// Toàn bộ câu trả lời (text) của lượt gần nhất.
    var lastTurnReply: String {
        guard turnStartIndex <= items.count else { return "" }
        return items[turnStartIndex...].filter { $0.kind == .assistant }.map(\.text).joined(separator: "\n")
    }
    var pendingRequest: ChatItem? {
        items.last { ($0.kind == .permission || $0.kind == .question) && $0.decision == .pending }
    }

    // MARK: - Lịch sử

    /// Nạp lại nội dung chat từ transcript của Claude Code (khi mở app hoặc resume phiên cũ).
    func loadHistory() {
        guard let sid = sessionId, items.isEmpty else { return }
        items = SessionHistory.transcript(folder: folder, sessionId: sid, root: profile.rootPath)
        if !items.isEmpty { items.append(ChatItem(kind: .info, text: "— Lịch sử phiên \(sid.prefix(8))… —")) }
    }

    /// Chuyển phiên sang session_id khác (resume một phiên cũ) hoặc phiên mới (nil).
    func switchTo(sessionId newId: String?, folder newFolder: String? = nil, profileId newProfile: UUID? = nil) {
        guard !turnActive else { return }
        shutdown()
        if let newFolder { folder = newFolder }
        if let newProfile { profileId = newProfile }
        sessionId = newId
        items = []
        todos = []
        if newId != nil { loadHistory() } else { items = [ChatItem(kind: .info, text: "Phiên mới trong \(folderName)")] }
        status = .idle
        statusText = "Sẵn sàng"
        onEvent?(self, .changed)
    }

    // MARK: - Gửi / dừng

    /// Gửi nguyên văn như gõ trong Claude Code — tin thường hoặc lệnh slash (/clear, /compact, /model …).
    func send(_ raw: String, byVoice: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if turnActive {
            queued.append((text, byVoice))
            items.append(ChatItem(kind: .info, text: "⏳ Xếp hàng: \(text.prefix(80))"))
            return
        }
        if openedInTerminal {
            if let sid = sessionId, TerminalLauncher.isOpenElsewhere(sessionId: sid) {
                items.append(ChatItem(kind: .error, text: "Phiên này đang mở trong Terminal\(remoteControlOn ? " (Remote Control)" : ""). Nhắn ở đó, hoặc đóng Terminal rồi nhắn lại ở đây."))
                onEvent?(self, .changed)
                return
            }
            openedInTerminal = false
            remoteControlOn = false
            // Nạp lại lịch sử mới nhất (gồm cả phần đã làm trong Terminal / từ điện thoại).
            items = []
            loadHistory()
            items.append(ChatItem(kind: .info, text: "Terminal đã đóng — tiếp tục phiên trong DeskPet"))
        }
        if text == "/clear" { clearing = true }
        if text.hasPrefix("/rename ") {
            let name = text.dropFirst("/rename ".count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { title = name }
        }
        if process?.isRunning != true {
            guard launch() else { return }
        }
        idleTimer?.invalidate()
        items.append(ChatItem(kind: .user, text: byVoice ? "🎤 " + text : text))
        lastTurnByVoice = byVoice
        turnStartIndex = items.count
        resetTurnState()
        turnActive = true
        setStatus(.working, "Đang suy nghĩ…")
        lastActivity = Date()
        onEvent?(self, .started)
        writeJSON(["type": "user", "message": ["role": "user", "content": text]])
    }

    /// Dừng lượt đang chạy (giống Esc trong terminal) — tiến trình vẫn sống.
    func stop() {
        guard turnActive else { return }
        userStopped = true
        writeJSON(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
        // Nếu CLI không phản hồi thì cắt hẳn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.turnActive, self.userStopped else { return }
            self.process?.interrupt()
        }
    }

    /// Đóng tiến trình (phiên vẫn còn, lần nhắn sau sẽ --resume).
    func shutdown() {
        idleTimer?.invalidate()
        queued.removeAll()
        guard let p = process else { return }
        try? stdin?.close()
        stdin = nil
        process = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
    }

    // MARK: - Quyết định của người dùng

    func decide(requestId: String, allow: Bool) {
        guard let idx = items.firstIndex(where: { $0.requestId == requestId && $0.decision == .pending }) else { return }
        let input = pendingInputs.removeValue(forKey: requestId) ?? [:]
        respond(requestId, allow ? ["behavior": "allow", "updatedInput": input]
                                 : ["behavior": "deny", "message": "Người dùng đã từ chối thao tác này."])
        items[idx].decision = allow ? .allowed : .denied
        afterDecision()
    }

    /// Trả lời AskUserQuestion: `answers` là {câu hỏi: nhãn đã chọn} (nhiều lựa chọn nối bằng ", ").
    func answer(requestId: String, answers: [String: String]) {
        guard let idx = items.firstIndex(where: { $0.requestId == requestId && $0.decision == .pending }) else { return }
        var input = pendingInputs.removeValue(forKey: requestId) ?? [:]
        input["answers"] = answers
        respond(requestId, ["behavior": "allow", "updatedInput": input])
        items[idx].decision = .allowed
        items[idx].answerSummary = items[idx].questions.map { "\($0.header.isEmpty ? $0.question : $0.header): \(answers[$0.question] ?? "—")" }
            .joined(separator: " · ")
        afterDecision()
    }

    private func respond(_ requestId: String, _ response: [String: Any]) {
        writeJSON(["type": "control_response",
                   "response": ["subtype": "success", "request_id": requestId, "response": response]])
    }

    private func afterDecision() {
        if pendingRequest == nil { setStatus(.working, "Đang làm…") }
        onEvent?(self, .changed)
    }

    func markOpenedInTerminal(remoteControl: Bool) {
        openedInTerminal = true
        remoteControlOn = remoteControl
        items.append(ChatItem(kind: .info, text: remoteControl
            ? "📡 Đã mở trong Terminal với Remote Control — điều khiển tiếp từ app Claude (điện thoại / claude.ai)"
            : "Đã mở trong Terminal"))
        setStatus(.idle, remoteControl ? "Đang mở ở Terminal · Remote Control" : "Đang mở ở Terminal")
        onEvent?(self, .changed)
    }

    /// Người dùng đã xem phiên — bỏ trạng thái "Xong" chưa đọc.
    func markSeen() {
        unread = false
        if status == .done { setStatus(.idle, "Sẵn sàng") }
    }

    // MARK: - Tiến trình

    private func launch() -> Bool {
        guard let claude = ClaudeLocator.find(custom: AppSettings.shared.claudePath) else {
            fail("Không tìm thấy `claude`. Hãy cài Claude Code hoặc chỉ đường dẫn trong Cài đặt.")
            return false
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            fail("Thư mục làm việc không tồn tại: \(folder)")
            return false
        }

        var args = ["-p",
                    "--input-format", "stream-json",
                    "--output-format", "stream-json",
                    "--verbose",
                    "--include-partial-messages",
                    "--permission-prompt-tool", "stdio",
                    "--permission-mode", "default"]
        if let sid = sessionId { args += ["--resume", sid] }
        let m = model().trimmingCharacters(in: .whitespaces)
        if !m.isEmpty { args += ["--model", m] }
        args += extraArgs()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        p.environment = ClaudeLocator.environment(configDir: profile.envConfigDir)

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        buffer.removeAll()
        stderrTail = ""
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.ingest(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + s).suffix(2000))
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.processEnded(proc) }
        }

        do { try p.run() } catch {
            fail("Không chạy được claude: \(error.localizedDescription)")
            return false
        }
        process = p
        stdin = inPipe.fileHandleForWriting
        return true
    }

    private func processEnded(_ proc: Process) {
        let wasCurrent = proc === process
        if wasCurrent { process = nil; stdin = nil }
        guard turnActive else { return } // thoát khi rảnh (hết giờ / shutdown) là bình thường
        for i in items.indices where (items[i].kind == .permission || items[i].kind == .question) && items[i].decision == .pending {
            items[i].decision = .cancelled
        }
        if userStopped {
            items.append(ChatItem(kind: .info, text: "Đã dừng."))
            finishTurn(success: true)
        } else {
            let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.contains("No conversation found") { sessionId = nil }
            items.append(ChatItem(kind: .error, text: "claude thoát với mã \(proc.terminationStatus)" + (tail.isEmpty ? "" : ":\n\(tail)")))
            finishTurn(success: false)
        }
    }

    // MARK: - Đọc stream

    private func resetTurnState() {
        userStopped = false
        turnHadText = false
        currentMessageId = nil
        openAssistantIndex = nil
        streamedMessageIds.removeAll()
        seenToolIds.removeAll()
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ msg: [String: Any]) {
        let type = msg["type"] as? String ?? ""
        let isSubagent = msg["parent_tool_use_id"] != nil && !(msg["parent_tool_use_id"] is NSNull)
        if type != "stream_event" { lastActivity = Date() }

        switch type {
        case "system":
            if msg["subtype"] as? String == "init", let sid = msg["session_id"] as? String, sid != sessionId {
                sessionId = sid
                onEvent?(self, .changed)
            }

        case "stream_event":
            guard !isSubagent, let ev = msg["event"] as? [String: Any] else { return }
            switch ev["type"] as? String {
            case "message_start":
                currentMessageId = (ev["message"] as? [String: Any])?["id"] as? String
                openAssistantIndex = nil
            case "content_block_delta":
                if let delta = ev["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    if let id = currentMessageId { streamedMessageIds.insert(id) }
                    appendAssistantText(t)
                }
            default: break
            }

        case "assistant":
            guard !isSubagent, let message = msg["message"] as? [String: Any] else { return }
            let mid = message["id"] as? String ?? ""
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if !streamedMessageIds.contains(mid), let t = block["text"] as? String, !t.isEmpty {
                        appendAssistantText(t)
                    }
                case "tool_use":
                    let tid = block["id"] as? String ?? UUID().uuidString
                    guard !seenToolIds.contains(tid) else { continue }
                    seenToolIds.insert(tid)
                    let name = block["name"] as? String ?? "?"
                    let input = block["input"] as? [String: Any] ?? [:]
                    toolInputs[tid] = input
                    if name == "TodoWrite" { todos = TodoItem.parse(input) }
                    if Self.hiddenTools.contains(name) { continue } // hiện ở bảng việc / thẻ câu hỏi
                    let d = ToolDescriber.describe(name: name, input: input)
                    items.append(ChatItem(kind: .tool, text: d.title, detail: d.detail, icon: d.icon))
                    openAssistantIndex = nil
                    if pendingRequest == nil { setStatus(.working, d.title + "…") }
                default: break
                }
            }

        case "user":
            guard !isSubagent else { return }
            if let r = msg["tool_use_result"] as? [String: Any] { applyTaskResult(r, msg) }
            if pendingRequest == nil, turnActive { setStatus(.working, "Đang suy nghĩ…") }

        case "control_request":
            handleControlRequest(msg)

        case "control_cancel_request":
            if let rid = msg["request_id"] as? String,
               let idx = items.firstIndex(where: { $0.requestId == rid && $0.decision == .pending }) {
                items[idx].decision = .cancelled
                pendingInputs[rid] = nil
                afterDecision()
            }

        case "result":
            if let sid = msg["session_id"] as? String, sid != sessionId { sessionId = sid }
            let isError = msg["is_error"] as? Bool ?? false
            if isError {
                let text = (msg["result"] as? String) ?? (msg["subtype"] as? String) ?? "Lỗi không rõ"
                // CLI thường in lỗi thành text trả lời rồi lặp lại trong result — chỉ hiện một lần.
                if let i = openAssistantIndex, i < items.count, items[i].kind == .assistant,
                   items[i].text.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    items[i].kind = .error
                } else {
                    items.append(ChatItem(kind: .error, text: text))
                }
            } else if !turnHadText, let r = msg["result"] as? String, !r.isEmpty {
                appendAssistantText(r)
            }
            if userStopped { items.append(ChatItem(kind: .info, text: "Đã dừng.")) }
            finishTurn(success: !isError)

        default:
            break
        }
    }

    private func handleControlRequest(_ msg: [String: Any]) {
        guard let rid = msg["request_id"] as? String,
              let req = msg["request"] as? [String: Any] else { return }
        guard req["subtype"] as? String == "can_use_tool" else {
            writeJSON(["type": "control_response",
                       "response": ["subtype": "error", "request_id": rid, "error": "DeskPet không hỗ trợ yêu cầu này"]])
            return
        }
        let name = req["tool_name"] as? String ?? "?"
        let input = req["input"] as? [String: Any] ?? [:]
        pendingInputs[rid] = input
        openAssistantIndex = nil

        if name == "AskUserQuestion" {
            let qs = AskQuestion.parse(input)
            items.append(ChatItem(kind: .question, text: qs.first?.question ?? "Claude hỏi bạn", requestId: rid, questions: qs))
            setStatus(.needsAnswer, "Đang chờ bạn trả lời")
            onEvent?(self, .question(qs.first?.question ?? ""))
            return
        }

        let d = ToolDescriber.describe(name: name, input: input)
        let summary = "\(d.title)\(d.detail.isEmpty ? "" : " — \(d.detail)")"
        switch autoDecide(name, input) {
        case .allow?:
            pendingInputs[rid] = nil
            respond(rid, ["behavior": "allow", "updatedInput": input])
            return
        case .deny(let message)?:
            pendingInputs[rid] = nil
            respond(rid, ["behavior": "deny", "message": message])
            items.append(ChatItem(kind: .info, text: "Đã chặn: \(summary) (đang tắt trong Cài đặt → Điều khiển máy)"))
            return
        case nil:
            break
        }
        items.append(ChatItem(kind: .permission,
                              text: "Claude muốn: \(summary)",
                              detail: ToolDescriber.permissionDetail(name: name, input: input),
                              icon: d.icon,
                              requestId: rid,
                              diff: DiffLine.forTool(name: name, input: input)))
        setStatus(.needsPermission, "Đang chờ bạn cho phép")
        onEvent?(self, .permission(summary))
    }

    /// Cập nhật bảng việc từ kết quả TaskCreate / TaskUpdate / TaskList (Claude Code mới thay TodoWrite bằng các tool này).
    private func applyTaskResult(_ r: [String: Any], _ msg: [String: Any]) {
        let toolUseId = ((msg["message"] as? [String: Any])?["content"] as? [[String: Any]])?
            .first { $0["type"] as? String == "tool_result" }?["tool_use_id"] as? String
        let input = toolUseId.flatMap { toolInputs[$0] } ?? [:]

        if let task = r["task"] as? [String: Any], let key = task["id"] as? String {
            let subject = task["subject"] as? String ?? input["subject"] as? String ?? ""
            if !todos.contains(where: { $0.key == key }) {
                todos.append(TodoItem(key: key, content: subject, activeForm: input["activeForm"] as? String ?? "", state: .pending))
            }
        } else if let key = r["taskId"] as? String, let i = todos.firstIndex(where: { $0.key == key }) {
            if let to = (r["statusChange"] as? [String: Any])?["to"] as? String {
                if to == "deleted" { todos.remove(at: i); return }
                todos[i].state = TodoItem.State(rawValue: to) ?? todos[i].state
            }
            if let subject = input["subject"] as? String { todos[i].content = subject }
            if let active = input["activeForm"] as? String { todos[i].activeForm = active }
        } else if let tasks = r["tasks"] as? [[String: Any]] {
            todos = tasks.map { t in
                let key = t["id"] as? String ?? ""
                return TodoItem(key: key, content: t["subject"] as? String ?? "",
                                activeForm: todos.first { $0.key == key }?.activeForm ?? "",
                                state: TodoItem.State(rawValue: t["status"] as? String ?? "") ?? .pending)
            }
        }
    }

    private func appendAssistantText(_ t: String) {
        turnHadText = true
        if let i = openAssistantIndex, i < items.count, items[i].kind == .assistant {
            items[i].text += t
        } else {
            items.append(ChatItem(kind: .assistant, text: t))
            openAssistantIndex = items.count - 1
        }
        if pendingRequest == nil { setStatus(.working, "Đang trả lời…") }
    }

    private func finishTurn(success: Bool) {
        guard turnActive else { return }
        turnActive = false
        userStopped = false
        lastActivity = Date()
        if success {
            unread = true
            setStatus(.done, "Xong rồi!")
        } else {
            setStatus(.error, "Có lỗi xảy ra")
        }
        if clearing {
            clearing = false
            if success {
                items = [ChatItem(kind: .info, text: "Đã /clear — bắt đầu ngữ cảnh mới")]
                todos = []
            }
        }
        onEvent?(self, .finished(success: success))
        if !queued.isEmpty {
            let next = queued.removeFirst()
            DispatchQueue.main.async { [weak self] in self?.send(next.text, byVoice: next.byVoice) }
            return
        }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleShutdown, repeats: false) { [weak self] _ in
            guard let self, !self.turnActive else { return }
            self.shutdown()
        }
    }

    private func fail(_ message: String) {
        items.append(ChatItem(kind: .error, text: message))
        setStatus(.error, "Có lỗi xảy ra")
        onEvent?(self, .finished(success: false))
    }

    private func setStatus(_ s: Status, _ text: String) {
        if status != s { status = s }
        statusText = text
    }

    private func writeJSON(_ obj: [String: Any]) {
        guard let h = stdin,
              var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        do { try h.write(contentsOf: data) } catch {
            items.append(ChatItem(kind: .error, text: "Không gửi được dữ liệu cho claude: \(error.localizedDescription)"))
        }
    }

    /// Chỉ dùng cho `--snapshot`.
    func loadPreview(_ preview: [ChatItem], status: Status, todos: [TodoItem] = []) {
        items = preview
        self.status = status
        statusText = status.label
        self.todos = todos
    }
}
