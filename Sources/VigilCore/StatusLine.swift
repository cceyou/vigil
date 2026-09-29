import Foundation

/// One rate-limit window from Claude Code's status line JSON (`rate_limits.five_hour` / `.seven_day`).
public struct UsageWindow: Codable, Equatable, Sendable {
    /// 0...100.
    public var usedPercentage: Double
    public var resetsAt: Date

    public init(usedPercentage: Double, resetsAt: Date) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}

/// What Vigil keeps from one status line update.
public struct StatusLineSnapshot: Equatable, Sendable {
    public var sessionID: String
    public var cwd: String?
    public var model: String?
    /// `context_window.used_percentage`, 0...100.
    public var contextPercent: Double?
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?

    public init(sessionID: String, cwd: String? = nil, model: String? = nil, contextPercent: Double? = nil,
                fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.model = model
        self.contextPercent = contextPercent
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public var hasRateLimits: Bool { fiveHour != nil || sevenDay != nil }
}

/// Parses what statusline.sh sends over the socket: `{"vigil_event":"StatusLine","payload":{...Claude's JSON...}}`.
/// Also accepts Claude's bare status line JSON. `rate_limits` is optional: it is only sent to Claude.ai
/// subscribers (Pro/Max, Claude Code 2.1.80+) and only after the first API response of a session.
public enum StatusLineParser {
    public static let eventName = "StatusLine"

    /// True if the socket line is a status line message (not a hook event).
    public static func isStatusLine(_ object: [String: Any]) -> Bool {
        (object["vigil_event"] as? String) == eventName
    }

    public static func parse(_ data: Data) -> StatusLineSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object: object)
    }

    public static func parse(object: [String: Any]) -> StatusLineSnapshot? {
        let payload = (object["payload"] as? [String: Any]) ?? object
        guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else { return nil }
        let model = (payload["model"] as? [String: Any])?["display_name"] as? String
        let context = number((payload["context_window"] as? [String: Any])?["used_percentage"])
        let limits = payload["rate_limits"] as? [String: Any]
        return StatusLineSnapshot(sessionID: sessionID,
                                  cwd: (payload["cwd"] as? String) ?? ((payload["workspace"] as? [String: Any])?["current_dir"] as? String),
                                  model: model,
                                  contextPercent: context.map(clampPercent),
                                  fiveHour: window(limits?["five_hour"]),
                                  sevenDay: window(limits?["seven_day"]))
    }

    private static func window(_ raw: Any?) -> UsageWindow? {
        guard let dict = raw as? [String: Any], let used = number(dict["used_percentage"]),
              let resets = number(dict["resets_at"]), resets > 0 else { return nil }
        return UsageWindow(usedPercentage: clampPercent(used), resetsAt: Date(timeIntervalSince1970: resets))
    }

    private static func number(_ raw: Any?) -> Double? {
        // `is Bool` would also match the numbers 0 and 1, so JSON booleans are told apart by their CF type.
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private static func clampPercent(_ v: Double) -> Double { min(100, max(0, v)) }
}
