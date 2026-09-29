import Foundation

/// All file-system locations Vigil uses. Injectable so tests never touch the real home directory.
public struct VigilPaths: Sendable {
    public var home: URL
    public var supportDir: URL

    public init(home: URL) {
        self.home = home
        self.supportDir = home.appendingPathComponent("Library/Application Support/Vigil", isDirectory: true)
    }

    public static let standard = VigilPaths(home: FileManager.default.homeDirectoryForCurrentUser)

    public var socket: URL { supportDir.appendingPathComponent("vigil.sock") }
    public var hookScript: URL { supportDir.appendingPathComponent("hook.sh") }
    public var history: URL { supportDir.appendingPathComponent("history.json") }
    /// Status line wrapper (forwards Claude Code's status line JSON to the socket).
    public var statusLineScript: URL { supportDir.appendingPathComponent("statusline.sh") }
    /// The user's statusLine object from settings.json before Vigil replaced it (verbatim JSON, or `null`).
    public var statusLineOriginal: URL { supportDir.appendingPathComponent("statusline.original.json") }
    /// The original status line command, run by the wrapper with the same stdin (empty: none).
    public var statusLineChain: URL { supportDir.appendingPathComponent("statusline.chain") }
    /// Finished turns (UserPromptSubmit → Stop) the work-time estimate learns from.
    public var turns: URL { supportDir.appendingPathComponent("turns.json") }
    /// Last known Claude usage (rate limits, per-session model and context).
    public var usage: URL { supportDir.appendingPathComponent("usage.json") }
    public var logDir: URL { supportDir.appendingPathComponent("logs", isDirectory: true) }
    public var logFile: URL { logDir.appendingPathComponent("vigil.log") }
    /// Exists only while disablesleep=1 is in force; the watchdog restores when it sees it after the app died.
    public var watchdogArmFile: URL { supportDir.appendingPathComponent("watchdog.armed") }
    public var watchdogPidFile: URL { supportDir.appendingPathComponent("watchdog.pid") }
    public var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }

    public func ensureSupportDir() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
