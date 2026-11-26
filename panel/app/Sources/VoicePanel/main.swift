import AppKit
import Carbon
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var model: PanelModel!
    var signalSource: DispatchSourceSignal?
    var pidFile: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let config = LaunchConfig.fromArguments() else {
            let alert = NSAlert()
            alert.messageText = "Voice Panel"
            alert.informativeText = "Open it from Claude Code with /voice."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        model = PanelModel(config: config)

        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 440),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Claude Voice"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PanelView(model: model))
        panel.setFrameAutosaveName("VoicePanel")
        if !panel.setFrameUsingName("VoicePanel"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 360, y: f.maxY - 460))
        }
        panel.orderFrontRegardless()

        // ⌃⌥Space: mic on/off · ⌃⌥V: show/hide · ⌃⌥,: stop reading · ⌃⌥.: stop + interrupt
        let mods = controlKey | optionKey
        let a = HotKeys.register(id: 1, keyCode: kVK_Space, modifiers: mods) { [weak self] in self?.model.toggleMic() }
        HotKeys.register(id: 2, keyCode: kVK_ANSI_V, modifiers: mods) { [weak self] in self?.toggleVisible() }
        HotKeys.register(id: 3, keyCode: kVK_ANSI_Period, modifiers: mods) { [weak self] in self?.model.hush() }
        HotKeys.register(id: 4, keyCode: kVK_ANSI_Comma, modifiers: mods) { [weak self] in self?.model.stopReading() }
        if !a { model.add(.system, "Hotkeys are taken (another panel open?). Use the buttons here.") }

        // `voice-panel` sends SIGUSR1 to bring an already-open panel back.
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.show() }
        src.resume()
        signalSource = src

        let runDir = NSHomeDirectory() + "/.voice-panel/run"
        try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        pidFile = runDir + "/\(config.session).pid"
        try? "\(getpid())".write(toFile: pidFile!, atomically: true, encoding: .utf8)

        model.start()
    }

    func toggleVisible() { panel.isVisible ? panel.orderOut(nil) : show() }
    func show() { panel.orderFrontRegardless() }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        model?.shutdown()
        if let pidFile { try? FileManager.default.removeItem(atPath: pidFile) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
