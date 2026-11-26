import AppKit
import Carbon
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Only the window's close button sets this. Closing quits the app, so nothing else
    /// (Esc, ⌘W, ⌘., stray close() calls) may close the panel.
    var closeButtonClicked = false

    override func cancelOperation(_ sender: Any?) {}   // NSPanel closes on Esc by default
    override func performClose(_ sender: Any?) {
        guard closeButtonClicked else { return }
        super.performClose(sender)
    }
    override func close() {
        guard closeButtonClicked else { return }
        super.close()
    }
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
        // Not movable by background: that turned text drags into window drags. The header is the drag handle.
        panel.isMovableByWindowBackground = false
        // Solid dark window: no translucency, so what's behind never blurs through.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = true
        panel.backgroundColor = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Take keyboard focus on any click, so ⌘C copies the panel's selection rather than going to the terminal.
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PanelView(model: model))
        if let closeButton = panel.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(closeButtonClicked)
        }
        panel.setFrameAutosaveName("VoicePanel")
        if !panel.setFrameUsingName("VoicePanel"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 360, y: f.maxY - 460))
        }
        // The saved frame may be the minimised bar from last time; always open full size.
        if panel.frame.height < Self.minExpandedHeight { setHeight(Self.defaultHeight) }
        panel.orderFrontRegardless()

        // Minimise / restore: shrink the window to the header bar, anchored at its top edge.
        // @Published fires before the value changes, so act on the next turn of the run loop.
        model.$compact.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyCompact() } }
            .store(in: &subscriptions)
        model.$compactHeight.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fitCompact() } }
            .store(in: &subscriptions)

        // ⌃⌥Space: mic on/off · ⌃⌥V: show/hide · ⌃⌥,: stop reading · ⌃⌥.: stop + interrupt
        let mods = controlKey | optionKey
        let a = HotKeys.register(id: 1, keyCode: kVK_Space, modifiers: mods) { [weak self] in self?.model.toggleMic() }
        HotKeys.register(id: 2, keyCode: kVK_ANSI_V, modifiers: mods) { [weak self] in self?.toggleVisible() }
        HotKeys.register(id: 3, keyCode: kVK_ANSI_Period, modifiers: mods) { [weak self] in self?.model.hush() }
        HotKeys.register(id: 4, keyCode: kVK_ANSI_Comma, modifiers: mods) { [weak self] in self?.model.stopReading() }
        HotKeys.register(id: 5, keyCode: kVK_ANSI_M, modifiers: mods) { [weak self] in self?.model.compact.toggle() }
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

    @objc private func closeButtonClicked() {
        panel.closeButtonClicked = true
        panel.performClose(nil)
    }

    func toggleVisible() { panel.isVisible ? panel.orderOut(nil) : show() }
    func show() { panel.orderFrontRegardless() }

    // MARK: - minimise

    static let minExpandedHeight: CGFloat = 260
    static let defaultHeight: CGFloat = 440
    private var subscriptions = Set<AnyCancellable>()
    private var expandedHeight = AppDelegate.defaultHeight

    /// Height of the title-bar strip above the SwiftUI content.
    private var titlebarInset: CGFloat { panel.frame.height - panel.contentLayoutRect.height }

    private func applyCompact() {
        if model.compact {
            expandedHeight = max(panel.frame.height, Self.minExpandedHeight)
            fitCompact()
        } else {
            panel.minSize = NSSize(width: 300, height: Self.minExpandedHeight)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            setHeight(expandedHeight)
        }
    }

    /// Size the minimised window to its content; re-run when a permission prompt appears or goes.
    private func fitCompact() {
        guard model.compact, model.compactHeight > 0 else { return }
        let h = (model.compactHeight + titlebarInset).rounded(.up)
        panel.minSize = NSSize(width: 300, height: h)
        panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: h)
        setHeight(h)
    }

    /// Resize keeping the top edge where it is.
    private func setHeight(_ h: CGFloat) {
        var f = panel.frame
        f.origin.y = f.maxY - h
        f.size.height = h
        panel.setFrame(f, display: true, animate: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        model?.shutdown()
        if let pidFile { try? FileManager.default.removeItem(atPath: pidFile) }
    }
}

/// No menu bar is shown (accessory app), but its key equivalents are what make ⌘C / ⌘V / ⌘X /
/// ⌘A / ⌘Z work in the panel. Deliberately no Close or Quit: only the close button closes it.
func editMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    appItem.submenu = NSMenu(title: "VoicePanel")
    main.addItem(appItem)
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    editItem.submenu = edit
    main.addItem(editItem)
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        .keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    return main
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.mainMenu = editMenu()
app.run()
