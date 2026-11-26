import Foundation

/// Runs brain.mjs (the forked Claude Code session) and exchanges JSON lines with it.
final class Brain {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var buffer = Data()

    init(config: LaunchConfig, mode: String) {
        process.executableURL = URL(fileURLWithPath: config.node)
        var args = [config.brainScript,
                    "--session", config.session,
                    "--transcript", config.transcript,
                    "--cwd", config.cwd,
                    "--mode", mode]
        if let claude = config.claude { args += ["--claude", claude] }
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: config.cwd)
        var env = ProcessInfo.processInfo.environment
        if let path = config.path { env["PATH"] = path }
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self, !chunk.isEmpty else { return }
            DispatchQueue.main.async { self.consume(chunk) }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.onExit?(p.terminationStatus) }
        }
        try process.run()
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                onEvent?(obj)
            }
        }
    }

    func send(_ obj: [String: Any]) {
        guard process.isRunning,
              var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        stdinPipe.fileHandleForWriting.write(data)
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}
