import AppKit

/// Mở một phiên trong Terminal: `claude --resume <id> [--remote-control "<tên>"]`.
/// Dùng khi cần giao diện terminal đầy đủ, hoặc bật Remote Control (chỉ có ở phiên tương tác).
enum TerminalLauncher {
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func script(folder: String, sessionId: String?, remoteControlName: String?, claude: String,
                       configDir: String? = nil) -> String {
        var cmd = "exec \(q(claude))"
        if let sid = sessionId { cmd += " --resume \(q(sid))" }
        // --remote-control nhận tên tuỳ chọn ngay sau nó — đặt cuối cho chắc.
        if let name = remoteControlName { cmd += " --remote-control \(q(name))" }
        return """
        #!/bin/zsh -l
        \(configDir.map { "export CLAUDE_CONFIG_DIR=\(q($0))" } ?? "unset CLAUDE_CONFIG_DIR")
        cd \(q(folder)) || exit 1
        \(cmd)
        """
    }

    @discardableResult
    static func open(_ r: SessionRunner, remoteControl: Bool) -> Bool {
        r.shutdown() // tránh hai tiến trình cùng ghi một phiên
        let claude = ClaudeLocator.find(custom: AppSettings.shared.claudePath) ?? "claude"
        let text = script(folder: r.folder, sessionId: r.sessionId,
                          remoteControlName: remoteControl ? r.title : nil, claude: claude,
                          configDir: r.profile.envConfigDir)
        guard run(text, name: "open-\(r.id.uuidString.prefix(8))") else { return false }
        r.markOpenedInTerminal(remoteControl: remoteControl)
        return true
    }

    /// Mở Terminal để đăng nhập một hồ sơ (`/login` trong Claude Code).
    @discardableResult
    static func openLogin(_ profile: AccountProfile) -> Bool {
        let claude = ClaudeLocator.find(custom: AppSettings.shared.claudePath) ?? "claude"
        if let dir = profile.envConfigDir {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let text = """
        #!/bin/zsh -l
        \(profile.envConfigDir.map { "export CLAUDE_CONFIG_DIR=\(q($0))" } ?? "unset CLAUDE_CONFIG_DIR")
        cd ~
        echo "DeskPet — hồ sơ: \(profile.name) (\(profile.displayDir))"
        echo "Trong Claude Code: gõ /login để đăng nhập (hoặc /logout để đổi tài khoản), xong gõ /exit."
        echo
        exec \(q(claude))
        """
        return run(text, name: "login-\(profile.id.uuidString.prefix(8))")
    }

    private static func run(_ text: String, name: String) -> Bool {
        let url = SessionManager.supportDir.appendingPathComponent("\(name).command")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            NSLog("DeskPet: không tạo được script Terminal: \(error)")
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    /// Phiên còn đang mở trong một tiến trình `claude --resume <id>` bên ngoài DeskPet không.
    static func isOpenElsewhere(sessionId: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "--", "resume \(sessionId)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
