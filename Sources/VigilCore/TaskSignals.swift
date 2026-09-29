import Foundation

public enum TaskStatus: String, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case deleted
}

/// One entry of a TodoWrite list (older Claude Code versions send the whole list every time).
public struct TodoItem: Equatable, Sendable {
    public var subject: String
    public var status: TaskStatus
    /// "Writing x.txt": the present-tense label Claude shows while the item runs.
    public var activeForm: String?

    public init(subject: String, status: TaskStatus, activeForm: String? = nil) {
        self.subject = subject
        self.status = status
        self.activeForm = activeForm
    }
}

/// What a hook tells us about Claude's task list. Information only: never used for sleep decisions.
public enum TaskSignal: Equatable, Sendable {
    case created(id: String?, subject: String)
    case started(id: String)
    case completed(id: String?, subject: String?)
    case deleted(id: String)
    /// A full TodoWrite list.
    case snapshot([TodoItem])
}

/// Field names come from payloads recorded on a real machine (Claude Code 2.1.284), kept as test fixtures in
/// `Tests/VigilTests/Fixtures`:
/// - `TaskCreated` / `TaskCompleted`: `task_id`, `task_subject`, `task_description`.
/// - `PostToolUse` `TaskCreate`: `tool_input.subject`, `tool_response.task.id`.
/// - `PostToolUse` `TaskUpdate`: `tool_input.taskId`, `tool_input.status`.
/// - `PostToolUse` `TodoWrite`: `tool_input.todos[]` with `content`, `status`, `activeForm`.
/// Anything else (or anything malformed) yields no signals.
public enum TaskSignalParser {
    public static func parse(kind: HookKind, payload: [String: Any]) -> [TaskSignal] {
        switch kind {
        case .taskCreated:
            guard let subject = string(payload["task_subject"]) else { return [] }
            return [.created(id: string(payload["task_id"]), subject: subject)]
        case .taskCompleted:
            let id = string(payload["task_id"])
            let subject = string(payload["task_subject"])
            guard id != nil || subject != nil else { return [] }
            return [.completed(id: id, subject: subject)]
        case .postToolUse:
            return parseTool(name: payload["tool_name"] as? String, input: payload["tool_input"] as? [String: Any],
                             response: payload["tool_response"] as? [String: Any])
        default:
            return []
        }
    }

    private static func parseTool(name: String?, input: [String: Any]?, response: [String: Any]?) -> [TaskSignal] {
        guard let name, let input else { return [] }
        switch name {
        case "TaskCreate":
            guard let subject = string(input["subject"]) else { return [] }
            let id = string((response?["task"] as? [String: Any])?["id"])
            return [.created(id: id, subject: subject)]
        case "TaskUpdate":
            guard let id = string(input["taskId"]), let raw = input["status"] as? String,
                  let status = TaskStatus(rawValue: raw) else { return [] }
            switch status {
            case .inProgress: return [.started(id: id)]
            case .completed: return [.completed(id: id, subject: nil)]
            case .deleted: return [.deleted(id: id)]
            case .pending: return []
            }
        case "TodoWrite":
            guard let todos = input["todos"] as? [Any] else { return [] }
            let items = todos.compactMap { any -> TodoItem? in
                guard let t = any as? [String: Any], let subject = string(t["content"]),
                      let status = (t["status"] as? String).flatMap(TaskStatus.init(rawValue:)) else { return nil }
                return TodoItem(subject: subject, status: status, activeForm: string(t["activeForm"]))
            }
            return [.snapshot(items)]
        default:
            return []
        }
    }

    /// Non-empty string; numbers are accepted as ids too.
    private static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s.isEmpty ? nil : s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
}
