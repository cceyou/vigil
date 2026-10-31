import Foundation

/// A background task as Claude Code reports it. Stop and SubagentStop carry `background_tasks`, the session's
/// running background shells and agents; a Bash call with `run_in_background` returns its `backgroundTaskId`.
/// Recorded payloads: Tests/VigilTests/Fixtures/hooks/background-shell-and-agent.json.
public struct ReportedTask: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case shell, subagent, other
    }

    public var id: String
    public var kind: Kind
    /// "running" while it runs; anything else means it is over.
    public var status: String
    /// Shells: the command line Claude ran.
    public var command: String?
    public var description: String?
    /// Subagents: the agent type ("general-purpose", ...).
    public var agentType: String?

    public init(id: String, kind: Kind, status: String = "running", command: String? = nil, description: String? = nil,
                agentType: String? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.command = command
        self.description = description
        self.agentType = agentType
    }

    public var isRunning: Bool { status == "running" }
}

/// What "Shelly na pozadí" does with a background shell Claude started.
public enum BackgroundShellPolicy: String, Codable, CaseIterable, Sendable {
    /// Keeps the Mac awake while it runs; a server (dev server, `stripe listen`, `tail -f`) only while it uses CPU.
    case exceptServers
    /// Keeps the Mac awake while it runs, servers included.
    case always
    /// Background shells never keep the Mac awake.
    case ignore
}

/// A background shell of a session, from the moment Claude starts it until it ends.
public struct BackgroundShell: Equatable, Identifiable, Sendable {
    public var id: String
    public var command: String
    public var startedAt: Date
    /// The process was found among the descendants of the session's Claude process.
    public var processFound = false
    /// The last process sample that still found its process alive. A shell seen alive recently is work in itself:
    /// the silence failsafe never cuts it, however quiet it is (`sleep 2400`, `gh run watch`).
    public var processSeenAt: Date?
    /// Average CPU of its process tree over the last `ShellActivity.window`; nil until there is that much history.
    public var cpuPercent: Double?
    /// "Ignorovat" in the popover or the card: it no longer keeps the Mac awake.
    public var ignored = false

    public init(id: String, command: String, startedAt: Date) {
        self.id = id
        self.command = command
        self.startedAt = startedAt
    }

    public var isServer: Bool { ServerCommands.isServer(command) }

    /// Its process was found alive within `within` seconds of `now`.
    public func processAlive(at now: Date, within: TimeInterval = 60) -> Bool {
        processSeenAt.map { now.timeIntervalSince($0) < within } ?? false
    }
}

/// Long-running servers: they run until stopped, so only CPU use says whether they are doing work.
public enum ServerCommands {
    /// Matched against the command, case-insensitively, as whole words.
    static let patterns: [String] = [
        #"\b(npm|pnpm|yarn|bun)\s+(run\s+)?(dev|start|serve|preview|watch)\b"#,
        #"\bnext\s+(dev|start)\b"#,
        #"\bvite\b"#,
        #"\bstripe\s+listen\b"#,
        #"(^|[\s;&|/])serve(\s|$)"#,
        #"\bhttp\.server\b"#,
        #"\bdocker[\s-]compose\s+up\b"#,
        #"\btail\s+(-[a-zA-Z]*f|--follow)"#,
        #"\bwebpack\s+serve\b"#,
        #"\b(nodemon|rails\s+s(erver)?|flask\s+run|uvicorn|php\s+-S)\b"#,
    ]
    static let regexes: [NSRegularExpression] = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    public static func isServer(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return regexes.contains { $0.firstMatch(in: command, range: range) != nil }
    }
}

/// Parsing of the background-task fields in hook payloads.
enum BackgroundTaskParser {
    /// `background_tasks` of a Stop or SubagentStop. nil when the field is absent (older Claude Code).
    static func reported(_ payload: [String: Any]) -> [ReportedTask]? {
        guard let list = payload["background_tasks"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let kind = ReportedTask.Kind(rawValue: item["type"] as? String ?? "") ?? .other
            return ReportedTask(id: id, kind: kind, status: item["status"] as? String ?? "running",
                                command: item["command"] as? String, description: item["description"] as? String,
                                agentType: item["agent_type"] as? String)
        }
    }

    /// A Bash call with `run_in_background` that started a shell (PostToolUse).
    static func startedShell(_ payload: [String: Any]) -> ReportedTask? {
        guard payload["tool_name"] as? String == "Bash",
              let response = payload["tool_response"] as? [String: Any],
              let id = response["backgroundTaskId"] as? String, !id.isEmpty else { return nil }
        let input = payload["tool_input"] as? [String: Any]
        return ReportedTask(id: id, kind: .shell, command: input?["command"] as? String,
                            description: input?["description"] as? String)
    }

    /// Tasks that are over: the `<task-notification>` Claude Code feeds back as a prompt when a background task ends,
    /// and TaskStop / KillShell calls.
    static func ended(_ payload: [String: Any]) -> [String] {
        if let prompt = payload["prompt"] as? String, prompt.contains("<task-notification>") {
            return taskIDs(in: prompt)
        }
        if let tool = payload["tool_name"] as? String, tool == "TaskStop" || tool == "KillShell",
           let input = payload["tool_input"] as? [String: Any] {
            return [input["task_id"], input["shell_id"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
        }
        return []
    }

    private static let taskIDPattern = try! NSRegularExpression(pattern: "<task-id>([^<]+)</task-id>")

    static func taskIDs(in text: String) -> [String] {
        taskIDPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }
}
