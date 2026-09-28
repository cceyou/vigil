import Foundation
import os

/// os.Logger + a size-rotating plain-text log file (1 MB x 3) under Application Support.
public final class Log: @unchecked Sendable {
    /// Under the test runner the shared log goes to a temp folder so tests never pollute the real log.
    public static let shared: Log = {
        let exe = CommandLine.arguments.first ?? ""
        let underTest = exe.contains("xctest") || exe.contains("testing-helper") || exe.contains("PackageTests")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vigil-test-home", isDirectory: true)
        return Log(paths: underTest ? VigilPaths(home: home) : .standard)
    }()

    private let logger = Logger(subsystem: "cz.krystof.vigil", category: "app")
    private let paths: VigilPaths
    private let queue = DispatchQueue(label: "cz.krystof.vigil.log")
    private let maxBytes = 1_000_000
    private let keep = 3
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(paths: VigilPaths) { self.paths = paths }

    public func info(_ message: String) { write("INFO", message); logger.info("\(message, privacy: .public)") }
    public func warning(_ message: String) { write("WARN", message); logger.warning("\(message, privacy: .public)") }
    public func error(_ message: String) { write("ERROR", message); logger.error("\(message, privacy: .public)") }

    private func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async { [self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: paths.logDir, withIntermediateDirectories: true)
            rotateIfNeeded()
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: paths.logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: paths.logFile)
                }
            }
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: paths.logFile.path)[.size] as? Int) ?? 0
        guard size >= maxBytes else { return }
        func numbered(_ n: Int) -> URL { paths.logDir.appendingPathComponent("vigil.\(n).log") }
        try? fm.removeItem(at: numbered(keep - 1))
        for n in stride(from: keep - 2, through: 1, by: -1) {
            try? fm.moveItem(at: numbered(n), to: numbered(n + 1))
        }
        try? fm.moveItem(at: paths.logFile, to: numbered(1))
    }

    /// Blocks until queued writes hit disk (used before exit and in tests).
    public func flush() { queue.sync {} }
}
