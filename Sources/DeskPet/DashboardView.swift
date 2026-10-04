import SwiftUI

/// Bảng phiên: quản lý nhiều phiên Claude Code chạy song song — thay cho 10 cửa sổ terminal.
struct DashboardView: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject var settings: AppSettings
    var actions: ChatActions

    @State private var renaming: SessionRunner?
    @State private var confirmCloseIdle = false
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 280)
                .background(.thinMaterial)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { manager.refreshExternal(force: true) }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in manager.refreshExternal() }
        .sheet(isPresented: $manager.requestNewSession) {
            NewSessionSheet(settings: settings) { folder, title, resume, prompt, profileId in
                manager.requestNewSession = false
                manager.create(folder: folder, title: title, resumeSessionId: resume, prompt: prompt, profileId: profileId)
            } onCancel: { manager.requestNewSession = false }
        }
        .alert("Đóng các phiên đang rảnh?", isPresented: $confirmCloseIdle) {
            Button("Huỷ", role: .cancel) {}
            Button("Đóng") { manager.closeIdleSessions() }
        } message: {
            Text("Các phiên không bận và không chờ bạn sẽ được bỏ khỏi danh sách. Lịch sử trò chuyện vẫn còn trong Claude Code — mở lại bằng “Phiên mới” → chọn project → chọn phiên cũ.")
        }
        .alert("Đổi tên phiên", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Tên", text: $renameText)
            Button("Huỷ", role: .cancel) { renaming = nil }
            Button("Lưu") {
                if let r = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    r.title = renameText
                    manager.renamed()
                }
                renaming = nil
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Phiên làm việc").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { manager.requestNewSession = true } label: { Label("Phiên mới", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("n", modifiers: .command)
                Menu {
                    Button("Đóng các phiên đang rảnh…") { confirmCloseIdle = true }
                        .disabled(!manager.runners.contains { !$0.isBusy && !$0.status.needsAttention })
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            // Trợ lý luôn ở đầu: nói "tạo phiên ở X", "clear đi", "đặt tên là Y"… các phiên hiện ra bên dưới.
            SidebarRow(runner: manager.assistant, selected: manager.selectedId == manager.assistant.id,
                       subtitle: "~/\((manager.assistant.folder as NSString).lastPathComponent) · tạo / điều phối phiên")
                .onTapGesture { manager.selectedId = manager.assistant.id }
                .padding(.horizontal, 8).padding(.top, 8)
            Divider().padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    section("Cần bạn", groups.attention, color: .orange)
                    section("Đang làm", groups.working, color: .blue)
                    section("Xong · chưa xem", groups.done, color: .green)
                    section("Khác", groups.rest, color: .secondary)
                    externalSection
                    if manager.runners.isEmpty && manager.externalSessions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 28)).foregroundStyle(.secondary)
                            Text("Chưa có phiên nào.\nNói với Trợ lý: “tạo phiên mới ở service-bank-v3”\nhoặc bấm “Phiên mới”.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(8)
            }
        }
    }

    private var groups: (attention: [SessionRunner], working: [SessionRunner], done: [SessionRunner], rest: [SessionRunner]) {
        var a: [SessionRunner] = [], w: [SessionRunner] = [], d: [SessionRunner] = [], r: [SessionRunner] = []
        for x in manager.runners {
            if x.status.needsAttention { a.append(x) }
            else if x.isBusy || x.status == .working { w.append(x) }
            else if x.unread && x.status == .done { d.append(x) }
            else { r.append(x) }
        }
        return (a, w, d, r.sorted { $0.lastActivity > $1.lastActivity })
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [SessionRunner], color: Color) -> some View {
        if !list.isEmpty {
            Text("\(title) · \(list.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
            ForEach(list) { r in
                SidebarRow(runner: r, selected: manager.selectedId == r.id)
                    .onTapGesture { manager.selectedId = r.id }
                    .contextMenu {
                        Button("Đổi tên…") { renameText = r.title; renaming = r }
                        Button("Mở trong Terminal") { actions.openInTerminal(r) }.disabled(r.isBusy)
                        Button("Bật Remote Control") { actions.remoteControl(r) }.disabled(r.isBusy)
                        Button("Mở thư mục trong Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.folder)])
                        }
                        Divider()
                        Button("Đóng phiên (vẫn giữ lịch sử)") { manager.close(r) }
                    }
            }
        }
    }

    @ViewBuilder
    private var externalSection: some View {
        if !manager.externalSessions.isEmpty {
            HStack(spacing: 4) {
                Text("Ngoài DeskPet · \(manager.externalSessions.count)")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.purple)
                if !FileManager.default.fileExists(atPath: StatusHooks.dir.path) {
                    Image(systemName: "info.circle").font(.system(size: 9)).foregroundStyle(.secondary)
                        .help("Trạng thái đang là ước đoán. Bật Cài đặt → Phiên ngoài DeskPet → “Theo dõi chính xác” để biết chính xác.")
                }
            }
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
            ForEach(manager.externalSessions) { e in
                ExternalRow(info: e, selected: manager.selectedExternalPid == e.pid)
                    .onTapGesture(count: 2) { if let tty = e.tty { ExternalSessions.focus(app: e.app, tty: tty) } }
                    .onTapGesture { manager.selectedExternalPid = e.pid }
                    .contextMenu {
                        Button("Mở tab trong \(e.app)") { if let tty = e.tty { ExternalSessions.focus(app: e.app, tty: tty) } }
                            .disabled(!e.canType)
                        Button("Mở thư mục trong Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.folder)])
                        }
                    }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let pid = manager.selectedExternalPid {
            if let e = manager.externalSessions.first(where: { $0.pid == pid }) {
                ExternalDetailView(info: e)
            } else {
                Text("Phiên này đã đóng.").foregroundStyle(.secondary)
            }
        } else if let id = manager.selectedId, let r = manager.runner(id) {
            ChatView(runner: r, settings: settings, compact: false, actions: actions)
                .id(r.id)
        } else {
            VStack(spacing: 10) {
                if let img = CharacterLibrary.image(settings.character, .pointing) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(height: 120)
                }
                Text("Chọn một phiên bên trái, hoặc tạo phiên mới (⌘N).").foregroundStyle(.secondary)
            }
        }
    }
}

struct SidebarRow: View {
    @ObservedObject var runner: SessionRunner
    let selected: Bool
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(dotColor).frame(width: 9, height: 9)
                if runner.isBusy && !runner.status.needsAttention {
                    Circle().stroke(dotColor.opacity(0.4), lineWidth: 3).frame(width: 15, height: 15)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if runner.isAssistant { Image(systemName: "sparkles").font(.system(size: 10)) }
                    Text(runner.title).font(.system(size: 12, weight: runner.unread ? .semibold : .regular)).lineLimit(1)
                    if runner.remoteControlOn {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 10)).foregroundStyle(.purple)
                    } else if runner.openedInTerminal {
                        Image(systemName: "apple.terminal").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Text((subtitle ?? "\(runner.folderName) · \(runner.status.needsAttention || runner.isBusy ? runner.statusText : runner.status.label)")
                     + (AppSettings.shared.profiles.count > 1 ? " · 👤 \(runner.profile.name)" : ""))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(ShortTime.since(runner.lastActivity)).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private var dotColor: Color {
        switch runner.status {
        case .needsPermission, .needsAnswer: return .orange
        case .working: return .blue
        case .done: return runner.unread ? .green : .gray.opacity(0.5)
        case .error: return .red
        case .idle: return .gray.opacity(0.5)
        }
    }
}

// MARK: - Phiên ngoài DeskPet

private extension StatusHooks.State.Kind {
    var color: Color {
        switch self {
        case .permission: return .orange
        case .working: return .blue
        case .done: return .green
        case .idle, .ended: return .gray.opacity(0.5)
        }
    }
}

struct ExternalRow: View {
    let info: ExternalSessions.Info
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(info.kind.color).frame(width: 9, height: 9)
                if info.kind == .working {
                    Circle().stroke(info.kind.color.opacity(0.4), lineWidth: 3).frame(width: 15, height: 15)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "apple.terminal").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(info.title).font(.system(size: 12)).lineLimit(1)
                }
                Text("\(info.folderName) · \(info.app) · \(info.statusLabel)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let d = info.lastActivity {
                Text(ShortTime.since(d)).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Xem phiên chạy ngoài DeskPet (đọc transcript) + gõ thẳng vào tab iTerm/Terminal của nó.
struct ExternalDetailView: View {
    let info: ExternalSessions.Info
    @State private var items: [ChatItem] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var result: (text: String, isError: Bool)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(verbatim: "\(info.folder) · \(info.app) · pid \(info.pid)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Text(info.statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(info.kind.color.opacity(0.18), in: Capsule())
                if info.canType, let tty = info.tty {
                    Button("Mở tab trong \(info.app)") { ExternalSessions.focus(app: info.app, tty: tty) }
                }
            }
            .padding(12)

            if info.kind == .permission {
                HStack {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text("Phiên đang chờ bạn cho phép — trả lời ngay trong \(info.app).").font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if items.isEmpty {
                            Text("Chưa đọc được nội dung phiên.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(items) { ExternalItemRow(item: $0) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: items.count) { _ in proxy.scrollTo("bottom") }
            }
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if info.canType {
                    HStack(alignment: .bottom) {
                        TextField("Gõ vào phiên — gửi sang tab \(info.app)…", text: $draft, axis: .vertical)
                            .lineLimit(1...4).textFieldStyle(.roundedBorder)
                            .onSubmit(send)
                        Button(sending ? "Đang gửi…" : "Gửi", action: send)
                            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let result {
                        Text(result.text).font(.system(size: 11)).foregroundStyle(result.isError ? .red : .secondary)
                    }
                } else {
                    Text("Phiên đang chạy trong \(info.app) — DeskPet chỉ xem được. Muốn điều khiển: thoát phiên ở đó rồi mở lại trong DeskPet (Phiên mới → chọn project → chọn phiên cũ).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        // Transcript đổi (lastActivity mới) → đọc lại.
        .task(id: "\(info.pid)-\(info.lastActivity?.timeIntervalSince1970 ?? 0)") {
            let i = info
            items = await Task.detached { ExternalSessions.recent(i, limit: 60) }.value
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        let i = info
        Task {
            let r = await Task.detached { ExternalSessions.send(text, to: i) }.value
            sending = false
            switch r {
            case .success(let msg): result = (msg, false); draft = ""
            case .failure(let e): result = (e.text, true)
            }
        }
    }
}

struct ExternalItemRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(item.text).font(.system(size: 12)).textSelection(.enabled)
                    .padding(8).background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
        case .tool:
            Label("\(item.text)\(item.detail.isEmpty ? "" : " — \(item.detail)")", systemImage: item.icon.isEmpty ? "wrench" : item.icon)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        default:
            Text(.init(item.text)).font(.system(size: 12)).textSelection(.enabled)
        }
    }
}

// MARK: - Tạo phiên mới

struct NewSessionSheet: View {
    @ObservedObject var settings: AppSettings
    let onCreate: (_ folder: String, _ title: String?, _ resume: String?, _ prompt: String?, _ profileId: UUID) -> Void
    let onCancel: () -> Void

    @State private var profileId: UUID = AppSettings.shared.defaultProfileId
    private var root: String { settings.profile(profileId).rootPath }

    @State private var projects: [ProjectIndex.Project]?
    @State private var query = ""
    @State private var folder: String?
    @State private var sessions: [SessionHistory.Entry]?
    @State private var resumeId: String?
    @State private var title = ""
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Phiên mới").font(.system(size: 15, weight: .semibold))
                Spacer()
                if settings.profiles.count > 1 {
                    Picker("Tài khoản", selection: $profileId) {
                        ForEach(settings.profiles) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 220)
                    .onChange(of: profileId) { _ in
                        projects = nil
                        if let f = folder { pick(f) }
                        let r = root
                        Task { projects = await Task.detached { ProjectIndex.recent(limit: 40, root: r) }.value }
                    }
                }
            }

            if let folder {
                HStack {
                    Label(folder, systemImage: "folder.fill").font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Đổi") { self.folder = nil; sessions = nil; resumeId = nil }
                }
                Text("Tiếp tục phiên cũ hay bắt đầu mới?").font(.system(size: 12, weight: .medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Button { resumeId = nil } label: {
                            HStack(spacing: 8) {
                                Image(systemName: resumeId == nil ? "largecircle.fill.circle" : "circle").foregroundStyle(Color.accentColor)
                                Text("Phiên mới").font(.system(size: 12, weight: .medium))
                                Spacer()
                            }
                            .padding(6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if let sessions {
                            ForEach(sessions) { e in
                                Button { resumeId = e.id } label: { SessionEntryRow(entry: e, current: resumeId == e.id) }
                                    .buttonStyle(.plain)
                            }
                        } else {
                            ProgressView().controlSize(.small).padding(8)
                        }
                    }
                }
                .frame(height: 170)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                TextField("Tên phiên (tuỳ chọn)", text: $title).textFieldStyle(.roundedBorder)
                TextField("Yêu cầu đầu tiên (tuỳ chọn)", text: $prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("Tìm project…", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if let projects {
                            ForEach(filtered(projects)) { p in
                                Button { pick(p.folder) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder").foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(p.name).font(.system(size: 12, weight: .medium))
                                            Text(p.folder).font(.system(size: 10)).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.head)
                                        }
                                        Spacer()
                                        Text("\(p.sessionCount) phiên").font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }
                                    .padding(6).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            ProgressView().controlSize(.small).padding(8)
                        }
                    }
                }
                .frame(height: 260)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                Button("Chọn thư mục khác…") {
                    if let p = FolderPicker.pick(start: NSHomeDirectory()) { pick(p) }
                }
            }

            HStack {
                Spacer()
                Button("Huỷ", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button(resumeId == nil ? "Tạo phiên" : "Tiếp tục phiên") {
                    guard let folder else { return }
                    let t = title.trimmingCharacters(in: .whitespaces)
                    let titleFromHistory = sessions?.first { $0.id == resumeId }.map { String($0.title.prefix(40)) }
                    onCreate(folder, t.isEmpty ? titleFromHistory : t, resumeId, prompt, profileId)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folder == nil)
            }
        }
        .padding(18)
        .frame(width: 480)
        .task {
            let r = root
            projects = await Task.detached { ProjectIndex.recent(limit: 40, root: r) }.value
        }
    }

    private func filtered(_ list: [ProjectIndex.Project]) -> [ProjectIndex.Project] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? list : list.filter { $0.folder.lowercased().contains(q) }
    }

    private func pick(_ path: String) {
        folder = SessionHistory.normalize(path)
        sessions = nil
        resumeId = nil
        let f = folder!, r = root
        Task { sessions = await Task.detached { SessionHistory.list(folder: f, limit: 20, root: r) }.value }
    }
}

/// "vừa xong", "5 phút", "2 giờ", "3 ngày" — gọn cho cột phiên.
enum ShortTime {
    static func since(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "vừa xong" }
        if s < 3600 { return "\(s / 60) phút" }
        if s < 86400 { return "\(s / 3600) giờ" }
        return "\(s / 86400) ngày"
    }
}
