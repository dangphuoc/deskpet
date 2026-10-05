import SwiftUI
import UniformTypeIdentifiers

/// Các hành động ngoài khung chat (cửa sổ, terminal…) do AppDelegate cung cấp.
struct ChatActions {
    var close: () -> Void = {}
    var openSettings: () -> Void = {}
    var openDashboard: () -> Void = {}
    var openInTerminal: (SessionRunner) -> Void = { _ in }
    var remoteControl: (SessionRunner) -> Void = { _ in }
}

struct ChatView: View {
    @ObservedObject var runner: SessionRunner
    @ObservedObject var settings: AppSettings
    /// true = bong bóng trợ lý cạnh pet; false = khung chi tiết trong bảng phiên.
    var compact: Bool
    var actions: ChatActions

    @ObservedObject private var voice = VoiceController.shared
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var dropTargeted = false
    @State private var showHistory = false
    @State private var showTodos = true
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !runner.todos.isEmpty { todoPanel; Divider() }
            messages
            Divider()
            inputBar
        }
        // Kéo thả ảnh / tệp vào bất kỳ đâu trong khung chat để đính kèm.
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(Label("Thả vào để đính kèm", systemImage: "paperclip").font(.system(size: 14, weight: .medium)))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            inputFocused = true
            runner.markSeen()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if compact, let img = CharacterLibrary.image(settings.character, .standing) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(compact ? "Trợ lý \(settings.character.displayName)" : runner.title)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if runner.isBusy { ProgressView().controlSize(.mini) }
                    if !compact {
                        Image(systemName: "folder").font(.system(size: 10))
                        Text(runner.folderName).font(.system(size: 11)).lineLimit(1)
                        Text("·")
                    }
                    if settings.profiles.count > 1 {
                        Image(systemName: "person.crop.circle").font(.system(size: 10))
                        Text(runner.profile.name).font(.system(size: 11)).lineLimit(1)
                        Text("·")
                    }
                    Text(runner.statusText).font(.system(size: 11)).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .help(runner.folder)
            }
            Spacer()

            if compact {
                headerButton("folder", "Mở thư mục của trợ lý (\(runner.folder))") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: runner.folder))
                }
                headerButton("rectangle.split.2x1", "Bảng phiên") { actions.openDashboard() }
            } else {
                headerButton("clock.arrow.circlepath", "Phiên cũ trong thư mục này") { showHistory.toggle() }
                    .disabled(runner.isBusy)
                    .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                        SessionPicker(folder: runner.folder, current: runner.sessionId, root: runner.profile.rootPath) { id in
                            showHistory = false
                            runner.switchTo(sessionId: id)
                        }
                    }
                headerButton("apple.terminal", "Mở phiên này trong Terminal") { actions.openInTerminal(runner) }
                    .disabled(runner.isBusy)
                headerButton("dot.radiowaves.left.and.right", "Bật Remote Control (mở trong Terminal, điều khiển từ điện thoại / claude.ai)") {
                    actions.remoteControl(runner)
                }
                .disabled(runner.isBusy)
                headerButton("folder", "Mở thư mục trong Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: runner.folder)])
                }
            }
            headerButton("square.and.pencil", "Cuộc trò chuyện mới") { runner.switchTo(sessionId: nil) }
                .disabled(runner.isBusy)
            if compact {
                headerButton("gearshape", "Cài đặt") { actions.openSettings() }
                headerButton("xmark", "Đóng (Esc)") { actions.close() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func headerButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(.borderless).help(help)
    }

    // MARK: Todo

    private var todoPanel: some View {
        let done = runner.todos.filter { $0.state == .completed }.count
        return DisclosureGroup(isExpanded: $showTodos) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(runner.todos) { t in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: t.state == .completed ? "checkmark.circle.fill"
                              : t.state == .inProgress ? "circle.dotted.circle" : "circle")
                            .foregroundStyle(t.state == .completed ? Color.green : t.state == .inProgress ? Color.accentColor : .secondary)
                        Text(t.state == .inProgress && !t.activeForm.isEmpty ? t.activeForm : t.content)
                            .strikethrough(t.state == .completed)
                            .foregroundStyle(t.state == .completed ? .secondary : .primary)
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Việc cần làm \(done)/\(runner.todos.count)", systemImage: "checklist")
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if runner.items.isEmpty { emptyHint.padding(.top, 8) }
                    ForEach(runner.items) { item in row(item).id(item.id) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: runner.items.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: runner.items.last?.text) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private var emptyHint: some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                Text("Chào bạn! Mình có thể:").font(.system(size: 13, weight: .medium))
                ForEach(["Mở nhạc lofi trên YouTube", "Mở Gmail",
                         "Phiên nào đang chờ mình cho phép?", "Trong service-bank-v3, chạy test module ekyc"], id: \.self) { s in
                    Button { draft = s } label: { Text("“\(s)”").font(.system(size: 12)) }
                        .buttonStyle(.link)
                }
            }
        } else {
            Text("Nhắn yêu cầu để Claude làm việc trong **\(runner.folderName)**.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    if !item.attachments.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(item.attachments, id: \.self) { url in SentAttachmentView(url: url) }
                        }
                    }
                    Text(item.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                }
            }
        case .assistant:
            HStack {
                Text(markdown(item.text))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer(minLength: 24)
            }
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: item.icon).frame(width: 14)
                Text(item.text).fontWeight(.medium)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.04), in: Capsule())
        case .permission:
            PermissionCard(item: item) { allow in runner.decide(requestId: item.requestId, allow: allow) }
        case .question:
            QuestionCard(item: item,
                         onAnswer: { runner.answer(requestId: item.requestId, answers: $0) },
                         onSkip: { runner.decide(requestId: item.requestId, allow: false) })
        case .error:
            VStack(alignment: .leading, spacing: 6) {
                Label { Text(item.text).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                if item.text.contains("/login") || item.text.localizedCaseInsensitiveContains("not logged in") {
                    Button("Đăng nhập tài khoản “\(runner.profile.name)”…") { TerminalLauncher.openLogin(runner.profile) }
                        .controlSize(.small)
                }
            }
        case .info:
            Text(item.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Input

    @ViewBuilder
    private var voiceBar: some View {
        if compact && voice.isListening {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Text(voice.transcript.isEmpty ? "Đang nghe… (thả ⌥Space hoặc ngừng nói là tự gửi)" : voice.transcript)
                    .font(.system(size: 13)).lineLimit(3)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.red.opacity(0.08))
        } else if compact, let err = voice.lastError {
            HStack(spacing: 6) {
                Image(systemName: "mic.slash.fill")
                Text(err).font(.system(size: 11)).lineLimit(3)
                Spacer(minLength: 0)
                Button { voice.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .foregroundStyle(.red)
            .padding(10)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            voiceBar
            attachmentStrip
            inputRow
            modeBar
        }
    }

    /// Chế độ quyền như dòng dưới ô nhập của Claude Code; Shift+Tab để xoay vòng.
    @ViewBuilder
    private var modeBar: some View {
        HStack(spacing: 6) {
            if runner.openedInTerminal {
                Image(systemName: "apple.terminal").font(.system(size: 10))
                Text("Đang mở trong Terminal — đổi chế độ bằng Shift+Tab ở đó").font(.system(size: 10))
            } else {
                Menu {
                    ForEach(PermissionMode.selectable) { m in
                        Button { runner.setPermissionMode(m) } label: {
                            Label("\(m.label) — \(m.detail)", systemImage: runner.permissionMode == m ? "checkmark" : m.icon)
                        }
                    }
                } label: {
                    Label(runner.permissionMode.label, systemImage: runner.permissionMode.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(runner.permissionMode.color)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(runner.permissionMode.detail)
                Text("⇧⇥ đổi chế độ").font(.system(size: 10)).foregroundStyle(.tertiary)
                // Shift+Tab như trong Claude Code.
                Button("") { runner.setPermissionMode(runner.permissionMode.next) }
                    .keyboardShortcut(.tab, modifiers: .shift)
                    .opacity(0).frame(width: 0, height: 0)
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(runner.isBusy ? "Claude đang làm việc…"
                      : compact ? "Nhắn cho \(settings.character.displayName)…" : "Nhắn trong \(runner.folderName)…",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit(send)
                .disabled(runner.isBusy)
            if compact && voice.isSpeaking {
                Button { voice.stopSpeaking() } label: { Image(systemName: "speaker.slash.fill").font(.system(size: 16)) }
                    .buttonStyle(.borderless).help("Dừng đọc")
            }
            if compact {
                Button {
                    if voice.isListening { voice.stopListening() } else {
                        voice.startListening { text in if !text.isEmpty { runner.send(text, byVoice: true) } }
                    }
                } label: {
                    Image(systemName: voice.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 17))
                        .foregroundStyle(voice.isListening ? Color.red : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(voice.isListening ? "Bấm để gửi" : "Bấm để nói (hoặc giữ ⌥Space)")
            }
            if runner.isBusy {
                Button { runner.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.borderless).help("Dừng (như Esc trong terminal)")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
            }
        }
        .padding(10)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty, !runner.isBusy else { return }
        let files = attachments
        draft = ""
        attachments = []
        runner.send(text, attachments: files)
    }

    // MARK: Đính kèm

    /// Ô ảnh / tệp sắp gửi + nút 📎 chọn tệp + ⌘⇧V dán ảnh từ clipboard.
    private var attachmentStrip: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { a in
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let t = a.thumbnail {
                            Image(nsImage: t).resizable().aspectRatio(contentMode: a.isImage ? .fill : .fit)
                        } else {
                            Image(systemName: "doc")
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
                    .help(a.url.path)
                    Button { attachments.removeAll { $0.id == a.id } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                }
            }
            Button { pickFiles() } label: { Image(systemName: "paperclip") }
                .buttonStyle(.borderless)
                .help("Đính kèm ảnh / tệp (hoặc kéo thả vào khung chat, ⌘⇧V để dán ảnh)")
            // ⌘⇧V: dán ảnh đang có trong clipboard (⌘V vẫn dán chữ như thường).
            Button("") { attachments += Attachment.fromPasteboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .opacity(0).frame(width: 0, height: 0)
            if !attachments.isEmpty {
                Text("\(attachments.count) tệp").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, attachments.isEmpty ? 6 : 10)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: runner.folder)
        panel.prompt = "Đính kèm"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { attachments += panel.urls.map(Attachment.make) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { attachments.append(Attachment.make(url)) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                // Ảnh kéo từ trình duyệt / app khác (không có tệp) → lưu PNG tạm.
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage, let url = Attachment.saveTemp(img) else { return }
                    DispatchQueue.main.async { attachments.append(Attachment.make(url)) }
                }
            }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - Thẻ xin quyền

struct PermissionCard: View {
    let item: ChatItem
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(item.text).font(.system(size: 12, weight: .semibold)).lineLimit(2)
            }
            if !item.diff.isEmpty {
                DiffView(lines: item.diff)
            } else if !item.detail.isEmpty {
                ScrollView {
                    Text(item.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(6)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            DecisionFooter(decision: item.decision) {
                Button("Từ chối") { decide(false) }
                Button("Cho phép") { decide(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.5)))
    }
}

struct DecisionFooter<Buttons: View>: View {
    let decision: ChatItem.Decision
    var answered: String = ""
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        switch decision {
        case .pending:
            HStack { Spacer(); buttons() }.controlSize(.small)
        case .allowed:
            Label(answered.isEmpty ? "Đã cho phép" : answered, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.green)
        case .denied:
            Label("Đã từ chối", systemImage: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red)
        case .cancelled:
            Label("Đã huỷ", systemImage: "minus.circle").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { l in
                    HStack(alignment: .top, spacing: 0) {
                        Text(prefix(l.kind)).foregroundStyle(color(l.kind)).frame(width: 14, alignment: .leading)
                        Text(l.text.isEmpty ? " " : l.text)
                            .foregroundStyle(l.kind == .header ? Color.primary : l.kind == .gap ? .secondary : color(l.kind))
                            .fontWeight(l.kind == .header ? .semibold : .regular)
                    }
                    .padding(.horizontal, 4)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .background(background(l.kind))
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 220)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private func prefix(_ k: DiffLine.Kind) -> String {
        switch k { case .added: return "+"; case .removed: return "−"; default: return " " }
    }
    private func color(_ k: DiffLine.Kind) -> Color {
        switch k { case .added: return .green; case .removed: return .red; default: return .primary }
    }
    private func background(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: return .green.opacity(0.12)
        case .removed: return .red.opacity(0.12)
        case .header: return .primary.opacity(0.06)
        default: return .clear
        }
    }
}

// MARK: - Thẻ câu hỏi (AskUserQuestion)

struct QuestionCard: View {
    let item: ChatItem
    let onAnswer: ([String: String]) -> Void
    let onSkip: () -> Void

    @State private var picked: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Claude hỏi bạn", systemImage: "questionmark.bubble.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
            ForEach(item.questions) { q in
                VStack(alignment: .leading, spacing: 5) {
                    Text(q.question).font(.system(size: 12, weight: .medium))
                    ForEach(q.options) { o in
                        Button { toggle(q, o.label) } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: icon(q, o.label)).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(o.label).font(.system(size: 12))
                                    if !o.description.isEmpty {
                                        Text(o.description).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(item.decision != .pending)
                    }
                    TextField("Khác…", text: Binding(get: { other[q.question, default: ""] },
                                                     set: { other[q.question] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .disabled(item.decision != .pending)
                }
            }
            DecisionFooter(decision: item.decision, answered: item.answerSummary) {
                Button("Bỏ qua") { onSkip() }
                Button("Gửi trả lời") { onAnswer(answers) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!item.questions.allSatisfy { !(answers[$0.question] ?? "").isEmpty })
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.blue.opacity(0.4)))
    }

    private var answers: [String: String] {
        var out: [String: String] = [:]
        for q in item.questions {
            var values = q.options.map(\.label).filter { picked[q.question]?.contains($0) == true }
            let extra = other[q.question, default: ""].trimmingCharacters(in: .whitespaces)
            if !extra.isEmpty { values.append(extra) }
            out[q.question] = values.joined(separator: ", ")
        }
        return out
    }

    private func toggle(_ q: AskQuestion, _ label: String) {
        var set = picked[q.question] ?? []
        if q.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
            other[q.question] = ""
        }
        picked[q.question] = set
    }

    private func icon(_ q: AskQuestion, _ label: String) -> String {
        let on = picked[q.question]?.contains(label) == true
        if q.multiSelect { return on ? "checkmark.square.fill" : "square" }
        return on ? "largecircle.fill.circle" : "circle"
    }
}

// MARK: - Chọn phiên cũ

/// Danh sách phiên Claude Code cũ của thư mục — bấm để resume.
struct SessionPicker: View {
    let folder: String
    let current: String?
    var root: String? = nil
    let onPick: (String) -> Void

    @State private var entries: [SessionHistory.Entry]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Phiên trong \((folder as NSString).lastPathComponent)")
                .font(.system(size: 12, weight: .semibold))
                .padding(10)
            Divider()
            if let entries {
                if entries.isEmpty {
                    Text("Chưa có phiên nào trong thư mục này.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(entries) { e in
                                Button { onPick(e.id) } label: { SessionEntryRow(entry: e, current: e.id == current) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(6)
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: 400)
        .task {
            let folder = folder, root = root
            entries = await Task.detached { SessionHistory.list(folder: folder, root: root) }.value
        }
    }
}

struct SessionEntryRow: View {
    let entry: SessionHistory.Entry
    let current: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: current ? "checkmark.circle.fill" : "bubble.left")
                .foregroundStyle(current ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 12)).lineLimit(2)
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(current ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

enum FolderPicker {
    static func pick(start: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: start)
        panel.prompt = "Chọn"
        panel.message = "Chọn thư mục làm việc cho Claude"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

extension PermissionMode {
    var color: Color {
        switch self {
        case .default: return .secondary
        case .acceptEdits: return .purple
        case .plan: return .teal
        case .auto: return .orange
        case .bypassPermissions, .dontAsk: return .red
        }
    }
}

/// Ảnh nhỏ / tên tệp đã gửi, hiện trên bong bóng tin nhắn của bạn. Bấm để mở.
struct SentAttachmentView: View {
    let url: URL
    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            if let img = NSImage(contentsOf: url), UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Label(url.lastPathComponent, systemImage: "doc")
                    .font(.system(size: 11)).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .help(url.path)
    }
}
