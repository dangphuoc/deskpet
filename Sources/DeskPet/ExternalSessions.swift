import Foundation

/// Các phiên `claude` đang chạy NGOÀI DeskPet (Terminal, iTerm, VS Code…): dò tiến trình bằng ps/lsof,
/// ghép với transcript mới nhất trong thư mục project để biết tiêu đề và tin nhắn cuối.
/// Chỉ để xem — DeskPet không gõ được vào các phiên này.
enum ExternalSessions {
    struct Info {
        let pid: Int
        let folder: String
        let app: String
        /// "/dev/ttys003" — để tìm đúng tab terminal.
        let tty: String?
        let sessionId: String?
        let title: String
        let lastActivity: Date?
        let root: String?

        var isActive: Bool { lastActivity.map { Date().timeIntervalSince($0) < 60 } ?? false }
        var statusLabel: String { isActive ? "Đang làm" : "Rảnh / chờ bạn" }
    }

    static func running() -> [Info] {
        // pid → (ppid, tty, comm)
        var procs: [Int: (ppid: Int, tty: String, comm: String)] = [:]
        for line in run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="]).split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            procs[pid] = (ppid, String(parts[2]), String(parts[3]))
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
        var usedPerFolder: [String: Int] = [:]
        return claudePids.compactMap { pid -> Info? in
            guard let folder = cwd[pid] else { return nil }
            let app = ancestors(pid).lazy.compactMap(appName).first ?? "?"
            let tty = procs[pid].map(\.tty).flatMap { $0.hasPrefix("ttys") ? "/dev/" + $0 : nil }
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

    /// Gõ `text` rồi Enter vào tab terminal đang chạy phiên (iTerm / Terminal), như người dùng tự gõ.
    static func send(_ text: String, to s: Info) -> Result<String, DeskPetMCP.ToolError> {
        guard let tty = s.tty else { return .failure(.init(text: "Không xác định được tab terminal của phiên này.")) }
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
            return .failure(.init(text: "Phiên đang chạy trong \(s.app) — DeskPet chỉ gõ được vào iTerm và Terminal. Nhờ người dùng thoát phiên đó rồi start_session với resume_session_id = \(s.sessionId ?? "?") để điều khiển từ DeskPet."))
        }
        let (status, out, err) = runScript(script, args: [tty, line])
        if status == 0 && out == "ok" { return .success("Đã gõ vào phiên \(s.title) trong \(s.app): \(line)") }
        if out == "notfound" { return .failure(.init(text: "Không tìm thấy tab \(tty) trong \(s.app).")) }
        return .failure(.init(text: "Không gõ được vào \(s.app): \(err.isEmpty ? out : err). Có thể cần cho DeskPet quyền điều khiển \(s.app) (System Settings → Privacy & Security → Automation)."))
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
