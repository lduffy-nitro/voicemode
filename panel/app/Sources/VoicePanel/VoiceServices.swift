import Foundation

/// The panel's ears and mouth, both provided by VoiceMode itself:
///
/// - ears:  `python -m voice_mode.listen capture --source mic` (long-lived; writes
///          partial / turn lines to the heard log)
/// - mouth: `python -m voice_mode.mouth say|retract` (VoiceMode's shared speech queue;
///          writes saying / said lines to the heard log)
/// - heard: `~/.voicemode/logs/conversations/heard_YYYY-MM-DD.jsonl`, followed here.
///
/// Our own speech is heard back by an open mic, so anything heard while VoiceMode is
/// speaking (or just after) is dropped.
final class VoiceMode {
    var onPartial: ((String) -> Void)?
    var onTurn: ((String) -> Void)?
    var onSpeakingChanged: ((Bool) -> Void)?
    var onEarsStopped: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    let python: String
    let session: String
    let voice: String
    private let env: [String: String]

    private var ears: Process?
    private var earsErr = Pipe()
    private let mouthQueue = DispatchQueue(label: "voicepanel.mouth")
    private var ourUtts = Set<String>()        // queued by us and not yet said
    private var speakingUtts = Set<String>()   // anyone's, between saying and said
    private var quietUntil = Date.distantPast
    private var turnContaminated = false

    private var followTimer: Timer?
    private var logPath = ""
    private var logOffset: UInt64 = 0
    private var partialBuffer = Data()

    init(python: String, session: String, path: String?) {
        self.python = python
        self.session = session
        let file = VoiceMode.readEnvFile()
        self.voice = file["VOICEMODE_VOICES"]?.split(separator: ",").first.map(String.init) ?? "af_sky"

        var e = ProcessInfo.processInfo.environment
        if let path { e["PATH"] = path }
        // Tag heard lines with the session the panel belongs to.
        e["CLAUDE_SESSION_ID"] = session
        e.removeValue(forKey: "CLAUDE_CODE_SESSION_ID")
        // mouth defaults to an mlx-audio Kokoro on :8890; VoiceMode's own Kokoro service is :8880.
        // voicemode.env wins if it sets these.
        e["VOICEMODE_MOUTH_KOKORO_URL"] = file["VOICEMODE_MOUTH_KOKORO_URL"] ?? e["VOICEMODE_MOUTH_KOKORO_URL"] ?? "http://127.0.0.1:8880/v1"
        e["VOICEMODE_MOUTH_KOKORO_MODEL"] = file["VOICEMODE_MOUTH_KOKORO_MODEL"] ?? e["VOICEMODE_MOUTH_KOKORO_MODEL"] ?? "kokoro"
        // mouth refuses to play without a device; follow the system output (AirPods, speakers…).
        e["VOICEMODE_MOUTH_DEVICE"] = file["VOICEMODE_MOUTH_DEVICE"] ?? e["VOICEMODE_MOUTH_DEVICE"] ?? "default"
        for (k, v) in file where k.hasPrefix("VOICEMODE_") && e[k] == nil { e[k] = v }
        self.env = e
    }

    var speaking: Bool { !speakingUtts.isEmpty }

    // MARK: ears

    var earsOn: Bool { ears?.isRunning == true }

    func startEars() throws {
        guard !earsOn else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-m", "voice_mode.listen", "capture", "--source", "mic",
                       "--heartbeat", "0", "--turn-text", "redecode"]
        p.environment = env
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        earsErr = Pipe()
        p.standardError = earsErr
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let err = String(data: self.earsErr.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            let tail = err.split(separator: "\n").suffix(2).joined(separator: " ")
            DispatchQueue.main.async {
                if proc.terminationReason == .uncaughtSignal || proc.terminationStatus == 0 { return }
                self.onEarsStopped?("listen exited (\(proc.terminationStatus)) \(tail)")
            }
        }
        try p.run()
        ears = p
        startFollowing()
    }

    func stopEars() {
        if let p = ears, p.isRunning { p.terminate() }
        ears = nil
    }

    // MARK: mouth

    func say(_ text: String) {
        let env = self.env, python = self.python, voice = self.voice
        mouthQueue.async { [weak self] in
            let (ok, out, err) = VoiceMode.exec(python, ["-m", "voice_mode.mouth", "say", "--voice", voice, text], env: env)
            guard ok else {
                let why = err.split(separator: "\n").last.map(String.init) ?? "unknown error"
                DispatchQueue.main.async { self?.onLog?("mouth say failed: \(why)") }
                return
            }
            let utt = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
            DispatchQueue.main.async { if !utt.isEmpty { self?.ourUtts.insert(utt) } }
        }
    }

    /// Cut our speech (playing and queued) without touching other agents' lines.
    func stopSpeaking() {
        let utts = ourUtts
        ourUtts.removeAll()
        let env = self.env, python = self.python
        mouthQueue.async {
            for u in utts { _ = VoiceMode.run(python, ["-m", "voice_mode.mouth", "retract", u], env: env) }
        }
    }

    // MARK: heard log

    private func currentLogPath() -> String {
        let base = env["VOICEMODE_BASE_DIR"] ?? (NSHomeDirectory() + "/.voicemode")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "\(base)/logs/conversations/heard_\(f.string(from: Date())).jsonl"
    }

    func startFollowing() {
        guard followTimer == nil else { return }
        logPath = currentLogPath()
        logOffset = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? UInt64) ?? 0
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stopAll() {
        stopEars()
        stopSpeaking()
        followTimer?.invalidate()
        followTimer = nil
    }

    private func poll() {
        let path = currentLogPath()
        if path != logPath { logPath = path; logOffset = 0; partialBuffer.removeAll() }   // new day
        guard let h = FileHandle(forReadingAtPath: logPath) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < logOffset { logOffset = 0 }
        guard size > logOffset else { return }
        try? h.seek(toOffset: logOffset)
        let data = h.readData(ofLength: Int(size - logOffset))
        logOffset = size
        partialBuffer.append(data)
        while let nl = partialBuffer.firstIndex(of: 0x0A) {
            let line = partialBuffer.subdata(in: partialBuffer.startIndex..<nl)
            partialBuffer.removeSubrange(partialBuffer.startIndex...nl)
            if let rec = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(rec) }
        }
    }

    private func handle(_ rec: [String: Any]) {
        let kind = rec["kind"] as? String ?? ""
        switch kind {
        case "saying":
            if let u = rec["utt"] as? String { speakingUtts.insert(u) }
            if speakingUtts.count == 1 { onSpeakingChanged?(true) }
        case "said":
            if let u = rec["utt"] as? String { speakingUtts.remove(u); ourUtts.remove(u) }
            quietUntil = Date().addingTimeInterval(0.8)
            if speakingUtts.isEmpty { onSpeakingChanged?(false) }
        case "partial", "turn":
            // Only what our own ears heard (mic, this session).
            guard rec["source"] as? String == "mic", rec["session"] as? String == session else { return }
            if speaking || Date() < quietUntil { turnContaminated = true }
            let text = (rec["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == "partial" {
                if !turnContaminated, !text.isEmpty { onPartial?(text) }
            } else {
                let drop = turnContaminated
                turnContaminated = false
                if drop { onLog?("(ignored speech heard while talking)"); onPartial?(""); return }
                if !VoiceMode.isNoise(text) { onTurn?(text) } else { onPartial?("") }
            }
        default:
            break
        }
    }

    // MARK: helpers

    @discardableResult
    static func run(_ exe: String, _ args: [String], env: [String: String]) -> String? {
        let (ok, out, _) = exec(exe, args, env: env)
        return ok ? out : nil
    }

    static func exec(_ exe: String, _ args: [String], env: [String: String]) -> (Bool, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, "", error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: o, encoding: .utf8) ?? "", String(data: e, encoding: .utf8) ?? "")
    }

    static func readEnvFile() -> [String: String] {
        let path = NSHomeDirectory() + "/.voicemode/voicemode.env"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).replacingOccurrences(of: "export ", with: "")
            let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard k.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil, !v.isEmpty else { continue }
            out[k] = v
        }
        return out
    }

    /// Make assistant text pleasant to hear: drop code, markdown and long paths.
    static func speakable(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (code shown in the panel) ", options: .regularExpression)
        t = t.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_#>|]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(/[\\w.\\-]+){3,}", with: " that file ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper emits these for silence / noise.
    static func isNoise(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if t.isEmpty { return true }
        if t.hasPrefix("[") || t.hasPrefix("(") { return true }
        return ["you", "thank you", "thanks for watching", "bye"].contains(t)
    }
}
