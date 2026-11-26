import Carbon
import Foundation

/// Global hotkeys via Carbon (no Accessibility permission needed).
enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    @discardableResult
    static func register(id: UInt32, keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5650_4E4C), id: id)  // 'VPNL'
        return RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                                   GetApplicationEventTarget(), 0, &ref) == noErr
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKeys.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
