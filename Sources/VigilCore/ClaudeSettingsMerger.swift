import Foundation

/// Pure JSON transformation of ~/.claude/settings.json. Never touches the disk.
public enum ClaudeSettingsMerger {
    /// Every hook command we install contains this; it is how we recognise (and remove) our own entries.
    public static let marker = "Vigil/hook.sh"

    /// Events we register. PostToolUse is a heartbeat that lets a session resume "working" after a
    /// permission prompt was approved (Claude Code fires no UserPromptSubmit in that case).
    public static let events: [HookKind] = [.sessionStart, .userPromptSubmit, .stop, .notification, .sessionEnd, .postToolUse]

    public enum MergeError: Error, Equatable, CustomStringConvertible {
        case invalidJSON(String)
        case notAnObject
        case unexpectedStructure(String)

        public var description: String {
            switch self {
            case .invalidJSON(let d): return "settings.json is not valid JSON (\(d))"
            case .notAnObject: return "settings.json is not a JSON object"
            case .unexpectedStructure(let d): return "unexpected structure in settings.json: \(d)"
            }
        }
    }

    public static func command(for kind: HookKind) -> String {
        "\"$HOME/Library/Application Support/Vigil/hook.sh\" \(kind.rawValue)"
    }

    // MARK: parse / serialize

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        do { try StrictJSON.validate(data) } catch {
            throw MergeError.invalidJSON("\(error)")
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch {
            throw MergeError.invalidJSON(error.localizedDescription)
        }
        guard let dict = object as? [String: Any] else { throw MergeError.notAnObject }
        return dict
    }

    private static func serialize(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func isOurs(_ hook: Any) -> Bool {
        guard let h = hook as? [String: Any], let cmd = h["command"] as? String else { return false }
        return cmd.contains(marker)
    }

    /// Returns the groups of an event with our entries stripped, plus how many entries were removed.
    private static func stripOurs(from groups: [Any]) -> (groups: [Any], removed: Int) {
        var removed = 0
        var result: [Any] = []
        for group in groups {
            guard var g = group as? [String: Any], let hooks = g["hooks"] as? [Any] else { result.append(group); continue }
            let kept = hooks.filter { !isOurs($0) }
            if kept.count == hooks.count { result.append(group); continue }
            removed += hooks.count - kept.count
            if kept.isEmpty { continue } // the group only contained our entry
            g["hooks"] = kept
            result.append(g)
        }
        return (result, removed)
    }

    // MARK: install

    /// Adds our hook entries, keeping everything else. Idempotent.
    public static func install(into data: Data?) throws -> Data {
        var root = try parse(data)
        var hooks: [String: Any]
        if let existing = root["hooks"] {
            guard let dict = existing as? [String: Any] else { throw MergeError.unexpectedStructure("\"hooks\" is not an object") }
            hooks = dict
        } else {
            hooks = [:]
        }
        for kind in events {
            var groups: [Any]
            if let existing = hooks[kind.rawValue] {
                guard let arr = existing as? [Any] else {
                    throw MergeError.unexpectedStructure("\"hooks.\(kind.rawValue)\" is not an array")
                }
                groups = stripOurs(from: arr).groups
            } else {
                groups = []
            }
            groups.append(["hooks": [["type": "command", "command": command(for: kind), "timeout": 5] as [String: Any]]])
            hooks[kind.rawValue] = groups
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    // MARK: remove

    /// Removes only our entries. Returns nil if nothing of ours was present (file must not be rewritten).
    public static func remove(from data: Data?) throws -> Data? {
        var root = try parse(data)
        guard var hooks = root["hooks"] as? [String: Any] else { return nil }
        var totalRemoved = 0
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let (kept, removed) = stripOurs(from: groups)
            totalRemoved += removed
            if removed > 0 {
                if kept.isEmpty { hooks[event] = nil } else { hooks[event] = kept }
            }
        }
        guard totalRemoved > 0 else { return nil }
        if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        return try serialize(root)
    }

    // MARK: status

    /// Events (of the ones we need) that are registered with our command.
    public static func installedEvents(in data: Data?) -> Set<HookKind> {
        guard let root = try? parse(data), let hooks = root["hooks"] as? [String: Any] else { return [] }
        var found = Set<HookKind>()
        for kind in events {
            guard let groups = hooks[kind.rawValue] as? [Any] else { continue }
            let has = groups.contains { g in
                guard let hs = (g as? [String: Any])?["hooks"] as? [Any] else { return false }
                return hs.contains(where: isOurs)
            }
            if has { found.insert(kind) }
        }
        return found
    }
}
