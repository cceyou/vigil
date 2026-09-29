import Foundation

// MARK: - Records

public struct SubagentRun: Codable, Equatable, Sendable {
    public var type: String
    public var duration: TimeInterval
    public init(type: String, duration: TimeInterval) {
        self.type = type
        self.duration = duration
    }
}

/// The estimate shown at 25, 50 or 75 % of a finished turn, as a predicted *total* active duration
/// (elapsed at that moment + remaining), so it compares directly with how long the turn took.
public struct EtaCheckpoint: Codable, Equatable, Sendable {
    public var fraction: Double
    public var low: TimeInterval
    public var likely: TimeInterval
    public var high: TimeInterval
    public var confidence: EtaConfidence
    /// Task list size when it was shown; nil = the estimate came from history.
    public var tasksTotal: Int?

    public init(fraction: Double, low: TimeInterval, likely: TimeInterval, high: TimeInterval,
                confidence: EtaConfidence, tasksTotal: Int?) {
        self.fraction = fraction
        self.low = low
        self.likely = likely
        self.high = high
        self.confidence = confidence
        self.tasksTotal = tasksTotal
    }
}

/// One finished turn (UserPromptSubmit → Stop): what the estimate learns from and is scored against.
public struct TurnRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var project: String
    public var startedAt: Date
    /// Wall-clock duration.
    public var duration: TimeInterval
    /// Without the time spent waiting for the user.
    public var activeDuration: TimeInterval
    public var taskCount: Int
    /// Active durations of the tasks completed in the turn.
    public var taskDurations: [TimeInterval]
    public var subagents: [SubagentRun]
    public var toolCount: Int
    /// Up to three: 25, 50, 75 % (only the fractions at which an estimate was shown).
    public var checkpoints: [EtaCheckpoint]

    public var subagentCount: Int { subagents.count }
    public var agentTypes: [String] { Array(Set(subagents.map(\.type))).sorted() }

    public init(id: String, project: String, startedAt: Date, duration: TimeInterval, activeDuration: TimeInterval,
                taskCount: Int = 0, taskDurations: [TimeInterval] = [], subagents: [SubagentRun] = [], toolCount: Int = 0,
                checkpoints: [EtaCheckpoint] = []) {
        self.id = id
        self.project = project
        self.startedAt = startedAt
        self.duration = duration
        self.activeDuration = activeDuration
        self.taskCount = taskCount
        self.taskDurations = taskDurations
        self.subagents = subagents
        self.toolCount = toolCount
        self.checkpoints = checkpoints
    }

    // Tolerant decoding: records written by an older build must still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        project = try c.decode(String.self, forKey: .project)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        activeDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .activeDuration) ?? duration
        taskCount = try c.decodeIfPresent(Int.self, forKey: .taskCount) ?? 0
        taskDurations = try c.decodeIfPresent([TimeInterval].self, forKey: .taskDurations) ?? []
        subagents = try c.decodeIfPresent([SubagentRun].self, forKey: .subagents) ?? []
        toolCount = try c.decodeIfPresent(Int.self, forKey: .toolCount) ?? 0
        checkpoints = try c.decodeIfPresent([EtaCheckpoint].self, forKey: .checkpoints) ?? []
    }
}

/// Last 500 finished turns, newest first, as JSON in Application Support.
public final class TurnStore: @unchecked Sendable {
    public static let limit = 500
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    public func load() -> [TurnRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url), let list = try? Self.decoder.decode([TurnRecord].self, from: data) else { return [] }
        return list
    }

    @discardableResult
    public func append(_ record: TurnRecord) -> [TurnRecord] {
        var list = load()
        list.insert(record, at: 0)
        if list.count > Self.limit { list = Array(list.prefix(Self.limit)) }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(list) { try? data.write(to: url, options: .atomic) }
        return list
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Live turn

public struct TrackedTask: Equatable, Sendable {
    public var id: String
    public var subject: String
    /// Active-time coordinates within the turn (seconds of active time since the turn started).
    public var startedActive: TimeInterval?
    public var completedActive: TimeInterval?
    public var duration: TimeInterval?

    public var isDone: Bool { completedActive != nil }
}

public struct RunningAgent: Equatable, Sendable {
    public var id: String
    public var type: String
    public var startedAt: Date
}

/// A sample of what the UI showed, for the 25/50/75 % checkpoints.
public struct EtaSample: Equatable, Sendable {
    public var activeElapsed: TimeInterval
    public var estimate: Estimate?
}

public struct LiveTurn: Equatable, Sendable {
    public var sessionID: String
    public var project: String
    public var startedAt: Date
    /// Started without a UserPromptSubmit (Vigil launched mid-turn): shown, but never stored as history.
    public var partial: Bool
    public var tasks: [TrackedTask] = []
    public var toolCount = 0
    public var lastActivity: Date
    public var running: [RunningAgent] = []
    public var finished: [SubagentRun] = []
    public var waited: TimeInterval = 0
    public var waitingSince: Date?
    /// The task list grew mid-run: by how much and when (the UI shows "+N steps" for 30 s).
    public var growth: (count: Int, at: Date)?
    public var smoother = EtaSmoother()
    /// The smoothed estimate currently shown.
    public var displayed: Estimate?
    public var samples: [EtaSample] = []
    /// The "almost done" notification was posted for this turn.
    public var notified = false

    public static func == (a: Self, b: Self) -> Bool {
        a.sessionID == b.sessionID && a.project == b.project && a.startedAt == b.startedAt && a.partial == b.partial
            && a.tasks == b.tasks && a.toolCount == b.toolCount && a.lastActivity == b.lastActivity && a.running == b.running
            && a.finished == b.finished && a.waited == b.waited && a.waitingSince == b.waitingSince
            && a.growth?.count == b.growth?.count && a.growth?.at == b.growth?.at && a.smoother == b.smoother
            && a.displayed == b.displayed && a.samples == b.samples && a.notified == b.notified
    }

    public func activeElapsed(at now: Date) -> TimeInterval {
        let waitingNow = waitingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return max(0, now.timeIntervalSince(startedAt) - waited - waitingNow)
    }

    public var tasksDone: Int { tasks.filter(\.isDone).count }

    /// The task in progress, else the first one not done yet.
    public var currentTask: TrackedTask? {
        tasks.first { $0.startedActive != nil && !$0.isDone } ?? tasks.first { !$0.isDone }
    }

    /// 1-based step shown to the user ("step 4 of 7"): the task being worked on.
    public var currentStep: Int { min(tasks.count, tasksDone + 1) }

    /// Active seconds the current task has been running: since its explicit start, else since the previous
    /// completion, else since the turn started.
    public func currentTaskElapsed(at now: Date) -> TimeInterval {
        let active = activeElapsed(at: now)
        let start = currentTask?.startedActive ?? tasks.compactMap(\.completedActive).max() ?? 0
        return max(0, active - start)
    }

    public func input(at now: Date) -> EtaInput {
        EtaInput(project: project, elapsed: activeElapsed(at: now), tasksTotal: tasks.count, tasksDone: tasksDone,
                 doneDurations: tasks.compactMap(\.duration), currentTaskElapsed: currentTaskElapsed(at: now),
                 runningAgents: running.map { ($0.type, max(0, now.timeIntervalSince($0.startedAt))) })
    }
}

/// Follows every session's current turn from hook events. Pure and deterministic like `StateMachine`, and
/// completely separate from it: the estimate is information only and never influences sleep.
public struct TurnTracker: Equatable, Sendable {
    public private(set) var turns: [String: LiveTurn] = [:]
    /// Unfinished tasks left over when a turn ended; Claude often carries on with them in the next turn.
    private var carried: [String: [TrackedTask]] = [:]
    /// Samples are kept at most this often (active seconds).
    public static let sampleInterval: TimeInterval = 5
    public static let growthBadgeDuration: TimeInterval = 30
    public static let checkpointFractions = [0.25, 0.5, 0.75]

    public init() {}

    public static func == (a: Self, b: Self) -> Bool { a.turns == b.turns && a.carried == b.carried }

    // MARK: events

    /// Returns the finished turn on Stop (nil for partial turns, which are never stored).
    public mutating func handle(_ hook: HookEvent, at now: Date) -> TurnRecord? {
        let id = hook.sessionID
        let project = Session(id: id, cwd: hook.cwd, pid: nil, state: .idle, startedAt: now, lastEventAt: now,
                              stateSince: now).projectName
        switch hook.kind {
        case .userPromptSubmit:
            if var turn = turns[id] {
                // A prompt answered while waiting or queued mid-turn: the same turn continues.
                Self.endWaiting(&turn, now: now)
                turns[id] = turn
            } else {
                var turn = LiveTurn(sessionID: id, project: project, startedAt: now, partial: false, lastActivity: now)
                turn.tasks = (carried.removeValue(forKey: id) ?? []).map {
                    TrackedTask(id: $0.id, subject: $0.subject, startedActive: $0.startedActive == nil ? nil : 0)
                }
                turns[id] = turn
            }
            return nil

        case .stop:
            guard let turn = turns.removeValue(forKey: id) else { return nil }
            let left = turn.tasks.filter { !$0.isDone }
            if left.isEmpty { carried[id] = nil } else { carried[id] = left }
            return turn.partial ? nil : record(turn, at: now)

        case .sessionEnd:
            discard([id])
            return nil

        case .notification:
            if ClaudeNotificationType.meaning(of: hook.notificationType) == .waiting { startWaiting(id, now: now) }
            return nil

        case .permissionRequest:
            startWaiting(id, now: now)
            return nil

        case .postToolUse:
            update(id, project: project, now: now) { turn in
                Self.endWaiting(&turn, now: now)
                turn.toolCount += 1
                turn.lastActivity = now
                Self.apply(hook.taskSignals, to: &turn, now: now)
            }
            return nil

        case .taskCreated, .taskCompleted:
            update(id, project: project, now: now) { turn in
                turn.lastActivity = now
                Self.apply(hook.taskSignals, to: &turn, now: now)
            }
            return nil

        case .subagentStart:
            guard let agentID = hook.agentID else { return nil }
            update(id, project: project, now: now) { turn in
                if !turn.running.contains(where: { $0.id == agentID }) {
                    turn.running.append(RunningAgent(id: agentID, type: hook.agentType.flatMap { $0.isEmpty ? nil : $0 } ?? "subagent",
                                                     startedAt: now))
                }
                turn.lastActivity = now
            }
            return nil

        case .subagentStop:
            guard let agentID = hook.agentID, var turn = turns[id],
                  let i = turn.running.firstIndex(where: { $0.id == agentID }) else { return nil }
            let agent = turn.running.remove(at: i)
            turn.finished.append(SubagentRun(type: agent.type, duration: max(0, now.timeIntervalSince(agent.startedAt))))
            turn.lastActivity = now
            turns[id] = turn
            return nil

        case .sessionStart, .selfTest:
            return nil
        }
    }

    /// Sessions whose Claude process died, or that ended: their turns are dropped (an interrupted turn says
    /// nothing reliable about how long work takes).
    public mutating func discard(_ ids: [String]) {
        for id in ids {
            turns[id] = nil
            carried[id] = nil
        }
    }

    // MARK: estimate

    /// Recomputes and smooths every running turn's estimate. Call about once per second.
    public mutating func tick(at now: Date, history: [TurnRecord]) {
        for id in turns.keys.sorted() {
            guard var turn = turns[id] else { continue }
            let active = turn.activeElapsed(at: now)
            if let raw = EtaModel.estimate(turn.input(at: now), history: history) {
                // A new basis (task list appears) is a different estimate, not a drift: no smoothing across it.
                if turn.displayed.map({ $0.basis.isTasks != raw.basis.isTasks }) ?? false { turn.smoother.reset() }
                turn.displayed = turn.smoother.update(raw, at: now)
            } else {
                turn.displayed = nil
                turn.smoother.reset()
            }
            if turn.waitingSince == nil,
               active - (turn.samples.last?.activeElapsed ?? -Self.sampleInterval) >= Self.sampleInterval {
                turn.samples.append(EtaSample(activeElapsed: active, estimate: turn.displayed))
            }
            if let g = turn.growth, now.timeIntervalSince(g.at) > Self.growthBadgeDuration { turn.growth = nil }
            turns[id] = turn
        }
    }

    /// Marks the "almost done" notification as sent for this turn. Returns false if it already was.
    public mutating func markNotified(_ id: String) -> Bool {
        guard var turn = turns[id], !turn.notified else { return false }
        turn.notified = true
        turns[id] = turn
        return true
    }

    // MARK: internals

    /// Runs `change` on the session's turn; adopts a partial turn when Vigil missed the UserPromptSubmit.
    private mutating func update(_ id: String, project: String, now: Date, _ change: (inout LiveTurn) -> Void) {
        var turn = turns[id] ?? LiveTurn(sessionID: id, project: project, startedAt: now, partial: true, lastActivity: now)
        change(&turn)
        turns[id] = turn
    }

    private mutating func startWaiting(_ id: String, now: Date) {
        guard var turn = turns[id], turn.waitingSince == nil else { return }
        turn.waitingSince = now
        turns[id] = turn
    }

    private static func endWaiting(_ turn: inout LiveTurn, now: Date) {
        guard let since = turn.waitingSince else { return }
        turn.waited += max(0, now.timeIntervalSince(since))
        turn.waitingSince = nil
    }

    private static func apply(_ signals: [TaskSignal], to turn: inout LiveTurn, now: Date) {
        let before = turn.tasks.count
        let active = turn.activeElapsed(at: now)
        for signal in signals {
            switch signal {
            case .created(let id, let subject):
                // TaskCreated and the TaskCreate tool call both report the same task: match by id, then subject.
                if let id, turn.tasks.contains(where: { $0.id == id }) { continue }
                if id == nil, turn.tasks.contains(where: { $0.subject == subject && !$0.isDone }) { continue }
                if let id, let i = turn.tasks.firstIndex(where: { $0.id.hasPrefix("subject:") && $0.subject == subject }) {
                    turn.tasks[i].id = id
                    continue
                }
                turn.tasks.append(TrackedTask(id: id ?? "subject:\(subject)", subject: subject))
            case .started(let id):
                guard let i = turn.tasks.firstIndex(where: { $0.id == id }), turn.tasks[i].startedActive == nil else { continue }
                turn.tasks[i].startedActive = active
            case .completed(let id, let subject):
                guard let i = turn.tasks.firstIndex(where: { (id != nil && $0.id == id) || (id == nil && $0.subject == subject) }),
                      !turn.tasks[i].isDone else { continue }
                Self.complete(&turn, at: i, active: active)
            case .deleted(let id):
                turn.tasks.removeAll { $0.id == id && !$0.isDone }
            case .snapshot(let items):
                Self.applySnapshot(items, to: &turn, active: active)
            }
        }
        let grew = turn.tasks.count - before
        // Growth only counts once a list existed and work on it had begun (the first TaskCreate burst is not growth).
        if grew > 0, before > 0, turn.tasks.contains(where: { $0.isDone || $0.startedActive != nil }) {
            turn.growth = (grew + (turn.growth.map { now.timeIntervalSince($0.at) <= Self.growthBadgeDuration ? $0.count : 0 } ?? 0), now)
        }
    }

    private static func complete(_ turn: inout LiveTurn, at i: Int, active: TimeInterval) {
        let previous = turn.tasks.compactMap(\.completedActive).max() ?? 0
        let start = turn.tasks[i].startedActive ?? previous
        turn.tasks[i].completedActive = active
        turn.tasks[i].duration = max(0, active - start)
    }

    /// TodoWrite sends the whole list: match items by subject, keep timings, follow status changes.
    private static func applySnapshot(_ items: [TodoItem], to turn: inout LiveTurn, active: TimeInterval) {
        var next: [TrackedTask] = []
        for item in items where item.status != .deleted {
            var task = turn.tasks.first { $0.subject == item.subject && !next.contains($0) }
                ?? TrackedTask(id: "todo:\(item.subject)", subject: item.subject)
            if item.status == .inProgress, task.startedActive == nil { task.startedActive = active }
            next.append(task)
        }
        turn.tasks = next
        for (i, item) in items.filter({ $0.status != .deleted }).enumerated() where item.status == .completed && !turn.tasks[i].isDone {
            Self.complete(&turn, at: i, active: active)
        }
    }

    private func record(_ turn: LiveTurn, at now: Date) -> TurnRecord {
        let active = turn.activeElapsed(at: now)
        var checkpoints: [EtaCheckpoint] = []
        for f in Self.checkpointFractions {
            // What was on screen at that moment: the last sample taken at or before it.
            guard let sample = turn.samples.last(where: { $0.activeElapsed <= f * active }), let e = sample.estimate else { continue }
            let tasksTotal: Int? = { if case .tasks(_, let n) = e.basis { return n } else { return nil } }()
            checkpoints.append(EtaCheckpoint(fraction: f, low: sample.activeElapsed + e.low,
                                             likely: sample.activeElapsed + e.likely, high: sample.activeElapsed + e.high,
                                             confidence: e.confidence, tasksTotal: tasksTotal))
        }
        return TurnRecord(id: "\(turn.sessionID)-\(Int(turn.startedAt.timeIntervalSince1970))", project: turn.project,
                          startedAt: turn.startedAt, duration: max(0, now.timeIntervalSince(turn.startedAt)), activeDuration: active,
                          taskCount: turn.tasks.count, taskDurations: turn.tasks.compactMap(\.duration),
                          subagents: turn.finished + turn.running.map { SubagentRun(type: $0.type, duration: now.timeIntervalSince($0.startedAt)) },
                          toolCount: turn.toolCount, checkpoints: checkpoints)
    }
}
