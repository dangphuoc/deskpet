import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var detectedClaude = ClaudeLocator.find(custom: "") ?? "không tìm thấy"
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Nhân vật") {
                HStack(spacing: 12) {
                    ForEach(PetCharacter.allCases) { c in
                        Button { settings.character = c } label: {
                            VStack(spacing: 4) {
                                if let img = CharacterLibrary.image(c, .standing) {
                                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                                        .frame(width: 64, height: 64)
                                }
                                Text(c.displayName).font(.system(size: 11))
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(settings.character == c ? Color.accentColor.opacity(0.18) : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(settings.character == c ? Color.accentColor : .secondary.opacity(0.3)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Text("Kích thước")
                    Slider(value: $settings.petSize, in: 70...220, step: 10)
                    Text("\(Int(settings.petSize))").monospacedDigit().frame(width: 32)
                }
                Toggle("Thỉnh thoảng đi dạo", isOn: $settings.walkingEnabled)
                Toggle("Mở khi đăng nhập", isOn: Binding(get: { loginEnabled }, set: { on in
                    loginError = LoginItem.set(on)
                    loginEnabled = LoginItem.isEnabled
                }))
                if let loginError {
                    Text("Không bật được: \(loginError)").font(.system(size: 11)).foregroundStyle(.red)
                } else if loginEnabled && !LoginItem.isInstalled {
                    Text("Đang chạy bản trong thư mục build. Nên cài vào /Applications (./build.sh install) rồi bật lại công tắc này.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                HStack {
                    Text("Ngủ sau khi rảnh")
                    Slider(value: $settings.sleepAfterMinutes, in: 0.5...30, step: 0.5)
                    Text(String(format: "%.1f phút", settings.sleepAfterMinutes)).monospacedDigit().frame(width: 64)
                }
            }

            Section("Claude Code") {
                HStack {
                    TextField("Thư mục của trợ lý", text: $settings.assistantFolder)
                    Button("Chọn…") {
                        if let p = FolderPicker.pick(start: settings.assistantFolder) { settings.assistantFolder = p }
                    }
                    Button("Mở") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: (settings.assistantFolder as NSString).expandingTildeInPath))
                    }
                }
                Text("Trợ lý làm việc trong thư mục này. CLAUDE.md trong đó là trí nhớ của trợ lý — bạn sửa tự do.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Đường dẫn claude", text: $settings.claudePath, prompt: Text(detectedClaude))
                TextField("Model cho các phiên", text: $settings.model, prompt: Text("để trống = mặc định của Claude Code"))
                TextField("Model cho trợ lý", text: $settings.assistantModel, prompt: Text("vd: haiku (nhanh) · trống = như trên"))
                Text("Mặc định Claude không được tự sửa file hay chạy lệnh: mỗi lần cần quyền, bong bóng chat sẽ hỏi Cho phép / Từ chối. Các luật allow/deny trong settings.json của Claude Code vẫn được áp dụng.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Phiên ngoài DeskPet") {
                StatusHooksSettings(settings: settings)
            }

            Section("Điều khiển máy") {
                ComputerControlSettings(settings: settings)
            }

            Section("Giọng nói") {
                Toggle("Đọc to câu trả lời khi bạn hỏi bằng giọng nói", isOn: $settings.speakReplies)
                Text("Gõ phím thì trợ lý chỉ trả lời bằng chữ. Giữ ⌥ Space để nói, thả ra (hoặc ngừng nói) là gửi. Nhấn nhanh ⌥ Space để mở/đóng trợ lý. Lần đầu macOS sẽ hỏi quyền Micro và Nhận dạng giọng nói.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Tài khoản Claude") {
                ProfilesEditor(settings: settings)
            }

            Section("Phím tắt") {
                Text("⌥ Space — trợ lý · Giữ ⌥ Space — nói · Double-click nhân vật — bảng phiên · Bấm nhân vật khi có “!” — tới phiên cần bạn · Chuột phải — menu")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640) // Form tự cuộn — vừa màn hình nhỏ
    }
}

/// Danh sách hồ sơ tài khoản: chọn mặc định, đăng nhập, thêm / bỏ.
struct ProfilesEditor: View {
    @ObservedObject var settings: AppSettings
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(settings.profiles) { p in
                HStack(spacing: 8) {
                    Button { settings.defaultProfileId = p.id } label: {
                        Image(systemName: settings.defaultProfileId == p.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Dùng làm mặc định (trợ lý + phiên mới)")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.system(size: 12, weight: .medium))
                        Text(p.displayDir).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Đăng nhập…") { TerminalLauncher.openLogin(p) }
                        .help("Mở Terminal với hồ sơ này — gõ /login (hoặc /logout để đổi tài khoản)")
                    if !p.isSystem {
                        Button {
                            if settings.defaultProfileId == p.id { settings.defaultProfileId = AccountProfile.systemId }
                            settings.profiles.removeAll { $0.id == p.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Bỏ khỏi danh sách (không xoá thư mục \(p.displayDir))")
                    }
                }
                .controlSize(.small)
            }
            HStack {
                TextField("Tên hồ sơ mới, vd. Cá nhân", text: $newName)
                Button("Thêm") { add() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Mỗi hồ sơ là một thư mục cấu hình Claude Code riêng (CLAUDE_CONFIG_DIR): đăng nhập, settings, skills, lịch sử phiên đều riêng. Thêm xong bấm “Đăng nhập…”. Hồ sơ mặc định dùng cho trợ lý và phiên mới; mỗi phiên vẫn chọn được hồ sơ khi tạo.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let slug = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let dir = "~/.claude-" + (slug.isEmpty ? String(UUID().uuidString.prefix(6)).lowercased() : slug)
        settings.profiles.append(AccountProfile(id: UUID(), name: name, configDir: dir))
        newName = ""
    }
}

/// Bật/tắt nhanh từng nhóm quyền điều khiển máy của trợ lý + trạng thái quyền macOS.
struct ComputerControlSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var axGranted = ControlPolicy.accessibilityGranted
    @State private var screenGranted = ControlPolicy.screenRecordingGranted
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Cho trợ lý điều khiển máy", isOn: $settings.controlEnabled)
            ForEach(ControlGroup.allCases) { g in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Label(g.title, systemImage: g.icon).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Picker("", selection: Binding(get: { settings.controlMode(g) },
                                                      set: { settings.setControlMode($0, for: g) })) {
                            ForEach(ControlMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    }
                    Text(g.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .disabled(!settings.controlEnabled)
                .opacity(settings.controlEnabled ? 1 : 0.5)
            }
            Divider()
            permissionRow("Accessibility (chuột, bàn phím)", granted: axGranted) { ControlPolicy.requestAccessibility() }
            permissionRow("Screen Recording (chụp màn hình)", granted: screenGranted) { ControlPolicy.requestScreenRecording() }
            Text("“Hỏi trước” hiện thẻ Cho phép / Từ chối như các phiên khác; “Tự chạy” làm luôn không hỏi. Đổi là có hiệu lực ngay, kể cả từ menu 🐾 → Điều khiển máy. App ký ad-hoc nên sau mỗi lần build lại có thể phải cấp lại quyền (bỏ DeskPet khỏi danh sách trong System Settings rồi thêm lại).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onReceive(refresh) { _ in
            axGranted = ControlPolicy.accessibilityGranted
            screenGranted = ControlPolicy.screenRecordingGranted
        }
    }

    private func permissionRow(_ title: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(title).font(.system(size: 12))
            Spacer()
            if !granted { Button("Cấp quyền…", action: request).controlSize(.small) }
        }
    }
}

/// Bật/tắt hook báo trạng thái cho các phiên Claude Code chạy ngoài DeskPet.
struct StatusHooksSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var installed = false
    @State private var error: String?

    private var roots: [String] { settings.profiles.map(\.rootPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Theo dõi chính xác phiên chạy trong iTerm / Terminal", isOn: Binding(get: { installed }, set: { on in
                error = StatusHooks.setEnabled(on, roots: roots)
                installed = StatusHooks.isInstalled(roots: roots)
            }))
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            Text("Thêm hook nhỏ vào settings.json của Claude Code (mọi hồ sơ) để biết phiên ngoài DeskPet đang làm, chờ cho phép hay đã xong — pet báo như phiên trong DeskPet. Hook khác của bạn giữ nguyên; tắt là gỡ sạch. Chỉ áp dụng cho phiên mở SAU khi bật. Thêm hồ sơ mới thì tắt rồi bật lại.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear { installed = StatusHooks.isInstalled(roots: roots) }
    }
}
