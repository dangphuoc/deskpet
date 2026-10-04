import AppKit
import ApplicationServices
import ImageIO

/// Mức quyền của một nhóm điều khiển máy.
enum ControlMode: String, CaseIterable, Identifiable {
    case off, ask, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Tắt"
        case .ask: return "Hỏi trước"
        case .auto: return "Tự chạy"
        }
    }
}

/// Các nhóm tool điều khiển máy — bật/tắt riêng trong Cài đặt hoặc menu 🐾.
enum ControlGroup: String, CaseIterable, Identifiable {
    case screen, input, script, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Nhìn màn hình"
        case .input: return "Chuột, bàn phím & thoát app"
        case .script: return "AppleScript & lệnh terminal"
        case .system: return "Hệ thống"
        }
    }
    var detail: String {
        switch self {
        case .screen: return "Chụp màn hình gửi cho Claude xem, liệt kê app và cửa sổ đang mở."
        case .input: return "Click, cuộn, gõ chữ, phím tắt, thoát app. Cần quyền Accessibility."
        case .script: return "Điều khiển app qua AppleScript/JXA và lệnh Bash của Claude Code."
        case .system: return "Âm lượng, dark mode, khoá màn hình, tắt màn hình, xem pin."
        }
    }
    var icon: String {
        switch self {
        case .screen: return "eye"
        case .input: return "cursorarrow.click.2"
        case .script: return "applescript"
        case .system: return "gearshape"
        }
    }
    var defaultMode: ControlMode {
        switch self {
        case .screen, .system: return .auto
        case .input, .script: return .ask
        }
    }
    /// Tool MCP (không tiền tố) thuộc nhóm. Bash có sẵn của Claude Code tính vào nhóm `script`.
    var tools: [String] {
        switch self {
        case .screen: return ["screenshot", "list_windows"]
        case .input: return ["mouse_click", "scroll", "type_text", "key_press", "quit_app"]
        case .script: return ["run_applescript"]
        case .system: return ["system_status", "set_volume", "set_dark_mode", "lock_screen", "sleep_display"]
        }
    }

    static func of(tool: String) -> ControlGroup? { allCases.first { $0.tools.contains(tool) } }

    /// Nhóm của một tool theo tên đầy đủ trong Claude Code (vd. "mcp__deskpet__screenshot", "Bash").
    static func of(claudeTool name: String) -> ControlGroup? {
        if name == "Bash" { return .script }
        let prefix = "mcp__deskpet__"
        return name.hasPrefix(prefix) ? of(tool: String(name.dropFirst(prefix.count))) : nil
    }
}

/// Đọc mức quyền thẳng từ UserDefaults — dùng được cả trong app lẫn tiến trình MCP (`DeskPet --mcp`),
/// nên đổi trong Cài đặt là có hiệu lực ngay, không cần khởi động lại phiên.
enum ControlPolicy {
    static let enabledKey = "controlEnabled"
    static let modesKey = "controlModes"

    static func mode(_ g: ControlGroup, defaults: UserDefaults = .standard) -> ControlMode {
        guard defaults.object(forKey: enabledKey) as? Bool ?? true else { return .off }
        let raw = (defaults.dictionary(forKey: modesKey) as? [String: String])?[g.rawValue]
        return raw.flatMap(ControlMode.init) ?? g.defaultMode
    }

    static func offMessage(_ g: ControlGroup) -> String {
        "Người dùng đang tắt nhóm “\(g.title)” trong DeskPet. Nhờ người dùng bật lại ở Cài đặt DeskPet → Điều khiển máy (hoặc menu 🐾 → Điều khiển máy) nếu cần."
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}

/// Tool điều khiển máy của MCP DeskPet (chạy trong tiến trình `DeskPet --mcp`).
enum ComputerControl {
    typealias Content = [[String: Any]]

    private static func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }
    private static let str: [String: Any] = ["type": "string"]
    private static let num: [String: Any] = ["type": "number"]
    private static let bool: [String: Any] = ["type": "boolean"]

    static let tools: [[String: Any]] = [
        ["name": "screenshot", "description": "Chụp màn hình để xem người dùng đang thấy gì. Toạ độ trên ảnh trả về dùng thẳng cho mouse_click / scroll. `display`: số màn hình (1 = màn hình chính).",
         "inputSchema": schema(["display": ["type": "integer"]])],
        ["name": "list_windows", "description": "Liệt kê app đang chạy, app đang ở trước và các cửa sổ đang hiện (app, tiêu đề, khung theo toạ độ ảnh chụp gần nhất).",
         "inputSchema": schema([:])],
        ["name": "mouse_click", "description": "Click chuột tại (x, y) theo toạ độ trên ảnh screenshot gần nhất. `button`: left (mặc định) hoặc right. `count`: 2 = double-click.",
         "inputSchema": schema(["x": num, "y": num, "button": str, "count": ["type": "integer"]], required: ["x", "y"])],
        ["name": "scroll", "description": "Cuộn tại (x, y) (toạ độ ảnh screenshot). `amount`: số dòng, dương = cuộn xuống, âm = cuộn lên.",
         "inputSchema": schema(["x": num, "y": num, "amount": ["type": "integer"]], required: ["amount"])],
        ["name": "type_text", "description": "Gõ chữ (có dấu tiếng Việt) vào ô đang được chọn. Muốn xuống dòng/gửi thì dùng key_press \"enter\".",
         "inputSchema": schema(["text": str], required: ["text"])],
        ["name": "key_press", "description": "Bấm phím hoặc tổ hợp phím, vd. \"enter\", \"esc\", \"tab\", \"cmd+c\", \"cmd+shift+4\", \"cmd+tab\", \"left\", \"f5\".",
         "inputSchema": schema(["keys": str], required: ["keys"])],
        ["name": "quit_app", "description": "Thoát một ứng dụng theo tên (vd. \"Safari\"). `force`=true để buộc thoát app bị treo.",
         "inputSchema": schema(["name": str, "force": bool], required: ["name"])],
        ["name": "run_applescript", "description": "Chạy AppleScript (hoặc JXA khi `language`=\"javascript\") để điều khiển app macOS: Finder, Safari, Music, Mail, System Events… Trả về kết quả của script. Tối đa 60 giây.",
         "inputSchema": schema(["script": str, "language": str], required: ["script"])],
        ["name": "system_status", "description": "Xem trạng thái máy: âm lượng, dark mode, pin, app đang ở trước, các màn hình.",
         "inputSchema": schema([:])],
        ["name": "set_volume", "description": "Chỉnh âm lượng loa (`level` 0–100) và/hoặc tắt/bật tiếng (`muted`).",
         "inputSchema": schema(["level": ["type": "integer"], "muted": bool])],
        ["name": "set_dark_mode", "description": "Bật (`on`=true) hoặc tắt dark mode của macOS.",
         "inputSchema": schema(["on": bool], required: ["on"])],
        ["name": "lock_screen", "description": "Khoá màn hình ngay.", "inputSchema": schema([:])],
        ["name": "sleep_display", "description": "Tắt màn hình (cho màn hình ngủ).", "inputSchema": schema([:])],
    ]

    static func call(_ name: String, _ a: [String: Any]) -> (Content, Bool) {
        func s(_ k: String) -> String { (a[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func d(_ k: String) -> Double? { (a[k] as? NSNumber)?.doubleValue ?? Double(s(k)) }
        func text(_ t: String, _ err: Bool = false) -> (Content, Bool) { ([["type": "text", "text": t]], err) }

        switch name {
        case "screenshot":
            return screenshot(display: Int(d("display") ?? 1))

        case "list_windows":
            return text(listWindows())

        case "mouse_click":
            guard let x = d("x"), let y = d("y") else { return text("Thiếu x, y.", true) }
            let right = s("button").lowercased() == "right"
            let count = max(1, min(3, Int(d("count") ?? 1)))
            let p = toScreen(x, y)
            click(at: p, right: right, count: count)
            return text("Đã \(count == 2 ? "double-click" : "click")\(right ? " chuột phải" : "") tại (\(Int(x)), \(Int(y)))." + axWarning)

        case "scroll":
            let amount = Int(d("amount") ?? 0)
            if let x = d("x"), let y = d("y") { move(to: toScreen(x, y)) }
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(-amount), wheel2: 0, wheel3: 0)
            e?.post(tap: .cghidEventTap)
            return text("Đã cuộn \(amount > 0 ? "xuống" : "lên") \(abs(amount)) dòng." + axWarning)

        case "type_text":
            let t = a["text"] as? String ?? ""
            guard !t.isEmpty else { return text("Thiếu text.", true) }
            typeText(t)
            return text("Đã gõ \(t.count) ký tự." + axWarning)

        case "key_press":
            switch pressKeys(s("keys")) {
            case .success: return text("Đã bấm \(s("keys"))." + axWarning)
            case .failure(let e): return text(e.text, true)
            }

        case "quit_app":
            return quitApp(s("name"), force: a["force"] as? Bool == true)

        case "run_applescript":
            let script = a["script"] as? String ?? ""
            guard !script.isEmpty else { return text("Thiếu script.", true) }
            let lang = s("language").lowercased().hasPrefix("j") ? "JavaScript" : "AppleScript"
            let r = capture("/usr/bin/osascript", ["-l", lang, "-"], input: script, timeout: 60)
            if r.status != 0 { return text("Lỗi (\(r.status)): \(r.err.isEmpty ? r.out : r.err)", true) }
            return text(r.out.isEmpty ? "Xong (không có kết quả)." : String(r.out.prefix(8000)))

        case "system_status":
            return text(systemStatus())

        case "set_volume":
            var parts: [String] = []
            if let level = d("level") { parts.append("set volume output volume \(max(0, min(100, Int(level))))") }
            if let m = a["muted"] as? Bool { parts.append("set volume output muted \(m)") }
            guard !parts.isEmpty else { return text("Cần `level` hoặc `muted`.", true) }
            let r = capture("/usr/bin/osascript", parts.flatMap { ["-e", $0] })
            return r.status == 0 ? text("Đã chỉnh âm lượng.") : text("Lỗi: \(r.err)", true)

        case "set_dark_mode":
            let on = a["on"] as? Bool ?? true
            let r = capture("/usr/bin/osascript",
                            ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)"])
            return r.status == 0 ? text(on ? "Đã bật dark mode." : "Đã tắt dark mode.")
                : text("Lỗi: \(r.err) (có thể cần cho DeskPet quyền điều khiển System Events trong Privacy & Security → Automation).", true)

        case "lock_screen":
            if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
               let sym = dlsym(h, "SACLockScreenImmediate") {
                typealias Lock = @convention(c) () -> Int32
                _ = unsafeBitCast(sym, to: Lock.self)()
                return text("Đã khoá màn hình.")
            }
            _ = capture("/usr/bin/pmset", ["displaysleepnow"])
            return text("Đã tắt màn hình (máy sẽ khoá nếu bật yêu cầu mật khẩu).")

        case "sleep_display":
            let r = capture("/usr/bin/pmset", ["displaysleepnow"])
            return r.status == 0 ? text("Đã tắt màn hình.") : text("Lỗi: \(r.err)", true)

        default:
            return text("Tool không tồn tại: \(name)", true)
        }
    }

    // MARK: - Màn hình & toạ độ

    /// Ảnh chụp gần nhất: toạ độ ảnh × scale + origin = toạ độ màn hình (điểm, gốc trên-trái màn hình chính).
    private struct Shot { var origin: CGPoint; var scale: Double }
    private static var lastShot: Shot?
    private static let maxShotWidth = 1440.0

    private static func displays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        // screencapture -D đánh số 1 = màn hình chính.
        let list = Array(ids.prefix(Int(n)))
        let main = CGMainDisplayID()
        return [main] + list.filter { $0 != main }
    }

    private static func shotGeometry(display: Int) -> (index: Int, bounds: CGRect, scale: Double) {
        let ds = displays()
        let idx = max(1, min(display, ds.count))
        let b = CGDisplayBounds(ds[idx - 1])
        return (idx, b, Double(b.width) / min(Double(b.width), maxShotWidth))
    }

    private static func currentShot() -> Shot {
        if let s = lastShot { return s }
        let g = shotGeometry(display: 1)
        return Shot(origin: g.bounds.origin, scale: g.scale)
    }

    private static func toScreen(_ x: Double, _ y: Double) -> CGPoint {
        let s = currentShot()
        return CGPoint(x: s.origin.x + x * s.scale, y: s.origin.y + y * s.scale)
    }

    private static func screenshot(display: Int) -> (Content, Bool) {
        let g = shotGeometry(display: display)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("deskpet-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = capture("/usr/sbin/screencapture", ["-x", "-D", "\(g.index)", "-t", "png", tmp.path], timeout: 15)
        guard r.status == 0,
              let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return ([["type": "text", "text": "Không chụp được màn hình. Cần cấp quyền Screen Recording cho DeskPet (Cài đặt DeskPet → Điều khiển máy). \(r.err)"]], true)
        }
        let w = Int((Double(g.bounds.width) / g.scale).rounded())
        let h = Int((Double(g.bounds.height) / g.scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return ([["type": "text", "text": "Không xử lý được ảnh chụp."]], true)
        }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        guard let small = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return ([["type": "text", "text": "Không xử lý được ảnh chụp."]], true)
        }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        CGImageDestinationFinalize(dest)
        lastShot = Shot(origin: g.bounds.origin, scale: g.scale)

        var note = "Màn hình \(g.index)/\(displays().count), ảnh \(w)×\(h). Toạ độ trên ảnh này dùng thẳng cho mouse_click / scroll."
        if !ControlPolicy.screenRecordingGranted {
            note += " (Có thể chưa có quyền Screen Recording — nếu ảnh chỉ thấy hình nền, nhờ người dùng cấp quyền.)"
        }
        return ([["type": "image", "data": (out as Data).base64EncodedString(), "mimeType": "image/jpeg"],
                 ["type": "text", "text": note]], false)
    }

    private static func listWindows() -> String {
        let shot = currentShot()
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = info.compactMap { w -> String? in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let owner = w[kCGWindowOwnerName as String] as? String,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd), r.width > 40, r.height > 40 else { return nil }
            let title = (w[kCGWindowName as String] as? String).map { " “\($0)”" } ?? ""
            let x = Int((Double(r.minX) - Double(shot.origin.x)) / shot.scale)
            let y = Int((Double(r.minY) - Double(shot.origin.y)) / shot.scale)
            return "- \(owner)\(title) — x:\(x) y:\(y) rộng:\(Int(Double(r.width) / shot.scale)) cao:\(Int(Double(r.height) / shot.scale))"
        }
        return """
        App đang ở trước: \(front)
        App đang chạy: \(apps.joined(separator: ", "))
        Cửa sổ (trên xuống dưới, toạ độ theo ảnh chụp):
        \(windows.isEmpty ? "(không có)" : windows.joined(separator: "\n"))
        """
    }

    // MARK: - Chuột & bàn phím

    private static var axWarning: String {
        ControlPolicy.accessibilityGranted ? ""
            : " (Cảnh báo: DeskPet có thể chưa có quyền Accessibility nên thao tác không có tác dụng — nhờ người dùng cấp ở Cài đặt DeskPet → Điều khiển máy.)"
    }

    private static func move(to p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(40_000)
    }

    private static func click(at p: CGPoint, right: Bool, count: Int) {
        move(to: p)
        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for i in 1...count {
            for type in [downType, upType] {
                let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e?.post(tap: .cghidEventTap)
            }
            usleep(30_000)
        }
    }

    private static func typeText(_ t: String) {
        let units = Array(t.utf16)
        var i = 0
        while i < units.count {
            var chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                e?.post(tap: .cghidEventTap)
            }
            usleep(10_000)
            i += 16
        }
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
        "enter": 36, "return": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    struct ControlError: Error { let text: String }

    private static func pressKeys(_ combo: String) -> Result<Void, ControlError> {
        let parts = combo.lowercased().replacingOccurrences(of: " ", with: "")
            .split(separator: "+").map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { return .failure(ControlError(text: "Thiếu phím.")) }
        var flags = CGEventFlags()
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: return .failure(ControlError(text: "Không hiểu phím bổ trợ \"\(m)\"."))
            }
        }
        guard let code = keyCodes[keyName] else { return .failure(ControlError(text: "Không hiểu phím \"\(keyName)\".")) }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        return .success(())
    }

    // MARK: - App & hệ thống

    private static func quitApp(_ name: String, force: Bool) -> (Content, Bool) {
        func text(_ t: String, _ err: Bool = false) -> (Content, Bool) { ([["type": "text", "text": t]], err) }
        let n = name.lowercased()
        guard !n.isEmpty else { return text("Thiếu tên app.", true) }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let matches = apps.filter { $0.localizedName?.lowercased() == n || $0.bundleIdentifier?.lowercased() == n }
        let found = matches.isEmpty ? apps.filter { ($0.localizedName ?? "").lowercased().contains(n) } : matches
        guard let app = found.first else { return text("Không thấy app \"\(name)\" đang chạy.", true) }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return text("Không tự thoát DeskPet.", true) }
        let ok = force ? app.forceTerminate() : app.terminate()
        return ok ? text("Đã \(force ? "buộc thoát" : "thoát") \(app.localizedName ?? name).")
                  : text("Không thoát được \(app.localizedName ?? name).", true)
    }

    private static func systemStatus() -> String {
        let vol = capture("/usr/bin/osascript", ["-e", "set v to get volume settings",
                                                 "-e", "(output volume of v as text) & \" \" & (output muted of v as text)"]).out
        let dark = capture("/usr/bin/defaults", ["read", "-g", "AppleInterfaceStyle"]).out == "Dark"
        let batt = capture("/usr/bin/pmset", ["-g", "batt"]).out
            .components(separatedBy: "\n").dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let screens = displays().enumerated().map { i, id in
            let b = CGDisplayBounds(id)
            return "màn hình \(i + 1): \(Int(b.width))×\(Int(b.height))"
        }.joined(separator: ", ")
        let v = vol.split(separator: " ")
        return """
        Âm lượng: \(v.first ?? "?")\(v.count > 1 && v[1] == "true" ? " (đang tắt tiếng)" : "")
        Dark mode: \(dark ? "bật" : "tắt")
        Pin: \(batt.isEmpty ? "không có" : batt)
        App đang ở trước: \(front)
        \(screens)
        Quyền: Accessibility \(ControlPolicy.accessibilityGranted ? "có" : "chưa"), Screen Recording \(ControlPolicy.screenRecordingGranted ? "có" : "chưa")
        """
    }

    // MARK: - Chạy tiến trình

    private static func capture(_ path: String, _ args: [String], input: String? = nil,
                                timeout: TimeInterval = 20) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()
        killer.cancel()
        let trim = { (d: Data) in String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (p.terminationStatus, trim(outData), trim(errData))
    }
}
