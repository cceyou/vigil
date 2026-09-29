import Foundation

/// Parses the line hook.sh sends over the socket:
/// `{"vigil_event":"Stop","pid":123,"payload":{...Claude's hook JSON...}}`
/// Also tolerates a bare Claude payload (uses `hook_event_name`).
public enum HookEventParser {
    public static func parse(_ data: Data) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (object["payload"] as? [String: Any]) ?? object
        let rawName = (object["vigil_event"] as? String) ?? (payload["hook_event_name"] as? String)
        guard let rawName, let kind = HookKind(rawValue: rawName) else { return nil }
        guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else { return nil }
        let cwd = payload["cwd"] as? String
        var pid: Int32?
        if let n = object["pid"] as? Int, n > 1 { pid = Int32(truncatingIfNeeded: n) }
        else if let s = object["pid"] as? String, let n = Int32(s), n > 1 { pid = n }
        let agentID = (payload["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let agentType = payload["agent_type"] as? String
        let notificationType = (payload["notification_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return HookEvent(kind: kind, sessionID: sessionID, cwd: cwd, pid: pid, agentID: agentID, agentType: agentType,
                         notificationType: notificationType)
    }
}
