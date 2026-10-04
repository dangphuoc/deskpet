import Carbon

/// Phím tắt toàn cục qua Carbon — không cần quyền Accessibility. Nhận cả lúc nhấn và lúc thả phím.
final class HotKey {
    private struct Handlers { let press: () -> Void; let release: (() -> Void)? }
    private static var handlers: [UInt32: Handlers] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?

    init?(keyCode: Int, modifiers: Int, id: UInt32, onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) {
        HotKey.installHandlerOnce()
        HotKey.handlers[id] = Handlers(press: onPress, release: onRelease)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4450_4554), id: id) // 'DPET'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { return nil }
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard let h = HotKey.handlers[hk.id] else { return noErr }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { h.release?() } else { h.press() }
            return noErr
        }, 2, &specs, nil, nil)
    }
}
