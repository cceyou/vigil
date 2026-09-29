import Foundation

/// Pure JSON transformation of the `statusLine` key in ~/.claude/settings.json. Never touches the disk.
///
/// Vigil's entry points at statusline.sh. The user's previous `statusLine` object is handed back to the
/// caller to be stored (verbatim) next to the wrapper, so `remove` can restore it exactly.
public enum StatusLineMerger {
    public static let marker = "Vigil/statusline.sh"
    public static let command = "\"$HOME/Library/Application Support/Vigil/statusline.sh\""

    public enum Status: Equatable, Sendable { case missing, installed }

    public struct Installation {
        public var settings: Data
        /// The statusLine value that was there before (nil: none). Store it for `remove`.
        public var original: Any?
    }

    public static func isOurs(_ value: Any?) -> Bool {
        guard let dict = value as? [String: Any], let cmd = dict["command"] as? String else { return false }
        return cmd.contains(marker)
    }

    public static func status(in data: Data?) -> Status {
        guard let root = try? ClaudeSettingsMerger.parse(data) else { return .missing }
        return isOurs(root["statusLine"]) ? .installed : .missing
    }

    /// Points statusLine at the wrapper, keeping the original's other keys (e.g. `padding`).
    /// Returns nil when Vigil's entry is already there: nothing to write, and the stored original stays valid.
    public static func install(into data: Data?) throws -> Installation? {
        var root = try ClaudeSettingsMerger.parse(data)
        let original = root["statusLine"]
        if isOurs(original) { return nil }
        var entry = (original as? [String: Any]) ?? [:]
        entry["type"] = "command"
        entry["command"] = command
        root["statusLine"] = entry
        return Installation(settings: try ClaudeSettingsMerger.serialize(root), original: original)
    }

    /// Puts the original back (or removes the key if there was none). Returns nil when the current statusLine
    /// is not Vigil's (the user changed it since): then settings.json must not be rewritten.
    public static func remove(from data: Data?, original: Any?) throws -> Data? {
        var root = try ClaudeSettingsMerger.parse(data)
        guard isOurs(root["statusLine"]) else { return nil }
        if let original, !(original is NSNull) { root["statusLine"] = original } else { root["statusLine"] = nil }
        return try ClaudeSettingsMerger.serialize(root)
    }

    /// The command the wrapper should chain to (nil: no previous command status line).
    public static func chainCommand(of original: Any?) -> String? {
        guard let dict = original as? [String: Any], (dict["type"] as? String ?? "command") == "command",
              let cmd = dict["command"] as? String, !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cmd.contains(marker) else { return nil }
        return cmd
    }

    /// Sidecar encoding of the original value: its JSON, or `null`.
    public static func encodeOriginal(_ original: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: original ?? NSNull(),
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    public static func decodeOriginal(_ data: Data) throws -> Any? {
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return value is NSNull ? nil : value
    }
}

/// File-level installation of statusline.sh, its sidecars and the settings.json entry.
public struct StatusLineInstaller: Sendable {
    public var paths: VigilPaths
    public init(paths: VigilPaths = .standard) { self.paths = paths }

    private var hooks: HookInstaller { HookInstaller(paths: paths) }

    public func installScript() throws {
        do {
            try paths.ensureSupportDir()
            try StatusLineScript.contents().write(to: paths.statusLineScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.statusLineScript.path)
        } catch {
            throw InstallError.io("could not install statusline.sh: \(error.localizedDescription)")
        }
    }

    /// Installs the wrapper and points settings.json at it, remembering the previous status line first.
    /// Invalid JSON aborts before anything is written. Running it again changes nothing.
    public func install() throws {
        let existing = try hooks.readSettings()
        let result: StatusLineMerger.Installation?
        do { result = try StatusLineMerger.install(into: existing) } catch let e as ClaudeSettingsMerger.MergeError {
            throw InstallError.settings(e)
        }
        try installScript()
        guard let result else {
            // Already ours: the stored original stays as it is; only repair a chain file that drifted from it.
            if !chainMatchesOriginal() { try? writeChain(for: storedOriginal()) }
            return
        }
        do {
            try StatusLineMerger.encodeOriginal(result.original).write(to: paths.statusLineOriginal, options: .atomic)
            try writeChain(for: result.original)
        } catch {
            throw InstallError.io("could not save the previous status line: \(error.localizedDescription)")
        }
        try hooks.backupSettings()
        try hooks.writeSettings(result.settings)
        Log.shared.info("status line installed into \(paths.claudeSettings.path)")
    }

    private func writeChain(for original: Any?) throws {
        try (StatusLineMerger.chainCommand(of: original) ?? "").write(to: paths.statusLineChain, atomically: true, encoding: .utf8)
    }

    /// Restores the previous status line exactly (or removes the key) and deletes the wrapper and sidecars.
    public func remove() throws {
        let existing = try hooks.readSettings()
        let original = storedOriginal()
        let updated: Data?
        do { updated = try StatusLineMerger.remove(from: existing, original: original) } catch let e as ClaudeSettingsMerger.MergeError {
            throw InstallError.settings(e)
        }
        if let updated {
            try hooks.backupSettings()
            try hooks.writeSettings(updated)
            Log.shared.info("status line restored in \(paths.claudeSettings.path)")
        }
        for url in [paths.statusLineOriginal, paths.statusLineChain, paths.statusLineScript] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The previous statusLine value as stored at install time (nil: none, or not stored).
    public func storedOriginal() -> Any? {
        guard let data = try? Data(contentsOf: paths.statusLineOriginal) else { return nil }
        return try? StatusLineMerger.decodeOriginal(data)
    }

    public func status() -> StatusLineMerger.Status {
        StatusLineMerger.status(in: try? hooks.readSettings())
    }

    /// settings.json points at the wrapper and the wrapper exists.
    public var isInstalled: Bool {
        status() == .installed && FileManager.default.isExecutableFile(atPath: paths.statusLineScript.path)
    }

    /// The chain file runs exactly the stored original command (or nothing, if there was none).
    public func chainMatchesOriginal() -> Bool {
        let chain = (try? String(contentsOf: paths.statusLineChain, encoding: .utf8)) ?? ""
        return chain == (StatusLineMerger.chainCommand(of: storedOriginal()) ?? "")
    }
}
