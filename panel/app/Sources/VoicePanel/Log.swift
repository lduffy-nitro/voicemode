import Foundation

/// Plain-text log of everything a panel shows plus what it doesn't (brain stderr, lifecycle),
/// so a panel that dies or misbehaves leaves evidence: ~/.voice-panel/logs/<session>.log
enum PanelLog {
    static let dir = NSHomeDirectory() + "/.voice-panel/logs"
    private static var path: String?
    private static let queue = DispatchQueue(label: "panel.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func open(session: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/\(session).log"
        if !FileManager.default.fileExists(atPath: path!) {
            FileManager.default.createFile(atPath: path!, contents: nil)
        }
    }

    /// A handle that appends to the log, for a child process's stderr.
    static func appendHandle() -> FileHandle? {
        guard let path, let h = FileHandle(forWritingAtPath: path) else { return nil }
        h.seekToEndOfFile()
        return h
    }

    static func write(_ line: String) {
        guard let path else { return }
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            guard let h = FileHandle(forWritingAtPath: path) else { return }
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        }
    }

    /// Synchronous variant for the last words before the process exits.
    static func writeNow(_ line: String) {
        queue.sync {}
        guard let path, let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile()
        h.write(Data("\(stamp.string(from: Date())) \(line)\n".utf8))
        try? h.close()
    }
}
