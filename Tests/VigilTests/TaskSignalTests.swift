import Foundation
import Testing
@testable import VigilCore

/// Parsers against payloads recorded on a real machine (Claude Code 2.1.284, `claude -p` with capture hooks),
/// stored exactly as hook.sh puts them on the socket: `{"vigil_event":…,"pid":…,"payload":{…}}`.
@Suite struct TaskSignalTests {
    static func fixture(_ name: String) throws -> [Data] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
    }

    static func events(_ name: String) throws -> [HookEvent] {
        try fixture(name).map { try #require(HookEventParser.parse($0)) }
    }

    @Test func taskHooksFromTheRecordedRun() throws {
        let events = try Self.events("tasks-run")
        #expect(events.count == 17)
        #expect(events.first?.kind == .userPromptSubmit)
        #expect(events.last?.kind == .stop)

        let created = events.filter { $0.kind == .taskCreated }
        #expect(created.map(\.taskSignals) == [[.created(id: "1", subject: "Write a.txt")],
                                                [.created(id: "2", subject: "Write b.txt")],
                                                [.created(id: "3", subject: "Write c.txt")]])
        let completed = events.filter { $0.kind == .taskCompleted }
        #expect(completed.map(\.taskSignals) == [[.completed(id: "1", subject: "Write a.txt")],
                                                  [.completed(id: "2", subject: "Write b.txt")],
                                                  [.completed(id: "3", subject: "Write c.txt")]])
    }

    @Test func taskToolCallsFromTheRecordedRun() throws {
        let tools = try Self.events("tasks-run").filter { $0.kind == .postToolUse }
        #expect(tools.map(\.toolName) == ["TaskCreate", "TaskCreate", "TaskCreate", "TaskUpdate", "TaskUpdate", "TaskUpdate",
                                          "TaskUpdate", "TaskUpdate", "TaskUpdate"])
        #expect(tools[0].taskSignals == [.created(id: "1", subject: "Write a.txt")]) // id from tool_response.task.id
        #expect(tools[3].taskSignals == [.started(id: "1")])
        #expect(tools[4].taskSignals == [.completed(id: "1", subject: nil)])
    }

    @Test func todoWriteFromTheRecordedRun() throws {
        let tools = try Self.events("todowrite-run").filter { $0.toolName == "TodoWrite" }
        #expect(tools.count == 3)
        #expect(tools[0].taskSignals == [.snapshot([
            TodoItem(subject: "Write x.txt", status: .inProgress, activeForm: "Writing x.txt"),
            TodoItem(subject: "Write y.txt", status: .pending, activeForm: "Writing y.txt"),
        ])])
        #expect(tools[2].taskSignals == [.snapshot([
            TodoItem(subject: "Write x.txt", status: .completed, activeForm: "Writing x.txt"),
            TodoItem(subject: "Write y.txt", status: .completed, activeForm: "Writing y.txt"),
        ])])
    }

    /// The whole recorded run through the tracker: three tasks, each started and completed once, no duplicates
    /// although TaskCreated and the TaskCreate tool call report the same task.
    @Test(arguments: ["tasks-run", "todowrite-run"])
    func recordedRunsReplayThroughTheTracker(_ name: String) throws {
        var tracker = TurnTracker()
        var record: TurnRecord?
        for (i, event) in try Self.events(name).enumerated() {
            if let r = tracker.handle(event, at: at(Double(i) * 10)) { record = r }
            tracker.tick(at: at(Double(i) * 10), history: [])
        }
        let r = try #require(record)
        #expect(r.project == "demo")
        #expect(r.taskCount == (name == "tasks-run" ? 3 : 2))
        #expect(r.taskDurations.count == r.taskCount)
        #expect(r.taskDurations.allSatisfy { $0 > 0 })
        #expect(tracker.turns.isEmpty)
    }

    @Test func malformedPayloadsGiveNoSignals() {
        let cases: [(HookKind, [String: Any])] = [
            (.taskCreated, [:]),
            (.taskCreated, ["task_subject": ""]),
            (.taskCompleted, ["task_description": "x"]),
            (.postToolUse, ["tool_name": "TaskUpdate", "tool_input": ["taskId": "1", "status": "bogus"]]),
            (.postToolUse, ["tool_name": "TaskUpdate", "tool_input": ["status": "completed"]]),
            (.postToolUse, ["tool_name": "TaskCreate", "tool_input": "not an object"]),
            (.postToolUse, ["tool_name": "Bash", "tool_input": ["command": "ls"]]),
            (.stop, ["task_id": "1", "task_subject": "x"]),
        ]
        for (kind, payload) in cases {
            #expect(TaskSignalParser.parse(kind: kind, payload: payload).isEmpty, "\(kind) \(payload)")
        }
        // A TodoWrite with broken items keeps the valid ones.
        let mixed = TaskSignalParser.parse(kind: .postToolUse, payload: ["tool_name": "TodoWrite", "tool_input": ["todos": [
            ["content": "ok", "status": "pending"], ["content": "no status"], "garbage",
        ]]])
        #expect(mixed == [.snapshot([TodoItem(subject: "ok", status: .pending)])])
    }

    @Test func numericTaskIDsAreAccepted() {
        #expect(TaskSignalParser.parse(kind: .taskCreated, payload: ["task_id": 7, "task_subject": "x"]) == [.created(id: "7", subject: "x")])
    }
}
