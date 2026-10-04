import Foundation

enum ClaudeLocator {
    /// PATH của login shell — app GUI chỉ có PATH tối giản.
    static let loginPath: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }()

    static func find(custom: String) -> String? {
        let fm = FileManager.default
        let c = (custom as NSString).expandingTildeInPath
        if !c.isEmpty { return fm.isExecutableFile(atPath: c) ? c : nil }
        let home = NSHomeDirectory()
        let dirs = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
            + loginPath.split(separator: ":").map(String.init)
        for d in dirs {
            let path = d + "/claude"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// `configDir`: CLAUDE_CONFIG_DIR của hồ sơ tài khoản (nil = hồ sơ mặc định ~/.claude).
    static func environment(configDir: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir } else { env["CLAUDE_CONFIG_DIR"] = nil }
        let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = loginPath.isEmpty ? base : loginPath + ":" + base
        // Nếu DeskPet được mở từ bên trong một phiên Claude Code, đừng để claude con tưởng mình là tiến trình lồng.
        env["CLAUDECODE"] = nil
        env["CLAUDE_CODE_ENTRYPOINT"] = nil
        return env
    }
}
