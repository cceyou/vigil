import Foundation

public enum InstallError: Error, CustomStringConvertible {
    case settings(ClaudeSettingsMerger.MergeError)
    case io(String)
    case userCancelled
    case sudoersInvalid(String)
    case privileged(String)

    public var description: String {
        switch self {
        case .settings(let e): return e.description
        case .io(let m): return m
        case .userCancelled: return L("Cancelled")
        case .sudoersInvalid(let m): return "sudoers validation failed: \(m)"
        case .privileged(let m): return m
        }
    }
}

/// File-level installation of hook.sh and the settings.json hook entries.
public struct HookInstaller: Sendable {
    public var paths: VigilPaths
    public init(paths: VigilPaths = .standard) { self.paths = paths }

    // MARK: hook.sh

    public func installScript() throws {
        do {
            try paths.ensureSupportDir()
            try HookScript.contents.write(to: paths.hookScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.hookScript.path)
        } catch {
            throw InstallError.io("could not install hook.sh: \(error.localizedDescription)")
        }
    }

    // MARK: settings.json

    private func readSettings() throws -> Data? {
        guard FileManager.default.fileExists(atPath: paths.claudeSettings.path) else { return nil }
        do { return try Data(contentsOf: paths.claudeSettings) } catch {
            throw InstallError.io("could not read settings.json: \(error.localizedDescription)")
        }
    }

    /// Timestamped copy next to the original. Returns the backup URL (nil if there was no file).
    @discardableResult
    public func backupSettings() throws -> URL? {
        guard FileManager.default.fileExists(atPath: paths.claudeSettings.path) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var url = paths.claudeSettings.deletingLastPathComponent()
            .appendingPathComponent("settings.json.vigil-backup-\(f.string(from: Date()))")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = url.deletingLastPathComponent().appendingPathComponent("settings.json.vigil-backup-\(f.string(from: Date()))-\(n)")
            n += 1
        }
        do { try FileManager.default.copyItem(at: paths.claudeSettings, to: url) } catch {
            throw InstallError.io("could not back up settings.json: \(error.localizedDescription)")
        }
        return url
    }

    private func writeSettings(_ data: Data) throws {
        do {
            try FileManager.default.createDirectory(at: paths.claudeSettings.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: paths.claudeSettings, options: .atomic)
        } catch {
            throw InstallError.io("could not write settings.json: \(error.localizedDescription)")
        }
    }

    /// Installs hook.sh, backs up settings.json, merges our hooks in. Invalid JSON aborts before any write.
    public func installHooks() throws {
        let existing = try readSettings()
        let merged: Data
        do { merged = try ClaudeSettingsMerger.install(into: existing) } catch let e as ClaudeSettingsMerger.MergeError {
            throw InstallError.settings(e)
        }
        try installScript()
        try backupSettings()
        try writeSettings(merged)
        Log.shared.info("hooks installed into \(paths.claudeSettings.path)")
    }

    /// Removes only our entries. No-op (and no rewrite) if none are present.
    public func removeHooks() throws {
        guard let existing = try readSettings() else { return }
        let updated: Data?
        do { updated = try ClaudeSettingsMerger.remove(from: existing) } catch let e as ClaudeSettingsMerger.MergeError {
            throw InstallError.settings(e)
        }
        guard let updated else { return }
        try backupSettings()
        try writeSettings(updated)
        Log.shared.info("hooks removed from \(paths.claudeSettings.path)")
    }

    public func installedEvents() -> Set<HookKind> {
        ClaudeSettingsMerger.installedEvents(in: try? readSettings())
    }

    public var hooksInstalled: Bool { installedEvents() == Set(ClaudeSettingsMerger.events) }
}
