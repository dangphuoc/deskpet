import AppKit
import SwiftUI
import Combine
import Carbon
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let settings = AppSettings.shared
    private let pet = PetModel()
    private let manager = SessionManager.shared
    private let voice = VoiceController.shared
    private var hotKeyDown = false
    private var holdWork: DispatchWorkItem?
    private var holdingToTalk = false

    private var petPanel: PetPanel!
    private var chatPanel: ChatPanel!
    private var toastPanel: ToastPanel!
    private var dashboardWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()

    private var tickTimer: Timer?
    private var walkTimer: Timer?
    private var walkTargetX: CGFloat = 0
    private var isDragging = false
    private var toastHideWork: DispatchWorkItem?

    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupEditMenu()
        setupPetPanel()
        setupChatPanel()
        toastPanel = ToastPanel()
        setupStatusItem()
        setupNotifications()

        manager.isVisible = { [weak self] id in self?.isShowing(id) ?? false }
        manager.onAlert = { [weak self] a in self?.present(a) }
        manager.onFinished = { [weak self] r, ok in
            guard let self else { return }
            self.stopWalk()
            self.pet.handle(ok ? .done : .failed)
            // Chỉ đọc to khi bạn hỏi bằng giọng nói — gõ phím thì trả lời bằng chữ thôi.
            if r.isAssistant, ok, r.lastTurnByVoice, self.settings.speakReplies, !self.voice.isListening {
                self.voice.speak(r.lastTurnReply)
            }
        }
        manager.onFocusRequest = { [weak self] id in self?.showDashboard(select: id) }
        manager.onExternalFinished = { [weak self] in
            self?.stopWalk()
            self?.pet.handle(.done)
        }
        manager.externalMonitor.onChange = { [weak manager] e in manager?.receiveExternal(e) }
        manager.externalMonitor.start()
        manager.dashboardVisible = { [weak self] in self?.dashboardWindow?.isVisible == true }
        manager.$alert.receive(on: RunLoop.main).sink { [weak self] a in
            if a == nil { self?.hideToast() }
            self?.updateStatusButton()
        }.store(in: &cancellables)

        // Nhấn nhanh ⌥Space: mở/đóng trợ lý. Giữ ⌥Space: nói, thả ra là gửi.
        hotKey = HotKey(keyCode: kVK_Space, modifiers: optionKey, id: 1,
                        onPress: { [weak self] in self?.hotKeyPressed() },
                        onRelease: { [weak self] in self?.hotKeyReleased() })
        if hotKey == nil { NSLog("DeskPet: không đăng ký được phím tắt ⌥Space") }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }

        settings.$petSize.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.resizePet() }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.shutdownAll()
    }

    /// Phiên này đang hiện trước mắt người dùng?
    private func isShowing(_ id: UUID) -> Bool {
        guard NSApp.isActive || chatPanel.isKeyWindow else { return false }
        if id == manager.assistant.id && chatPanel.isVisible { return true }
        if let w = dashboardWindow, w.isVisible, w.isKeyWindow, manager.selectedId == id { return true }
        return false
    }

    // MARK: - Pet window

    private var petWindowSize: NSSize {
        let s = CGFloat(settings.petSize)
        return NSSize(width: s * 1.6, height: s * 1.55)
    }

    private func setupPetPanel() {
        petPanel = PetPanel(size: petWindowSize)
        let interaction = PetInteractionView(frame: NSRect(origin: .zero, size: petWindowSize))
        interaction.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: PetView(model: pet, settings: settings))
        host.frame = interaction.bounds
        host.autoresizingMask = [.width, .height]
        interaction.addSubview(host)
        interaction.onDoubleClick = { [weak self] in self?.toggleDashboard() }
        interaction.onClick = { [weak self] in
            guard let self else { return }
            self.pet.poke()
            // Đang có việc cần bạn → bấm pet là tới thẳng phiên đó.
            if let a = self.manager.alert { self.open(alert: a) }
        }
        interaction.onDragBegan = { [weak self] in
            self?.isDragging = true
            self?.stopWalk()
            self?.pet.poke()
        }
        interaction.onDragEnded = { [weak self] in
            self?.isDragging = false
            self?.savePetPosition()
        }
        interaction.contextMenu = { [weak self] in self?.buildMenu() }
        petPanel.contentView = interaction

        if let saved = UserDefaults.standard.string(forKey: "petOrigin") {
            petPanel.setFrameOrigin(NSPointFromString(saved))
        } else if let vf = NSScreen.main?.visibleFrame {
            petPanel.setFrameOrigin(NSPoint(x: vf.maxX - petWindowSize.width - 40, y: vf.minY))
        }
        clampPetOnScreen()
        petPanel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: petPanel, queue: .main) { [weak self] _ in
            self?.positionChat()
            self?.positionToast()
        }
    }

    private func resizePet() {
        let old = petPanel.frame
        let size = petWindowSize
        petPanel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.minY, width: size.width, height: size.height), display: true)
        clampPetOnScreen()
    }

    private func savePetPosition() {
        UserDefaults.standard.set(NSStringFromPoint(petPanel.frame.origin), forKey: "petOrigin")
    }

    private func clampPetOnScreen() {
        let f = petPanel.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let x = min(max(f.minX, vf.minX - f.width * 0.2), vf.maxX - f.width * 0.8)
        let y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        petPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Nhịp sống: đồng bộ tâm trạng pet với các phiên + đi dạo

    private func tick() {
        // Đang nghe thì giữ tư thế nghe, không để trạng thái phiên đè lên.
        if voice.isListening {
            if pet.mood != .listening { stopWalk(); pet.handle(.listening) }
            return
        }
        if pet.mood == .listening { pet.handle(.idle) }
        switch manager.aggregate {
        case .attention:
            if pet.mood != .permission { stopWalk(); pet.handle(.permission) }
        case .working:
            switch pet.mood {
            case .idle, .sleeping, .walking, .permission: stopWalk(); pet.handle(.thinking)
            default: break
            }
        case .none:
            pet.handle(.idle)
        }
        updateStatusButton()

        let canWalk = settings.walkingEnabled && !isDragging && !chatPanel.isVisible && !pet.busy && !toastPanel.isVisible
        if pet.tick(sleepAfter: settings.sleepAfterMinutes * 60, canWalk: canWalk) {
            startWalk()
        }
    }

    private func startWalk() {
        guard let vf = (petPanel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let w = petPanel.frame.width
        let current = petPanel.frame.minX
        let distance = CGFloat.random(in: 80...260) * (Bool.random() ? 1 : -1)
        walkTargetX = min(max(current + distance, vf.minX), vf.maxX - w)
        guard abs(walkTargetX - current) > 20 else { pet.stopWalking(); return }
        pet.startWalking(left: walkTargetX < current)
        walkTimer?.invalidate()
        walkTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.walkStep() }
    }

    private func walkStep() {
        guard pet.mood == .walking else { stopWalk(); return }
        let speed = CGFloat(settings.petSize) * 0.5 / 60
        var o = petPanel.frame.origin
        let dx = walkTargetX - o.x
        if abs(dx) <= speed {
            o.x = walkTargetX
            petPanel.setFrameOrigin(o)
            stopWalk()
            savePetPosition()
        } else {
            o.x += dx > 0 ? speed : -speed
            petPanel.setFrameOrigin(o)
        }
    }

    private func stopWalk() {
        walkTimer?.invalidate()
        walkTimer = nil
        pet.stopWalking()
    }

    // MARK: - Menu Edit (copy/paste)

    /// App không có Dock nên không hiện menu bar, nhưng phím tắt ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z chỉ chạy khi có
    /// menu Edit trong `NSApp.mainMenu` — thiếu nó thì ô nhập không copy/paste được.
    private func setupEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Thoát DeskPet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Hoàn tác", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Làm lại", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cắt", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Chép", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Dán", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Chọn tất cả", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - Giọng nói (giữ ⌥Space)

    private func hotKeyPressed() {
        guard !hotKeyDown else { return } // bỏ qua lặp phím
        hotKeyDown = true
        let work = DispatchWorkItem { [weak self] in self?.beginVoice() }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func hotKeyReleased() {
        hotKeyDown = false
        holdWork?.cancel()
        if holdingToTalk {
            holdingToTalk = false
            voice.stopListening()
        } else {
            toggleChat()
        }
    }

    private func beginVoice() {
        guard hotKeyDown else { return }
        holdingToTalk = true
        voice.stopSpeaking()
        showChat()
        voice.startListening { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.manager.assistant.send(text, byVoice: true)
        }
    }

    // MARK: - Trợ lý (bong bóng cạnh pet)

    private var chatActions: ChatActions {
        ChatActions(close: { [weak self] in self?.hideChat() },
                    openSettings: { [weak self] in self?.openSettings() },
                    openDashboard: { [weak self] in self?.hideChat(); self?.showDashboard(select: nil) },
                    openInTerminal: { [weak self] r in self?.openInTerminal(r) },
                    remoteControl: { [weak self] r in self?.openInTerminal(r, remoteControl: true) })
    }

    private func setupChatPanel() {
        chatPanel = ChatPanel()
        chatPanel.onEscape = { [weak self] in self?.hideChat() }
        let view = ChatView(runner: manager.assistant, settings: settings, compact: true, actions: chatActions)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        chatPanel.contentView = NSHostingView(rootView: view)
    }

    @objc func toggleChat() {
        chatPanel.isVisible ? hideChat() : showChat()
    }

    @objc func showChat() {
        stopWalk()
        pet.poke()
        positionChat()
        NSApp.activate(ignoringOtherApps: true)
        chatPanel.makeKeyAndOrderFront(nil)
        manager.assistant.markSeen()
    }

    private func hideChat() {
        voice.stopSpeaking()
        if voice.isListening { voice.stopListening() }
        chatPanel.orderOut(nil)
    }

    private func positionChat() {
        guard chatPanel != nil else { return }
        let p = petPanel.frame
        let size = chatPanel.frame.size
        guard let vf = (petPanel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var origin: NSPoint
        if p.maxY - 10 + size.height <= vf.maxY {
            origin = NSPoint(x: p.midX - size.width / 2, y: p.maxY - 10)
        } else if p.minX - size.width >= vf.minX {
            origin = NSPoint(x: p.minX - size.width + 10, y: p.maxY - size.height)
        } else {
            origin = NSPoint(x: p.maxX - 10, y: p.maxY - size.height)
        }
        origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
        origin.y = min(max(origin.y, vf.minY + 4), vf.maxY - size.height - 4)
        chatPanel.setFrameOrigin(origin)
    }

    // MARK: - Bảng phiên

    @objc func toggleDashboard() {
        if let w = dashboardWindow, w.isVisible, w.isKeyWindow { w.orderOut(nil) } else { showDashboard(select: nil) }
    }

    private func showDashboard(select id: UUID?) {
        if let id { manager.selectedId = id }
        if dashboardWindow == nil {
            let view = DashboardView(manager: manager, settings: settings, actions: chatActions)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "DeskPet — Bảng phiên"
            w.titlebarAppearsTransparent = true
            w.contentView = NSHostingView(rootView: view)
            w.minSize = NSSize(width: 760, height: 460)
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace]
            w.setFrameAutosaveName("DeskPetDashboard")
            if !w.setFrameUsingName("DeskPetDashboard") { w.center() }
            dashboardWindow = w
        }
        stopWalk()
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
        if let sel = manager.selectedId { manager.runner(sel)?.markSeen() }
        if let a = manager.alert, a.runnerId == manager.selectedId, a.kind == .done || a.kind == .failed {
            manager.dismissAlert()
        }
    }

    // MARK: - Thông báo (toast cạnh pet + thông báo macOS)

    private func present(_ a: SessionManager.Alert) {
        showToast(a)
        postNotification(a)
        updateStatusButton()
    }

    private func open(alert a: SessionManager.Alert) {
        manager.dismissAlert()
        if let ext = a.external { ExternalSessions.focus(app: ext.app, tty: ext.tty); return }
        if a.runnerId == manager.assistant.id { showChat() } else { showDashboard(select: a.runnerId) }
    }

    private func showToast(_ a: SessionManager.Alert) {
        toastHideWork?.cancel()
        let view = ToastView(alert: a, onOpen: { [weak self] in self?.open(alert: a) },
                             onClose: { [weak self] in
                                 self?.hideToast()
                                 if a.kind == .done || a.kind == .failed { self?.manager.dismissAlert() }
                             })
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        toastPanel.contentView = host
        toastPanel.setContentSize(host.fittingSize)
        positionToast()
        toastPanel.orderFrontRegardless()
        stopWalk()
        // "Xong" tự ẩn; "cần cho phép" ở lại tới khi được xử lý.
        if a.kind == .done || a.kind == .failed {
            let work = DispatchWorkItem { [weak self] in
                self?.hideToast()
                if self?.manager.alert == a { self?.manager.dismissAlert() }
            }
            toastHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        }
    }

    private func hideToast() {
        toastHideWork?.cancel()
        toastPanel?.orderOut(nil)
    }

    private func positionToast() {
        guard let toastPanel, toastPanel.isVisible || toastPanel.contentView != nil else { return }
        let p = petPanel.frame
        let size = toastPanel.frame.size
        guard let vf = (petPanel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var origin = NSPoint(x: p.midX - size.width / 2, y: p.maxY - 6)
        if origin.y + size.height > vf.maxY { origin.y = p.minY - size.height }
        origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
        toastPanel.setFrameOrigin(origin)
    }

    private func setupNotifications() {
        guard notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(_ a: SessionManager.Alert) {
        guard notificationsAvailable, !isShowing(a.runnerId) else { return }
        let content = UNMutableNotificationContent()
        content.title = a.title
        content.body = a.body
        content.userInfo = ["runnerId": a.runnerId.uuidString]
        if let ext = a.external { content.userInfo["externalApp"] = ext.app; content.userInfo["externalTty"] = ext.tty }
        if a.kind == .permission || a.kind == .question { content.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: a.runnerId.uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let app = info["externalApp"] as? String, let tty = info["externalTty"] as? String {
            ExternalSessions.focus(app: app, tty: tty)
        } else if let s = info["runnerId"] as? String, let id = UUID(uuidString: s) {
            DispatchQueue.main.async {
                if id == self.manager.assistant.id { self.showChat() } else { self.showDashboard(select: id) }
            }
        }
        completionHandler()
    }

    // MARK: - Terminal

    private func openInTerminal(_ r: SessionRunner, remoteControl: Bool = false) {
        TerminalLauncher.open(r, remoteControl: remoteControl)
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "DeskPet")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusButton() {
        let n = manager.attentionCount
        statusItem?.button?.title = n > 0 ? " \(n)" : ""
        statusItem?.button?.contentTintColor = n > 0 ? .systemOrange : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu().items { item.menu?.removeItem(item); menu.addItem(item) }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let waiting = manager.runners.filter { $0.status.needsAttention }
        if !waiting.isEmpty {
            let header = NSMenuItem(title: "Cần bạn", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for r in waiting {
                let mi = item("\(r.title) — \(r.status.label)", #selector(focusRunner(_:)))
                mi.representedObject = r.id.uuidString
                mi.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }
        menu.addItem(item("Trợ lý", #selector(showChat), key: " ", mods: [.option]))
        let working = manager.runners.filter { $0.isBusy }.count
        menu.addItem(item("Bảng phiên" + (working > 0 ? " (\(working) đang làm)" : ""), #selector(openDashboardFromMenu)))
        menu.addItem(item("Phiên mới…", #selector(newSessionFromMenu)))
        menu.addItem(item("Trí nhớ của trợ lý (CLAUDE.md)", #selector(openAssistantMemory)))
        menu.addItem(controlMenuItem())
        menu.addItem(.separator())

        let charItem = NSMenuItem(title: "Nhân vật", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for c in PetCharacter.allCases {
            let mi = item(c.displayName, #selector(pickCharacter(_:)))
            mi.representedObject = c.rawValue
            mi.state = settings.character == c ? .on : .off
            if let img = CharacterLibrary.image(c, .standing) {
                let thumb = NSImage(size: NSSize(width: 18, height: 18))
                thumb.lockFocus()
                img.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
                thumb.unlockFocus()
                mi.image = thumb
            }
            sub.addItem(mi)
        }
        charItem.submenu = sub
        menu.addItem(charItem)

        let walk = item("Đi dạo", #selector(toggleWalking))
        walk.state = settings.walkingEnabled ? .on : .off
        menu.addItem(walk)
        menu.addItem(item("Cài đặt…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Thoát DeskPet", #selector(quit), key: "q"))
        return menu
    }

    /// Menu "Điều khiển máy": công tắc tổng + mức quyền từng nhóm, đổi nhanh không cần mở Cài đặt.
    private func controlMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Điều khiển máy" + (settings.controlEnabled ? "" : " (tắt)"), action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: nil)
        let sub = NSMenu()
        let master = item("Cho trợ lý điều khiển máy", #selector(toggleControl))
        master.state = settings.controlEnabled ? .on : .off
        sub.addItem(master)
        sub.addItem(.separator())
        for g in ControlGroup.allCases {
            let current = settings.controlMode(g)
            let gi = NSMenuItem(title: "\(g.title) — \(current.label)", action: nil, keyEquivalent: "")
            gi.image = NSImage(systemSymbolName: g.icon, accessibilityDescription: nil)
            gi.isEnabled = settings.controlEnabled
            let modes = NSMenu()
            for m in ControlMode.allCases {
                let mi = item(m.label, #selector(pickControlMode(_:)))
                mi.representedObject = "\(g.rawValue):\(m.rawValue)"
                mi.state = current == m ? .on : .off
                modes.addItem(mi)
            }
            gi.submenu = modes
            sub.addItem(gi)
        }
        root.submenu = sub
        return root
    }

    @objc private func toggleControl() { settings.controlEnabled.toggle() }

    @objc private func pickControlMode(_ sender: NSMenuItem) {
        guard let parts = (sender.representedObject as? String)?.split(separator: ":"), parts.count == 2,
              let g = ControlGroup(rawValue: String(parts[0])), let m = ControlMode(rawValue: String(parts[1])) else { return }
        settings.setControlMode(m, for: g)
    }

    private func item(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = mods
        mi.target = self
        return mi
    }

    @objc private func focusRunner(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let id = UUID(uuidString: s) { showDashboard(select: id) }
    }

    @objc private func openDashboardFromMenu() { showDashboard(select: nil) }

    @objc private func newSessionFromMenu() {
        showDashboard(select: nil)
        manager.requestNewSession = true
    }

    @objc private func openAssistantMemory() {
        let home = SessionManager.prepareAssistantFolder(settings.assistantFolder)
        NSWorkspace.shared.open(URL(fileURLWithPath: home).appendingPathComponent("CLAUDE.md"))
    }

    @objc private func pickCharacter(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let c = PetCharacter(rawValue: raw) {
            settings.character = c
            pet.poke()
        }
    }

    @objc private func toggleWalking() {
        settings.walkingEnabled.toggle()
        if !settings.walkingEnabled { stopWalk() }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings)))
            w.title = "Cài đặt DeskPet"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        manager.shutdownAll()
        NSApp.terminate(nil)
    }
}
