import Foundation

/// Hook Claude Code báo trạng thái phiên cho DeskPet — để biết chính xác phiên chạy NGOÀI DeskPet
/// (iTerm, Terminal…) đang làm, chờ cho phép hay đã xong.
///
/// Cài vào `hooks` trong settings.json của từng hồ sơ: SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd.
/// Mỗi sự kiện chạy một script shell nhỏ ghi `<support>/hooks/<session_id>.json` (ghi đè, chỉ giữ sự kiện mới nhất).
/// Script không bao giờ chặn hay làm lỗi Claude Code: thiếu script/thư mục thì thoát 0, phiên của DeskPet thì bỏ qua.
enum StatusHooks {
    static let events = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"]
    /// Dấu nhận biết hook của DeskPet trong settings.json (để gỡ đúng, không đụng hook khác).
    private static let marker = "#deskpet-status-hook"

    static var dir: URL { SessionManager.supportDir.appendingPathComponent("hooks") }
    static var scriptURL: URL { SessionManager.supportDir.appendingPathComponent("hook.sh") }

    private static func command(_ event: String) -> String {
        // exec: script thay chỗ shell nên $PPID trong script = pid của claude.
        "f='\(scriptURL.path)'; [ -x \"$f\" ] && exec \"$f\" \(event); exit 0 \(marker)"
    }

    private static var script: String {
        """
        #!/bin/sh
        # DeskPet — báo trạng thái phiên Claude Code. Chỉ ghi file, luôn thoát 0, không chặn Claude.
        [ -n "$DESKPET_SESSION" ] && exit 0
        DIR='\(dir.path)'
        [ -d "$DIR" ] || exit 0
        INPUT=$(cat)
        SID=$(printf '%s' "$INPUT" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null)
        case "$SID" in ""|*[!A-Za-z0-9-]*) exit 0;; esac
        TMP="$DIR/.$SID.$$"
        printf '{"event":"%s","time":%s,"pid":%s,"input":%s}\\n' "$1" "$(date +%s)" "$PPID" "$INPUT" > "$TMP" \\
          && mv -f "$TMP" "$DIR/$SID.json"
        rm -f "$TMP"
        exit 0
        """
    }

    private static func settingsURL(_ root: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent("settings.json")
    }

    /// Đã cài cho mọi hồ sơ chưa.
    static func isInstalled(roots: [String]) -> Bool {
        !roots.isEmpty && roots.allSatisfy { root in
            guard let data = try? Data(contentsOf: settingsURL(root)),
                  let s = String(data: data, encoding: .utf8) else { return false }
            return s.contains(marker)
        }
    }

    /// Bật: ghi script + thêm hook vào settings.json của từng hồ sơ. Tắt: gỡ hook (giữ nguyên hook khác) + xoá script.
    /// Trả về lỗi (nếu có) để hiện trong Cài đặt.
    static func setEnabled(_ on: Bool, roots: [String]) -> String? {
        let fm = FileManager.default
        if on {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            } catch { return "Không ghi được script hook: \(error.localizedDescription)" }
        }
        var errors: [String] = []
        for root in roots {
            if let e = update(root: root, add: on) { errors.append(e) }
        }
        if !on {
            try? fm.removeItem(at: scriptURL)
            try? fm.removeItem(at: dir)
        }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private static func update(root: String, add: Bool) -> String? {
        let fm = FileManager.default
        let url = settingsURL(root)
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return "\(url.path) không phải JSON hợp lệ — không sửa."
            }
            obj = o
            // Sao lưu một lần trước lần sửa đầu tiên.
            let backup = url.appendingPathExtension("deskpet-backup")
            if !fm.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        } else if !add {
            return nil
        }

        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries = entries.compactMap { entry in
                let inner = entry["hooks"] as? [[String: Any]] ?? []
                let kept = inner.filter { !(($0["command"] as? String) ?? "").contains(marker) }
                if kept.isEmpty && !inner.isEmpty { return nil }
                var e = entry
                e["hooks"] = kept
                return e
            }
            if add {
                entries.append(["hooks": [["type": "command", "command": command(event), "timeout": 5]]])
            }
            hooks[event] = entries.isEmpty ? nil : entries
        }
        obj["hooks"] = hooks.isEmpty ? nil : hooks

        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return "Không ghi được \(url.path): \(error.localizedDescription)"
        }
    }

    // MARK: - Đọc trạng thái

    struct State {
        enum Kind { case working, permission, idle, done, ended }
        let sessionId: String
        let event: String
        let time: Date
        let pid: Int
        let cwd: String
        let message: String
        let transcriptPath: String

        var isPermissionNotice: Bool {
            event == "Notification" && (message.lowercased().contains("permission")
                || message.lowercased().contains("approval"))
        }

        /// Transcript được ghi sau thông báo xin quyền → người dùng đã trả lời, Claude đang làm tiếp.
        private var transcriptMovedOn: Bool {
            guard let m = (try? FileManager.default.attributesOfItem(atPath: transcriptPath))?[.modificationDate] as? Date
            else { return false }
            return m.timeIntervalSince(time) > 2
        }

        var kind: Kind {
            switch event {
            case "UserPromptSubmit": return .working
            case "Notification": return isPermissionNotice ? (transcriptMovedOn ? .working : .permission) : .idle
            case "Stop": return .done
            case "SessionEnd": return .ended
            default: return .idle
            }
        }

        var label: String {
            switch kind {
            case .working: return "Đang làm"
            case .permission: return "Chờ cho phép"
            case .idle: return "Rảnh / chờ bạn"
            case .done: return "Xong"
            case .ended: return "Đã đóng"
            }
        }

        var processAlive: Bool { pid > 1 && kill(pid_t(pid), 0) == 0 }
    }

    /// Trạng thái mới nhất của các phiên (theo session_id), bỏ file cũ hơn 2 ngày.
    static func states() -> [String: State] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [:] }
        var out: [String: State] = [:]
        for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(mod) > 2 * 86400 { try? fm.removeItem(at: url); continue }
            guard let data = try? Data(contentsOf: url),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let input = o["input"] as? [String: Any] ?? [:]
            let sid = url.deletingPathExtension().lastPathComponent
            out[sid] = State(sessionId: sid,
                             event: o["event"] as? String ?? "",
                             time: Date(timeIntervalSince1970: (o["time"] as? NSNumber)?.doubleValue ?? 0),
                             pid: (o["pid"] as? NSNumber)?.intValue ?? 0,
                             cwd: input["cwd"] as? String ?? "",
                             message: input["message"] as? String ?? "",
                             transcriptPath: input["transcript_path"] as? String ?? "")
        }
        return out
    }
}

/// Theo dõi file trạng thái từ hook (trong app): báo pet / bong bóng / thông báo khi phiên ngoài DeskPet
/// cần cho phép hoặc làm xong.
final class ExternalMonitor {
    struct Event { let state: StatusHooks.State; let kind: StatusHooks.State.Kind }

    var onChange: ((Event) -> Void)?
    private(set) var attention: [StatusHooks.State] = []
    private(set) var working: [StatusHooks.State] = []
    private var lastKinds: [String: StatusHooks.State.Kind] = [:]
    private var primed = false
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        guard FileManager.default.fileExists(atPath: StatusHooks.dir.path) else {
            attention = []; working = []; lastKinds = [:]
            return
        }
        let live = StatusHooks.states().values.filter(\.processAlive)
        attention = live.filter { $0.kind == .permission }
        working = live.filter { $0.kind == .working }
        for s in live {
            let k = s.kind
            defer { lastKinds[s.sessionId] = k }
            // Lần đầu chỉ ghi nhận, không báo lại chuyện cũ.
            guard primed, lastKinds[s.sessionId] != k else { continue }
            onChange?(Event(state: s, kind: k))
        }
        primed = true
    }
}
