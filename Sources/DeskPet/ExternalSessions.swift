import Foundation

/// Các phiên `claude` đang chạy NGOÀI DeskPet (Terminal, iTerm, VS Code…): dò tiến trình bằng ps/lsof,
/// ghép với transcript mới nhất trong thư mục project để biết tiêu đề và tin nhắn cuối.
/// Gõ được vào phiên trong iTerm / Terminal (AppleScript), có kiểm tra an toàn trước khi gõ — xem `send`.
enum ExternalSessions {
    struct Info: Identifiable {
        let pid: Int
        let folder: String
        let app: String
        /// "/dev/ttys003" — để tìm đúng tab terminal.
        let tty: String?
        let sessionId: String?
        let title: String
        let lastActivity: Date?
        let root: String?
        /// Trạng thái chính xác từ hook (nếu đã bật "Theo dõi phiên ngoài DeskPet").
        var hook: StatusHooks.State? = nil

        var id: Int { pid }
        var folderName: String { (folder as NSString).lastPathComponent }
        /// Gõ thẳng vào được không (chỉ iTerm / Terminal).
        var canType: Bool { tty != nil && ["iterm", "iterm2", "terminal"].contains(app.lowercased()) }

        var isActive: Bool { lastActivity.map { Date().timeIntervalSince($0) < 60 } ?? false }
        var kind: StatusHooks.State.Kind { hook?.kind ?? (isActive ? .working : .idle) }
        /// Có hook thì chính xác; không thì đoán theo lần ghi transcript gần nhất.
        var statusLabel: String { hook?.label ?? (isActive ? "Đang làm" : "Rảnh / chờ bạn") }
    }

    private static let psLine = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*?)\s*$"#)

    static func running() -> [Info] {
        // pid → (ppid, tty, comm)
        var procs: [Int: (ppid: Int, tty: String, comm: String)] = [:]
        for line in run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="]).split(separator: "\n") {
            // "  1983  1633 ttys000  claude" — cột cách nhau bởi nhiều khoảng trắng; comm có thể chứa khoảng trắng.
            let l = String(line)
            guard let m = Self.psLine.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), m.numberOfRanges == 5,
                  let pid = Int(l[Range(m.range(at: 1), in: l)!]), let ppid = Int(l[Range(m.range(at: 2), in: l)!]) else { continue }
            procs[pid] = (ppid, String(l[Range(m.range(at: 3), in: l)!]), String(l[Range(m.range(at: 4), in: l)!]))
        }
        func ancestors(_ pid: Int) -> [String] {
            var out: [String] = [], p = procs[pid]?.ppid ?? 1, guardCount = 0
            while p > 1, let info = procs[p], guardCount < 30 { out.append(info.comm); p = info.ppid; guardCount += 1 }
            return out
        }
        let claudePids = procs.filter { ($0.value.comm as NSString).lastPathComponent == "claude" }.map(\.key).filter { pid in
            let anc = ancestors(pid)
            // Bỏ phiên của chính DeskPet (kể cả trợ lý) và claude con của claude khác.
            return !anc.contains { $0.contains("DeskPet") } && (anc.first.map { ($0 as NSString).lastPathComponent != "claude" } ?? true)
        }.sorted()
        guard !claudePids.isEmpty else { return [] }

        // Thư mục làm việc của từng tiến trình.
        var cwd: [Int: String] = [:]
        var current = 0
        for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", claudePids.map(String.init).joined(separator: ",")])
            .split(separator: "\n") {
            if line.hasPrefix("p") { current = Int(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { cwd[current] = String(line.dropFirst()) }
        }

        let roots = AppSettings.shared.profiles.map(\.rootPath)
        let hooks = StatusHooks.states().values
        var usedPerFolder: [String: Int] = [:]
        return claudePids.compactMap { pid -> Info? in
            guard let folder = cwd[pid] else { return nil }
            let app = ancestors(pid).lazy.compactMap(appName).first ?? "?"
            let tty = procs[pid].map(\.tty).flatMap { $0.hasPrefix("ttys") ? "/dev/" + $0 : nil }
            // Hook ghi đúng pid của claude → biết chắc phiên nào (không phải đoán theo transcript mới nhất).
            if let h = hooks.filter({ $0.pid == pid }).max(by: { $0.time < $1.time }) {
                let root = roots.first { h.transcriptPath.hasPrefix($0 + "/") }
                let entry = SessionHistory.list(folder: folder, limit: 30, root: root).first { $0.id == h.sessionId }
                return Info(pid: pid, folder: folder, app: app, tty: tty, sessionId: h.sessionId,
                            title: entry?.title ?? (folder as NSString).lastPathComponent,
                            lastActivity: entry?.date ?? h.time, root: root, hook: h)
            }
            // Nhiều claude cùng thư mục → gán lần lượt các transcript mới nhất.
            let k = usedPerFolder[folder, default: 0]
            usedPerFolder[folder] = k + 1
            let candidates = roots.flatMap { root in
                SessionHistory.list(folder: folder, limit: k + 1, root: root).map { (entry: $0, root: root) }
            }.sorted { $0.entry.date > $1.entry.date }
            let hit = candidates.count > k ? candidates[k] : nil
            return Info(pid: pid, folder: folder, app: app, tty: tty, sessionId: hit?.entry.id,
                        title: hit?.entry.title ?? (folder as NSString).lastPathComponent,
                        lastActivity: hit?.entry.date, root: hit?.root)
        }
    }

    /// Nội dung gần đây của một phiên ngoài (để trợ lý tóm tắt).
    static func recent(_ s: Info, limit: Int = 12) -> [ChatItem] {
        guard let sid = s.sessionId else { return [] }
        return SessionHistory.transcript(folder: s.folder, sessionId: sid, maxItems: limit, root: s.root)
    }

    /// Đưa tab terminal đang chạy phiên lên trước (khi bấm thông báo của phiên ngoài DeskPet).
    static func focus(app: String, tty: String) {
        let script: String
        switch app.lowercased() {
        case "iterm", "iterm2":
            script = """
            on run argv
              tell application id "com.googlecode.iterm2"
                activate
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if tty of s is (item 1 of argv) then
                        select w
                        select t
                        select s
                        return "ok"
                      end if
                    end repeat
                  end repeat
                end repeat
              end tell
            end run
            """
        case "terminal":
            script = """
            on run argv
              tell application id "com.apple.Terminal"
                activate
                repeat with w in windows
                  repeat with t in tabs of w
                    if tty of t is (item 1 of argv) then
                      set selected of t to true
                      set index of w to 1
                      return "ok"
                    end if
                  end repeat
                end repeat
              end tell
            end run
            """
        default:
            return
        }
        DispatchQueue.global().async { _ = runScript(script, args: [tty]) }
    }

    /// Gõ `text` rồi Enter vào tab terminal đang chạy phiên (iTerm / Terminal), như người dùng tự gõ.
    ///
    /// Enter là phím nguy hiểm: nếu tab đang hiện bảng xin quyền của Claude Code, Enter chọn luôn "Yes";
    /// nếu claude đã thoát / bị Ctrl-Z, chữ gõ vào thành lệnh shell. Nên trước khi gõ phải chắc:
    /// (1) claude còn chạy và đang chiếm terminal, (2) không có bảng xin quyền / bảng chọn đang mở.
    static func send(_ text: String, to s: Info) -> Result<String, DeskPetMCP.ToolError> {
        guard let tty = s.tty else { return .failure(.init(text: "Không xác định được tab terminal của phiên này.")) }
        let app = s.app.lowercased()
        guard ["iterm", "iterm2", "terminal"].contains(app) else {
            return .failure(.init(text: "Phiên đang chạy trong \(s.app) — DeskPet chỉ gõ được vào iTerm và Terminal. Nhờ người dùng thoát phiên đó rồi start_session với resume_session_id = \(s.sessionId ?? "?") để điều khiển từ DeskPet."))
        }
        if let problem = foregroundProblem(pid: s.pid) {
            return .failure(.init(text: "Không gõ vào phiên \(s.title): \(problem) Gõ lúc này có thể thành lệnh shell."))
        }
        let blocked = "Phiên \(s.title) đang chờ bạn cho phép hoặc chọn đáp án — DeskPet không gõ vào để tránh tự bấm Enter chọn \"Yes\". Mở tab trong \(s.app) để tự xem và trả lời (focus_session)."
        if let h = StatusHooks.states().values.filter({ $0.pid == s.pid }).max(by: { $0.time < $1.time }), h.kind == .permission {
            return .failure(.init(text: blocked))
        }
        switch screenText(app: app, tty: tty) {
        case .success(let screen):
            if showsChoiceMenu(screen) { return .failure(.init(text: blocked)) }
        case .failure(let err):
            return .failure(.init(text: "Không đọc được màn hình tab \(tty) để kiểm tra trước khi gõ: \(err.text)"))
        }
        // TUI của Claude Code gửi khi gặp Enter — xuống dòng giữa chừng sẽ gửi sớm, nên gộp thành một dòng.
        let line = text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        let script: String
        switch s.app.lowercased() {
        case "iterm", "iterm2":
            // Gõ chữ và Enter tách nhau: gõ một lèo kèm Enter dễ bị Claude Code coi là dán (không gửi).
            script = """
            on run argv
              set ttyPath to item 1 of argv
              set msg to item 2 of argv
              tell application id "com.googlecode.iterm2"
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if tty of s is ttyPath then
                        tell s to write text msg newline no
                        delay 0.4
                        tell s to write text (ASCII character 13) newline no
                        return "ok"
                      end if
                    end repeat
                  end repeat
                end repeat
              end tell
              return "notfound"
            end run
            """
        case "terminal":
            script = """
            on run argv
              set ttyPath to item 1 of argv
              set msg to item 2 of argv
              tell application id "com.apple.Terminal"
                repeat with w in windows
                  repeat with t in tabs of w
                    if tty of t is ttyPath then
                      do script msg in t
                      return "ok"
                    end if
                  end repeat
                end repeat
              end tell
              return "notfound"
            end run
            """
        default:
            return .failure(.init(text: "Không hỗ trợ \(s.app)."))
        }
        let (status, out, err) = runScript(script, args: [tty, line])
        if status == 0 && out == "ok" { return .success("Đã gõ vào phiên \(s.title) trong \(s.app): \(line)") }
        if out == "notfound" { return .failure(.init(text: "Không tìm thấy tab \(tty) trong \(s.app).")) }
        return .failure(.init(text: "Không gõ được vào \(s.app): \(err.isEmpty ? out : err). Có thể cần cho DeskPet quyền điều khiển \(s.app) (System Settings → Privacy & Security → Automation)."))
    }

    // MARK: - Kiểm tra an toàn trước khi gõ

    /// nil = claude còn chạy và đang chiếm terminal (chính nó hoặc lệnh con của nó ở foreground).
    /// Ngược lại trả về lý do không được gõ.
    static func foregroundProblem(pid: Int) -> String? {
        // tpgid = nhóm tiến trình đang ở foreground của terminal.
        var procs: [Int: (ppid: Int, pgid: Int, tpgid: Int, stat: String)] = [:]
        for line in run("/bin/ps", ["-axo", "pid=,ppid=,pgid=,tpgid=,stat="]).split(separator: "\n") {
            let c = line.split(separator: " ", omittingEmptySubsequences: true)
            guard c.count >= 5, let p = Int(c[0]), let pp = Int(c[1]), let g = Int(c[2]), let t = Int(c[3]) else { continue }
            procs[p] = (pp, g, t, String(c[4]))
        }
        guard let me = procs[pid] else { return "phiên Claude (pid \(pid)) đã thoát." }
        if me.stat.hasPrefix("T") { return "phiên Claude đang bị tạm dừng (Ctrl-Z)." }
        guard me.tpgid > 0 else { return "phiên Claude không còn gắn với tab terminal." }
        if me.pgid == me.tpgid { return nil }
        // Foreground là nhóm khác: chỉ chấp nhận nếu là tiến trình con/cháu của claude (vd. lệnh Bash Claude đang chạy).
        func descends(_ p: Int) -> Bool {
            var cur = p, n = 0
            while cur > 1, n < 40, let info = procs[cur] {
                if cur == pid { return true }
                cur = info.ppid; n += 1
            }
            return false
        }
        if procs.contains(where: { $0.value.pgid == me.tpgid && descends($0.key) }) { return nil }
        return "terminal đang ở tiến trình khác (có thể Claude đã thoát về shell)."
    }

    /// Có bảng chọn của Claude Code đang mở không (xin quyền "Do you want to…", AskUserQuestion…).
    /// Dấu hiệu ở phần cuối màn hình: dòng đang chọn "❯ 1." hoặc chân bảng "Esc to cancel".
    static func showsChoiceMenu(_ screen: String) -> Bool {
        let tail = screen.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(30)
        return tail.contains { line in
            // Bảng có thể vẽ trong khung: "│ ❯ 1. Yes".
            line.range(of: #"^[│┃|╭╰\s]*[❯›]\s*\d+\.\s"#, options: .regularExpression) != nil
                || line.localizedCaseInsensitiveContains("Esc to cancel")
        }
    }

    /// Nội dung đang hiện trên tab (iTerm: `contents` của session; Terminal: `contents` của tab).
    private static func screenText(app: String, tty: String) -> Result<String, DeskPetMCP.ToolError> {
        let script: String
        if app == "terminal" {
            script = """
            on run argv
              tell application id "com.apple.Terminal"
                repeat with w in windows
                  repeat with t in tabs of w
                    if tty of t is (item 1 of argv) then return "ok:" & (contents of t)
                  end repeat
                end repeat
              end tell
              return "notfound"
            end run
            """
        } else {
            script = """
            on run argv
              tell application id "com.googlecode.iterm2"
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if tty of s is (item 1 of argv) then return "ok:" & (contents of s)
                    end repeat
                  end repeat
                end repeat
              end tell
              return "notfound"
            end run
            """
        }
        let (status, out, err) = runScript(script, args: [tty])
        if status == 0, out.hasPrefix("ok:") { return .success(String(out.dropFirst(3))) }
        if out == "notfound" { return .failure(.init(text: "không thấy tab \(tty).")) }
        return .failure(.init(text: (err.isEmpty ? out : err) + " (có thể cần cho DeskPet quyền điều khiển app terminal trong Privacy & Security → Automation)."))
    }

    private static func runScript(_ script: String, args: [String]) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"] + args
        let inPipe = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = inPipe
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        inPipe.fileHandleForWriting.write(Data(script.utf8))
        try? inPipe.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let trim = { (d: Data) in String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (p.terminationStatus, trim(o), trim(e))
    }

    /// "/Applications/iTerm.app/Contents/MacOS/iTerm2" → "iTerm".
    private static func appName(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
