import AppKit
import SwiftUI
import AVFoundation
import Speech

/// Công cụ kiểm tra không giao diện.
///   DeskPet --selftest "<tin 1>" ["<tin 2>" …] [--allow|--deny]   chạy nhiều lượt trong MỘT tiến trình claude
///   DeskPet --assistant "<tin nhắn>"                              hỏi trợ lý (có MCP DeskPet)
///   DeskPet --sessions <thư mục>                                  in các phiên cũ của thư mục
enum SelfTest {
    private static var firstAttachments: [Attachment] = []
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--sessions"), i + 1 < args.count { sessions(args[i + 1]) }
        // `DeskPet --terminal-script <thư mục> <session_id> <tên>` — in script mở Terminal + Remote Control (không chạy)
        if let i = args.firstIndex(of: "--terminal-script"), i + 3 < args.count {
            print(TerminalLauncher.script(folder: args[i + 1], sessionId: args[i + 2], remoteControlName: args[i + 3],
                                          claude: ClaudeLocator.find(custom: "") ?? "claude"))
            exit(0)
        }
        // `DeskPet --tts-check "<markdown>"` — tổng hợp giọng vào bộ nhớ (không phát loa), in độ dài âm thanh.
        if let i = args.firstIndex(of: "--tts-check"), i + 1 < args.count { ttsCheck(args[i + 1]) }
        // `DeskPet --stt-file <audio>` — nhận dạng tiếng Việt từ file (cần quyền Speech Recognition).
        if let i = args.firstIndex(of: "--stt-file"), i + 1 < args.count { sttFile(args[i + 1]) }
        // `DeskPet --send-guard <pid>` — kiểm tra "claude còn chiếm terminal không" (không gõ gì).
        if let i = args.firstIndex(of: "--send-guard"), i + 1 < args.count, let pid = Int(args[i + 1]) {
            print(ExternalSessions.foregroundProblem(pid: pid) ?? "OK — được gõ")
            exit(0)
        }
        // `DeskPet --menu-check <file>` — nội dung màn hình trong file có bảng chọn của Claude Code không.
        if let i = args.firstIndex(of: "--menu-check"), i + 1 < args.count {
            let text = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
            print(ExternalSessions.showsChoiceMenu(text) ? "CÓ bảng chọn — chặn" : "không có bảng chọn")
            exit(0)
        }
        // `DeskPet --login-item on|off|status`
        if let i = args.firstIndex(of: "--login-item") {
            let mode = i + 1 < args.count ? args[i + 1] : "status"
            if mode != "status", let err = LoginItem.set(mode == "on") { print("lỗi: \(err)") }
            print("login item: \(LoginItem.isEnabled ? "BẬT" : "tắt") · bundle: \(Bundle.main.bundlePath)")
            exit(0)
        }
        if let i = args.firstIndex(of: "--assistant"), i + 1 < args.count {
            let messages = args[(i + 1)...].filter { !$0.hasPrefix("--") }
            run(runner: SessionManager.shared.assistant, messages: Array(messages), allow: args.contains("--allow"))
        }
        guard let i = args.firstIndex(of: "--selftest") else { return }
        // `--mode <chế độ>`: giá trị đi sau --mode không phải tin nhắn.
        let modeIndex = args.firstIndex(of: "--mode")
        let mode = modeIndex.flatMap { $0 + 1 < args.count ? PermissionMode(rawValue: args[$0 + 1]) : nil }
        // `--attach <tệp>` (lặp được): đính kèm vào tin đầu tiên.
        let attachIdx = args.indices.filter { args[$0] == "--attach" && $0 + 1 < args.count }.map { $0 + 1 }
        let messages = args.indices.filter { $0 > i && !args[$0].hasPrefix("--") && $0 != modeIndex.map { $0 + 1 }
                                             && !attachIdx.contains($0) }
            .map { args[$0] }
        firstAttachments = attachIdx.map { Attachment.make(URL(fileURLWithPath: args[$0])) }
        let runner = SessionRunner(title: "selftest", folder: AppSettings.shared.workingDirectory, sessionId: nil,
                                   permissionMode: mode ?? .default)
        runner.model = { AppSettings.shared.model }
        run(runner: runner, messages: Array(messages), allow: !args.contains("--deny"))
    }

    private static func run(runner: SessionRunner, messages: [String], allow: Bool) {
        var queue = messages
        var printed = 0
        let start = Date()
        func flush() {
            for item in runner.items.dropFirst(printed) {
                let extra = item.detail.isEmpty ? "" : " | \(item.detail.prefix(100).replacingOccurrences(of: "\n", with: " "))"
                print("[\(item.kind)] \(item.text.prefix(300))\(extra)")
            }
            printed = runner.items.count
        }
        runner.onEvent = { r, e in
            switch e {
            case .permission, .question:
                guard let p = r.pendingRequest else { return }
                flush()
                if p.kind == .question {
                    let ans = Dictionary(uniqueKeysWithValues: p.questions.map { ($0.question, $0.options.first?.label ?? "") })
                    print("  → trả lời: \(ans)")
                    r.answer(requestId: p.requestId, answers: ans)
                } else {
                    if !p.diff.isEmpty { print("  diff: \(p.diff.count) dòng") }
                    print("  → \(allow ? "cho phép" : "từ chối")")
                    r.decide(requestId: p.requestId, allow: allow)
                }
            case .finished(let ok):
                flush()
                print("  (xong lượt: \(ok ? "ok" : "lỗi"), \(String(format: "%.1f", Date().timeIntervalSince(start)))s, tiến trình sống: \(r.isRunning), todos: \(r.todos.count))")
                if queue.isEmpty {
                    print("session_id: \(r.sessionId ?? "-")")
                    if r.isAssistant { dumpSessionsWhenIdle() } else { r.shutdown(); exit(0) }
                    return
                }
                let next = queue.removeFirst()
                DispatchQueue.main.async { r.send(next) }
            default: break
            }
        }
        runner.send(queue.removeFirst(), attachments: firstAttachments)
        RunLoop.main.run()
    }

    /// Sau khi trợ lý xong: chờ các phiên nó điều khiển chạy xong rồi in nội dung bên trong từng phiên.
    private static func dumpSessionsWhenIdle(waited: Double = 0) {
        let m = SessionManager.shared
        if m.runners.contains(where: { $0.isBusy }) && waited < 180 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { dumpSessionsWhenIdle(waited: waited + 1) }
            return
        }
        for r in m.runners {
            print("=== phiên \"\(r.title)\" (\((r.folder as NSString).lastPathComponent)) sid=\(r.sessionId?.prefix(8) ?? "-") status=\(r.status.label) mode=\(r.permissionMode.rawValue)")
            for item in r.items { print("   [\(item.kind)] \(item.text.prefix(160).replacingOccurrences(of: "\n", with: " "))") }
        }
        m.shutdownAll()
        exit(0)
    }

    private static func ttsCheck(_ md: String) -> Never {
        let plain = VoiceController.plainText(md)
        print("đọc: \(plain)")
        print("giọng: \(VoiceController.vietnameseVoice?.name ?? "-") (\(VoiceController.vietnameseVoice?.language ?? "-"))")
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: plain)
        u.voice = VoiceController.vietnameseVoice
        var frames: AVAudioFrameCount = 0
        var rate = 0.0
        synth.write(u) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                print(String(format: "âm thanh: %.1f giây", rate > 0 ? Double(frames) / rate : 0))
                exit(0)
            }
            frames += pcm.frameLength
            rate = pcm.format.sampleRate
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("hết giờ"); exit(1) }
        RunLoop.main.run()
        exit(0)
    }

    private static func sttFile(_ path: String) -> Never {
        SFSpeechRecognizer.requestAuthorization { status in
            print("quyền nhận dạng: \(status.rawValue) (3 = được phép)")
            guard status == .authorized, let r = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN")) else { exit(1) }
            print("on-device: \(r.supportsOnDeviceRecognition)")
            let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
            if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            r.recognitionTask(with: req) { result, error in
                if let result, result.isFinal { print("nghe được: \(result.bestTranscription.formattedString)"); exit(0) }
                if let error { print("lỗi: \(error.localizedDescription)"); exit(1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("hết giờ"); exit(1) }
        RunLoop.main.run()
        exit(0)
    }

    private static func sessions(_ folder: String) -> Never {
        let start = Date()
        let list = SessionHistory.list(folder: folder)
        print("dir: \(SessionHistory.projectDir(for: folder).path)")
        print("\(list.count) phiên (\(Int(Date().timeIntervalSince(start) * 1000)) ms)")
        for e in list.prefix(8) { print("  \(e.id.prefix(8))  \(e.date)  \(e.title)") }
        exit(0)
    }
}

/// `DeskPet --snapshot <thư mục>` — render các trạng thái của pet, bảng phiên, bong bóng trợ lý ra PNG.
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let settings = AppSettings.shared

        let moods: [(String, PetActivity?)] = [("idle", nil), ("thinking", .thinking), ("working", .working("terminal")),
                                               ("talking", .talking), ("permission", .permission), ("happy", .done), ("error", .failed)]
        for c in PetCharacter.allCases {
            let original = settings.character
            settings.character = c
            for (name, act) in moods {
                let model = PetModel()
                if let act { model.handle(act) }
                render(PetView(model: model, settings: settings), size: NSSize(width: 192, height: 186),
                       to: dir.appendingPathComponent("\(c.rawValue)_\(name).png"))
            }
            settings.character = original
        }

        // Bảng phiên với dữ liệu mẫu.
        let manager = SessionManager.shared
        let a = manager.create(folder: NSHomeDirectory(), title: "face-engine-switcher")
        a.loadPreview([
            ChatItem(kind: .user, text: "Đổi engine so khớp khuôn mặt sang provider mới"),
            ChatItem(kind: .tool, text: "Đọc file", detail: "FaceEngineRouter.java", icon: "doc.text"),
            ChatItem(kind: .permission, text: "Claude muốn: Sửa file — FaceEngineRouter.java", icon: "pencil", requestId: "x",
                     diff: DiffLine.forTool(name: "Edit", input: ["file_path": "ekyc/face/FaceEngineRouter.java",
                        "old_string": "    if (flag) {\n        return vendorA.match(req);\n    }\n    return legacy.match(req);",
                        "new_string": "    if (flag) {\n        return vendorB.match(req);\n    }\n    return legacy.match(req);"])),
        ], status: .needsPermission, todos: [
            TodoItem(content: "Đọc router hiện tại", activeForm: "", state: .completed),
            TodoItem(content: "Đổi sang vendor B", activeForm: "Đang đổi sang vendor B", state: .inProgress),
            TodoItem(content: "Chạy test ekyc", activeForm: "", state: .pending),
        ])
        let b = manager.create(folder: NSHomeDirectory(), title: "napas error mapping")
        a.setPermissionMode(.auto)
        b.setPermissionMode(.acceptEdits)
        b.loadPreview([ChatItem(kind: .user, text: "map errorDesc cho mọi lỗi")], status: .working)
        let c = manager.create(folder: NSHomeDirectory(), title: "rate limit report")
        c.loadPreview([ChatItem(kind: .assistant, text: "Đã xong báo cáo.")], status: .done)
        c.unread = true
        let q = manager.create(folder: NSHomeDirectory(), title: "chọn thư viện")
        q.loadPreview([ChatItem(kind: .question, text: "", requestId: "q", questions: [
            AskQuestion(question: "Dùng thư viện HTTP nào?", header: "HTTP", options: [
                .init(label: "Vert.x WebClient", description: "đang dùng ở module khác"),
                .init(label: "Quarkus REST Client", description: "chuẩn mới")], multiSelect: false)])],
            status: .needsAnswer)
        manager.selectedId = a.id
        render(DashboardView(manager: manager, settings: settings, actions: ChatActions()),
               size: NSSize(width: 1000, height: 660), to: dir.appendingPathComponent("dashboard.png"))
        manager.selectedId = q.id
        render(DashboardView(manager: manager, settings: settings, actions: ChatActions()),
               size: NSSize(width: 1000, height: 660), to: dir.appendingPathComponent("dashboard_question.png"))
        // Phiên claude thật đang chạy ngoài DeskPet (nếu có).
        manager.refreshExternal(force: true)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        if let e = manager.externalSessions.first {
            manager.selectedExternalPid = e.pid
            render(DashboardView(manager: manager, settings: settings, actions: ChatActions()),
                   size: NSSize(width: 1000, height: 660), to: dir.appendingPathComponent("dashboard_external.png"))
        }
        render(ChatView(runner: manager.assistant, settings: settings, compact: true, actions: ChatActions()),
               size: NSSize(width: 380, height: 500), to: dir.appendingPathComponent("assistant.png"))
        render(ToastView(alert: .init(runnerId: a.id, kind: .permission, title: "face-engine-switcher cần bạn cho phép",
                                      body: "Sửa file — FaceEngineRouter.java"), onOpen: {}, onClose: {}),
               size: NSSize(width: 312, height: 80), to: dir.appendingPathComponent("toast.png"))
        render(SettingsView(settings: settings), size: NSSize(width: 480, height: 600), to: dir.appendingPathComponent("settings.png"))
        exit(0)
    }

    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
