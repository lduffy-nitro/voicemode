import AVFoundation
import Foundation
import SwiftUI

struct LaunchConfig {
    var session: String
    var transcript: String
    var cwd: String
    var node: String
    var brainScript: String
    var claude: String?
    var path: String?
    var vmPython: String

    static func fromArguments() -> LaunchConfig? {
        var a: [String: String] = [:]
        let argv = CommandLine.arguments
        var i = 1
        while i + 1 < argv.count {
            if argv[i].hasPrefix("--") { a[String(argv[i].dropFirst(2))] = argv[i + 1]; i += 2 } else { i += 1 }
        }
        guard let s = a["session"], let t = a["transcript"], let n = a["node"], let b = a["brain"],
              let py = a["voicemode-python"] else { return nil }
        return LaunchConfig(session: s, transcript: t, cwd: a["cwd"] ?? NSHomeDirectory(),
                            node: n, brainScript: b, claude: a["claude"], path: a["path"], vmPython: py)
    }
}

struct Entry: Identifiable {
    enum Role { case you, claude, tool, permission, system }
    let id = UUID()
    let role: Role
    let text: String
}

enum PermissionMode: String, CaseIterable, Identifiable {
    case ask = "default", edits = "acceptEdits", auto = "auto", bypass = "bypassPermissions"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ask: return "Ask"
        case .edits: return "Accept edits"
        case .auto: return "Auto"
        case .bypass: return "Bypass (dangerous)"
        }
    }
    var short: String {
        switch self {
        case .ask: return "Ask"
        case .edits: return "Edits"
        case .auto: return "Auto"
        case .bypass: return "Bypass"
        }
    }
    var detail: String {
        switch self {
        case .ask: return "Ask before anything your settings don't already allow"
        case .edits: return "Auto-approve file edits; ask for commands"
        case .auto: return "A safety classifier approves routine actions; risky ones still ask"
        case .bypass: return "Approve everything without asking"
        }
    }
}

struct PermissionAsk {
    let id: String
    let tool: String
    let summary: String
}

final class PanelModel: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var micOn = false
    @Published var hearing = false
    @Published var speaking = false
    @Published var thinking = false
    @Published var heardSoFar = ""   // live partial transcript of what you're saying
    @Published var autoScreen = false
    @Published var pending: PermissionAsk?
    @Published var ready = false
    @Published var draft = ""
    @Published var compact = false          // minimised to the header bar
    @Published var compactHeight: CGFloat = 0  // measured height of the minimised content
    @Published var permissionMode: PermissionMode {
        didSet {
            guard permissionMode != oldValue else { return }
            UserDefaults.standard.set(permissionMode.rawValue, forKey: "permissionMode")
            brain.send(["type": "mode", "mode": permissionMode.rawValue])
        }
    }

    let config: LaunchConfig
    let title: String
    private let brain: Brain
    private let voice: VoiceMode

    init(config: LaunchConfig) {
        self.config = config
        self.title = URL(fileURLWithPath: config.cwd).lastPathComponent
        let saved = UserDefaults.standard.string(forKey: "permissionMode").flatMap(PermissionMode.init) ?? .auto
        self.permissionMode = saved
        self.brain = Brain(config: config, mode: saved.rawValue)
        self.voice = VoiceMode(python: config.vmPython, session: config.session, path: config.path)

        brain.onEvent = { [weak self] e in self?.handle(e) }
        brain.onExit = { [weak self] code in
            self?.ready = false
            self?.add(.system, "Brain exited (\(code)). Close and reopen with /voice.")
        }
        voice.onPartial = { [weak self] text in
            guard let self else { return }
            self.heardSoFar = text.isEmpty ? "" : (self.heardSoFar.isEmpty ? text : self.heardSoFar + " " + text)
            self.hearing = !self.heardSoFar.isEmpty
        }
        voice.onTurn = { [weak self] text in
            self?.heardSoFar = ""
            self?.hearing = false
            self?.submit(text)
        }
        voice.onSpeakingChanged = { [weak self] on in self?.speaking = on }
        voice.onEarsStopped = { [weak self] why in
            self?.micOn = false
            self?.add(.system, "Mic stopped: \(why)")
        }
        voice.onLog = { [weak self] t in self?.add(.system, t) }
    }

    func start() {
        add(.system, "Forking session \(config.session.prefix(8))… VoiceMode voice: \(voice.voice)")
        do { try brain.start() } catch { add(.system, "Couldn't start brain: \(error.localizedDescription)") }
        setMic(true)
    }

    func shutdown() {
        voice.stopAll()
        brain.stop()
    }

    // MARK: - brain events

    private func handle(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "ready":
            ready = true
            add(.system, "Ready. Talk, or type below. (The fork is made on your first message.)")
        case "forked":
            add(.system, "Forked as session \((e["sessionId"] as? String ?? "").prefix(8)).")
        case "say":
            guard let text = e["text"] as? String else { return }
            add(.claude, text)
            speak(text)
        case "tool":
            add(.tool, "\(e["name"] as? String ?? "tool"): \(e["summary"] as? String ?? "")")
        case "permission_request":
            let ask = PermissionAsk(id: e["id"] as? String ?? "", tool: e["tool"] as? String ?? "tool",
                                    summary: e["summary"] as? String ?? "")
            pending = ask
            speak("Okay to run \(ask.tool.replacingOccurrences(of: "mcp__panel__", with: ""))? Say yes or no.")
        case "mode":
            add(.system, "Permissions: \(PermissionMode(rawValue: e["mode"] as? String ?? "")?.label ?? "?")")
        case "turn_end":
            thinking = false
        case "error":
            add(.system, "Error: \(e["message"] as? String ?? "?")")
            thinking = false
        case "log":
            PanelLog.write("[brain] \(e["text"] as? String ?? "")")
        default:
            PanelLog.write("[brain event] \(e)")
        }
    }

    // MARK: - user input

    func setMic(_ on: Bool) {
        if on {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    guard granted else {
                        self.add(.system, "Microphone access denied. Enable VoicePanel in System Settings › Privacy & Security › Microphone.")
                        self.micOn = false
                        return
                    }
                    do { try self.voice.startEars(); self.micOn = true } catch {
                        self.add(.system, "Mic error: \(error.localizedDescription)")
                        self.micOn = false
                    }
                }
            }
        } else {
            voice.stopEars()
            micOn = false
            hearing = false
            heardSoFar = ""
        }
    }

    func toggleMic() { setMic(!micOn) }

    func submitDraft() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        if !t.isEmpty { submit(t) }
    }

    func submit(_ text: String) {
        if let ask = pending {
            let t = text.lowercased()
            if t.range(of: #"\b(yes|yeah|yep|sure|ok|okay|go ahead|do it|allow|approve)\b"#, options: .regularExpression) != nil {
                answer(ask, allow: true); add(.you, text); return
            }
            if t.range(of: #"\b(no|nope|don'?t|deny|stop|cancel)\b"#, options: .regularExpression) != nil {
                answer(ask, allow: false); add(.you, text); return
            }
            // Anything else: decline the pending action and treat this as new direction.
            answer(ask, allow: false)
        }
        add(.you, text)
        stopReading()
        let wantsScreen = autoScreen || text.range(
            of: #"\b(screen|look at (this|that)|see (this|that)|what'?s this|on my display)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        thinking = true
        brain.send(["type": "user", "text": text, "screenshot": wantsScreen])
    }

    func answer(_ ask: PermissionAsk, allow: Bool) {
        brain.send(["type": "permission", "id": ask.id, "allow": allow])
        if pending?.id == ask.id { pending = nil }
        add(.permission, "\(allow ? "Allowed" : "Denied") \(ask.tool)")
    }

    /// Stop reading aloud (current sentence and anything queued) but let the work carry on.
    func stopReading() {
        voice.stopSpeaking()
    }

    func hush() {
        stopReading()
        if thinking { brain.send(["type": "interrupt"]) }
    }

    // MARK: - output

    private func speak(_ text: String) {
        let spoken = VoiceMode.speakable(text)
        if !spoken.isEmpty { voice.say(spoken) }
    }

    func add(_ role: Entry.Role, _ text: String) {
        PanelLog.write("[\(role)] \(text)")
        entries.append(Entry(role: role, text: text))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
    }
}
