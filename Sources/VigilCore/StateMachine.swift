import Foundation

// MARK: - Model

public enum SessionState: String, Codable, Equatable, Sendable {
    case idle
    case working
    /// Claude is waiting for the user: a permission prompt, a question (elicitation), or an agent needing input.
    case waiting
}

public enum SessionEndReason: String, Codable, Equatable, Sendable {
    /// SessionEnd hook fired.
    case ended
    /// The Claude process died without a SessionEnd (e.g. Ctrl+C, terminal closed).
    case interrupted
    /// "working" with no events for longer than the max keep-awake duration.
    case timedOut
}

/// A subagent (Agent tool, background agent) between its SubagentStart and SubagentStop.
public struct Subagent: Equatable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var startedAt: Date

    public init(id: String, type: String, startedAt: Date) {
        self.id = id
        self.type = type
        self.startedAt = startedAt
    }
}

public struct Session: Equatable, Identifiable, Sendable {
    public var id: String
    public var cwd: String?
    public var pid: Int32?
    /// The main agent's state. Subagents are tracked separately and keep the session busy on their own.
    public var state: SessionState
    public var startedAt: Date
    public var lastEventAt: Date
    public var stateSince: Date
    /// Active subagents in start order.
    public var subagents: [Subagent] = []
    /// Most subagents seen running at once (for the history).
    public var maxSubagents = 0
    /// Total run time of subagents that have already finished.
    public var finishedSubagentTime: TimeInterval = 0
    /// Waited longer than `Config.maxWaiting`: no longer keeps the Mac awake. Reset when a new wait starts.
    public var waitExpired = false
    /// Background shells Claude started (Bash with `run_in_background`), until they end.
    public var shells: [BackgroundShell] = []
    /// Last sign of work: an activity hook (tool use, subagent, prompt, compaction) or a change in its processes.
    /// Stop, SessionEnd and Notification are not activity.
    public var lastActivityAt: Date = .distantPast
    /// Subagents that already sent SubagentStop (the last 50), so a late tool call of theirs does not revive them.
    public var endedAgentIDs: [String] = []

    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// Working by the sleep rule: the main agent is working, or any subagent is still running.
    public var isWorking: Bool { state == .working || !subagents.isEmpty }

    /// The main agent has finished its turn but subagents keep the session busy.
    public var onlySubagentsWorking: Bool { state != .working && !subagents.isEmpty }

    /// Since when the session has been busy (nil when it is not working).
    public var workingSince: Date? {
        if state == .working { return stateSince }
        return (subagents.map(\.startedAt) + shells.map(\.startedAt)).min()
    }

    /// Finished plus still-running subagent time.
    public func subagentTime(at now: Date) -> TimeInterval {
        finishedSubagentTime + subagents.reduce(0) { $0 + max(0, now.timeIntervalSince($1.startedAt)) }
    }
}

/// Why a session keeps the Mac awake. A session is busy while it has at least one.
public enum BusyReason: Equatable, Sendable {
    /// The main agent is in a turn (UserPromptSubmit … Stop).
    case turn
    /// Waiting for an answer (under the keep-awake policy, up to `Config.maxWaiting`).
    case waiting
    /// Subagents between SubagentStart and SubagentStop, background agents included.
    case subagents(Int)
    /// A background shell that is still running (the command).
    case shell(String)
    /// An activity hook within `Config.recentActivityWindow`.
    case recentActivity

    public var logText: String {
        switch self {
        case .turn: return "turn active"
        case .waiting: return "waiting for an answer"
        case .subagents(let n): return "\(n) subagent\(n == 1 ? "" : "s") active"
        case .shell(let c): return "shell active (\(c.prefix(60)))"
        case .recentActivity: return "recent activity"
        }
    }
}

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var project: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var reason: SessionEndReason
    /// Most subagents running at once during the session.
    public var maxSubagents: Int
    /// Summed run time of all subagents.
    public var subagentTime: TimeInterval

    public init(id: String, project: String, startedAt: Date, duration: TimeInterval, reason: SessionEndReason,
                maxSubagents: Int = 0, subagentTime: TimeInterval = 0) {
        self.id = id
        self.project = project
        self.startedAt = startedAt
        self.duration = duration
        self.reason = reason
        self.maxSubagents = maxSubagents
        self.subagentTime = subagentTime
    }

    // History written before subagent tracking has no subagent fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        project = try c.decode(String.self, forKey: .project)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        reason = try c.decode(SessionEndReason.self, forKey: .reason)
        maxSubagents = try c.decodeIfPresent(Int.self, forKey: .maxSubagents) ?? 0
        subagentTime = try c.decodeIfPresent(TimeInterval.self, forKey: .subagentTime) ?? 0
    }
}

public enum Phase: String, Equatable, Sendable {
    case off
    case armed
    case working
    case countdown
}

/// What "Claude is waiting for the user" does to sleep.
public enum NotificationPolicy: String, Codable, CaseIterable, Sendable {
    /// Waiting counts as idle: the normal sleep countdown (the grace period) starts. "Uspat po prodlevě".
    case treatAsIdle
    /// Waiting keeps the Mac awake (up to `Config.maxWaiting`), so a prompt can be answered from the phone
    /// through Claude Code Remote Control. The default since settings revision 3.
    case keepAwake
}

/// Claude Code's Notification hook carries a `notification_type`. Only some of them mean "waiting for you".
public enum ClaudeNotificationType {
    public enum Meaning: Equatable, Sendable {
        /// Claude needs an answer: keep the session busy (under the default policy).
        case waiting
        /// Claude finished and the prompt is sitting idle. Never keeps the Mac awake.
        case idle
        /// Unknown or missing type: logged and ignored.
        case unknown
    }

    public static let waitingTypes: Set<String> = ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog",
                                                   "agent_needs_input"]
    public static let idleTypes: Set<String> = ["idle_prompt"]

    public static func meaning(of type: String?) -> Meaning {
        guard let type else { return .unknown }
        if waitingTypes.contains(type) { return .waiting }
        if idleTypes.contains(type) { return .idle }
        return .unknown
    }
}

public enum ThermalLevel: Int, Codable, Equatable, Sendable {
    case nominal, fair, serious, critical
}

public struct Environment: Equatable, Sendable {
    public var lidClosed: Bool
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var thermal: ThermalLevel
    /// On the charger and actually charging (not just "plugged in and full").
    public var isCharging: Bool

    public init(lidClosed: Bool = false, onBattery: Bool = false, batteryPercent: Int? = nil, thermal: ThermalLevel = .nominal,
                isCharging: Bool = false) {
        self.lidClosed = lidClosed
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermal = thermal
        self.isCharging = isCharging
    }
}

public struct Config: Equatable, Codable, Sendable {
    public var graceSeconds: TimeInterval = 30
    /// Absolute limit on one keep-awake stretch (an explicit "Nechat vzhůru" overrides it).
    public var maxKeepAwake: TimeInterval = 12 * 3600
    /// Percent. 0 turns the guard off.
    public var lowBatteryThreshold: Int = 5
    /// "S otevřeným víkem uspat po nečinnosti": seconds without keyboard/mouse/trackpad input after which a
    /// forced sleep is allowed with the lid open (or in closed-lid desktop mode). 0 = never (the default).
    /// Replaces the old `sleepOnlyIfLidClosed`, which is ignored when an old settings file still has it.
    public var lidOpenIdleSleep: TimeInterval = 0
    public var notificationPolicy: NotificationPolicy = .keepAwake
    /// Under `.keepAwake`: after waiting this long for an answer, notify and start the normal sleep countdown.
    public var maxWaiting: TimeInterval = 2 * 3600
    public var manualKeepAwake: TimeInterval = 3600
    /// A subagent with no SubagentStop for this long is dropped (a lost hook must not pin the Mac awake).
    public var stuckSubagentLimit: TimeInterval = 2 * 3600
    /// "Shelly na pozadí".
    public var backgroundShells: BackgroundShellPolicy = .exceptServers
    /// Any activity hook keeps its session busy this long (background agents, auto-continued turns). 0 = off.
    public var recentActivityWindow: TimeInterval = 120
    /// The silence failsafe: a busy session without any activity (hook or process change) for this long no longer
    /// keeps the Mac awake. 0 = off. `maxKeepAwake` stays the absolute limit.
    public var silenceLimit: TimeInterval = 30 * 60
    /// A server (dev server, `stripe listen`, `tail -f`) running this long with its CPU under `serverCPUThreshold`
    /// counts as idle.
    public var serverIdleAfter: TimeInterval = 5 * 60
    /// Percent of one core, averaged over `serverIdleAfter`.
    public var serverCPUThreshold: Double = 2

    public init() {}

    // Every key is optional so settings saved by an older build (missing newer keys) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        graceSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .graceSeconds) ?? d.graceSeconds
        maxKeepAwake = try c.decodeIfPresent(TimeInterval.self, forKey: .maxKeepAwake) ?? d.maxKeepAwake
        lowBatteryThreshold = try c.decodeIfPresent(Int.self, forKey: .lowBatteryThreshold) ?? d.lowBatteryThreshold
        lidOpenIdleSleep = try c.decodeIfPresent(TimeInterval.self, forKey: .lidOpenIdleSleep) ?? d.lidOpenIdleSleep
        notificationPolicy = try c.decodeIfPresent(NotificationPolicy.self, forKey: .notificationPolicy) ?? d.notificationPolicy
        maxWaiting = try c.decodeIfPresent(TimeInterval.self, forKey: .maxWaiting) ?? d.maxWaiting
        manualKeepAwake = try c.decodeIfPresent(TimeInterval.self, forKey: .manualKeepAwake) ?? d.manualKeepAwake
        stuckSubagentLimit = try c.decodeIfPresent(TimeInterval.self, forKey: .stuckSubagentLimit) ?? d.stuckSubagentLimit
        backgroundShells = (try? c.decodeIfPresent(BackgroundShellPolicy.self, forKey: .backgroundShells)) ?? d.backgroundShells
        recentActivityWindow = try c.decodeIfPresent(TimeInterval.self, forKey: .recentActivityWindow) ?? d.recentActivityWindow
        silenceLimit = try c.decodeIfPresent(TimeInterval.self, forKey: .silenceLimit) ?? d.silenceLimit
        serverIdleAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .serverIdleAfter) ?? d.serverIdleAfter
        serverCPUThreshold = try c.decodeIfPresent(Double.self, forKey: .serverCPUThreshold) ?? d.serverCPUThreshold
    }
}

/// Why the app refuses to hold the Mac awake right now.
public enum GuardReason: String, Equatable, Sendable {
    case lowBattery
    case thermal
    case maxDuration
    case manualSleep
}

// MARK: - Events and effects

public enum HookKind: String, Codable, Equatable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
    case notification = "Notification"
    case sessionEnd = "SessionEnd"
    /// Heartbeat: a tool call finished, so Claude is working (and a waiting session has been answered).
    case postToolUse = "PostToolUse"
    /// A permission dialog is about to be shown: a second "waiting for the user" signal next to Notification.
    /// hook.sh never prints a decision, so Claude Code always asks the user as usual.
    case permissionRequest = "PermissionRequest"
    /// A subagent (Agent tool, background agent) started; carries agent_id and agent_type.
    case subagentStart = "SubagentStart"
    /// A subagent finished; carries agent_id.
    case subagentStop = "SubagentStop"
    /// Claude added an item to its task list (task_id, task_subject). ETA only; the state machine ignores it.
    /// Exit code 2 from this hook would cancel the task, so hook.sh must always exit 0.
    case taskCreated = "TaskCreated"
    /// Claude completed an item of its task list. ETA only; ignored by the state machine.
    case taskCompleted = "TaskCompleted"
    /// Used by the self-test round trip; never reaches the state machine.
    case selfTest = "VigilSelfTest"
}

public struct HookEvent: Equatable, Sendable {
    public var kind: HookKind
    public var sessionID: String
    public var cwd: String?
    public var pid: Int32?
    /// Subagent hooks only.
    public var agentID: String?
    public var agentType: String?
    /// Notification hooks only (`permission_prompt`, `idle_prompt`, ...).
    public var notificationType: String?
    /// PostToolUse only.
    public var toolName: String?
    /// Task list changes (TaskCreated/TaskCompleted, or TaskCreate/TaskUpdate/TodoWrite tool calls). ETA only.
    public var taskSignals: [TaskSignal]
    /// SessionStart only: "startup", "resume", "clear" or "compact".
    public var source: String?
    /// Stop / SubagentStop: the session's background tasks at that moment. nil = the payload had no such field.
    public var backgroundTasks: [ReportedTask]?
    /// PostToolUse of a Bash call with `run_in_background`: the shell it started.
    public var startedShell: ReportedTask?
    /// Background tasks reported as over (a `<task-notification>` prompt, TaskStop, KillShell).
    public var endedTaskIDs: [String]

    public init(kind: HookKind, sessionID: String, cwd: String? = nil, pid: Int32? = nil,
                agentID: String? = nil, agentType: String? = nil, notificationType: String? = nil,
                toolName: String? = nil, taskSignals: [TaskSignal] = [], source: String? = nil,
                backgroundTasks: [ReportedTask]? = nil, startedShell: ReportedTask? = nil, endedTaskIDs: [String] = []) {
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.pid = pid
        self.agentID = agentID
        self.agentType = agentType
        self.notificationType = notificationType
        self.toolName = toolName
        self.taskSignals = taskSignals
        self.source = source
        self.backgroundTasks = backgroundTasks
        self.startedShell = startedShell
        self.endedTaskIDs = endedTaskIDs
    }
}

public enum Event: Equatable, Sendable {
    case hook(HookEvent)
    /// Call about once per second.
    case tick
    /// Sessions whose Claude process is gone (from `PIDLiveness`).
    case sessionsDied([String])
    case setEnabled(Bool)
    case cancelCountdown
    /// "Nechat vzhůru": an explicit keep-awake for a while or until cancelled.
    case keepAwake(KeepAwakeDuration)
    /// "Zrušit" next to a running keep-awake.
    case cancelKeepAwake
    case sleepNow
    case environment(Environment)
    case configChanged(Config)
    /// A fresh reading of lid, displays, input idle time and assertions for the sleep gate. Send it about once
    /// per second (before `.tick`) and right before hook events.
    case presence(PresenceSnapshot)
    /// What the process sampler saw of the sessions' processes (every few seconds).
    case processes([ProcessObservation])
    /// "Ignorovat" next to a running background shell.
    case ignoreShell(sessionID: String, shellID: String)
}

/// How long "Nechat vzhůru" holds the Mac awake.
public enum KeepAwakeDuration: Codable, Equatable, Hashable, Sendable {
    case minutes(Int)
    /// "Do odvolání".
    case untilCancelled

    /// The menu: 30 min, 1, 2, 4 and 8 h, until cancelled ("Vlastní…" adds any hours and minutes).
    public static let presets: [KeepAwakeDuration] = [.minutes(30), .minutes(60), .minutes(120), .minutes(240), .minutes(480), .untilCancelled]

    public var seconds: TimeInterval? {
        if case .minutes(let m) = self { return TimeInterval(max(1, m) * 60) }
        return nil
    }
}

/// One session's processes, as the process sampler saw them.
public struct ProcessObservation: Equatable, Sendable {
    public var sessionID: String
    /// Its processes changed since the last sample (new or ended processes, CPU used): counts as activity.
    public var activity: Bool
    public var shells: [String: ShellObservation]

    public init(sessionID: String, activity: Bool, shells: [String: ShellObservation] = [:]) {
        self.sessionID = sessionID
        self.activity = activity
        self.shells = shells
    }
}

public struct ShellObservation: Equatable, Sendable {
    /// Its process is among the descendants of the session's Claude process.
    public var found: Bool
    /// It was found before and is gone now: the shell has ended.
    public var exited: Bool
    /// Average CPU of its process tree over the server window; nil until there is that much history.
    public var cpuPercent: Double?

    public init(found: Bool, exited: Bool = false, cpuPercent: Double? = nil) {
        self.found = found
        self.exited = exited
        self.cpuPercent = cpuPercent
    }
}

public enum Effect: Equatable, Sendable {
    /// `pmset disablesleep 1` + IOPM assertions.
    case acquireAwake
    /// `pmset disablesleep 0` + release assertions.
    case releaseAwake
    /// Always preceded by `.releaseAwake` in the same batch. Executors must run effects in order.
    case sleepNow
    case showCountdown(deadline: Date)
    case dismissCountdown
    case notifyGuard(GuardReason)
    case record(SessionRecord)
    /// A subagent hit the stuck-subagent limit and was dropped; the executor logs a warning.
    case droppedStuckSubagent(project: String, agentID: String, agentType: String, age: TimeInterval)
    /// A session waited for an answer longer than `Config.maxWaiting`; the executor notifies the user.
    case waitTimedOut(project: String, waited: TimeInterval)
    /// A Notification hook with an unknown (or missing) `notification_type`; the executor logs it.
    case ignoredNotification(type: String?)
    /// A sleep or a skip decided by the sleep gate (or "Uspat hned"); the executor logs it and keeps it in history.
    case sleepDecision(SleepDecisionRecord)
}

// MARK: - State machine

/// Pure, deterministic state machine. All time comes in through the `at now:` parameter.
public struct StateMachine: Equatable {
    public private(set) var phase: Phase = .off
    public private(set) var sessions: [Session] = []
    public private(set) var countdownDeadline: Date?
    public private(set) var keepAwakeUntil: Date?
    /// "Do odvolání": held until cancelled (or a battery / heat guard trips).
    public private(set) var keepAwakeIndefinite = false
    /// When the running keep-awake was asked for (its progress bar).
    public private(set) var keepAwakeStartedAt: Date?
    /// True while `disablesleep 1` is (supposed to be) in force.
    public private(set) var awakeHeld = false
    public private(set) var awakeSince: Date?
    public private(set) var latch: GuardReason?
    public private(set) var enabled: Bool
    public private(set) var environment = Environment()
    public private(set) var config: Config
    /// Latest presence reading for the sleep gate (nil until the first one: then nothing is ever forced).
    public private(set) var presence: PresenceSnapshot?
    public private(set) var countdownStartedAt: Date?
    /// Claude finished but the gate refused a forced sleep: Vigil released its keep-awake and macOS sleeps on its
    /// own. The UI shows "Hotovo · Mac běží normálně". Cleared when Vigil holds the Mac awake again.
    public private(set) var handedBack: SleepDecisionRecord?
    /// Time of the event being handled (or the last one): what the busy rules are evaluated at.
    public private(set) var clock: Date = .distantPast

    public init(enabled: Bool = true, config: Config = Config(), presence: PresenceSnapshot? = nil) {
        self.enabled = enabled
        self.config = config
        self.presence = presence
        self.phase = enabled ? .armed : .off
    }

    /// What the sleep gate says right now.
    public var gate: GateDecision { SleepGate.decide(presence, lidOpenIdleThreshold: config.lidOpenIdleSleep) }

    /// The reason acquiring is currently blocked, if any (latch or environment guard).
    public var blockedReason: GuardReason? { latch ?? environmentGuard }

    /// Sessions doing work: a turn, subagents, a running background shell or recent activity (waiting is not work).
    public var workingSessions: [Session] { sessions.filter { busyReasons($0).contains { $0 != .waiting } } }

    /// Background shells that keep their session busy right now (by "Shelly na pozadí").
    public func activeShells(_ s: Session) -> [BackgroundShell] {
        s.shells.filter { shellCounts($0, at: clock) }
    }

    private func shellCounts(_ shell: BackgroundShell, at now: Date) -> Bool {
        guard !shell.ignored else { return false }
        switch config.backgroundShells {
        case .ignore: return false
        case .always: return true
        case .exceptServers:
            guard shell.isServer, now.timeIntervalSince(shell.startedAt) >= config.serverIdleAfter,
                  let cpu = shell.cpuPercent else { return true }
            return cpu >= config.serverCPUThreshold
        }
    }

    /// The one place that decides whether a session keeps the Mac awake. Work (turn, subagents, shells, recent
    /// activity) stops counting after `silenceLimit` without any activity, except a shell whose process is still
    /// alive: that is work until it ends (the 12-hour limit still applies). The failsafe is for signals without a
    /// live process behind them, such as a subagent whose SubagentStop never came. Waiting has its own limit.
    public func busyReasons(_ s: Session) -> [BusyReason] {
        let now = clock
        var work: [BusyReason] = []
        if s.state == .working { work.append(.turn) }
        if !s.subagents.isEmpty { work.append(.subagents(s.subagents.count)) }
        let shells = s.shells.filter { shellCounts($0, at: now) }
        work += shells.map { .shell($0.command) }
        if config.recentActivityWindow > 0, now.timeIntervalSince(s.lastActivityAt) < config.recentActivityWindow {
            work.append(.recentActivity)
        }
        if config.silenceLimit > 0, now.timeIntervalSince(s.lastActivityAt) >= config.silenceLimit {
            work = shells.filter { $0.processAlive(at: now) }.map { .shell($0.command) }
        }
        if s.state == .waiting, config.notificationPolicy == .keepAwake, !s.waitExpired { work.insert(.waiting, at: 0) }
        return work
    }

    /// Busy for the done sound: the same rule without the recent-activity window and the silence failsafe, so the
    /// sound plays when the work really ends (not two minutes later), and never while shells or subagents run.
    public func busyForChime(_ s: Session) -> Bool {
        s.state != .idle || !s.subagents.isEmpty || s.shells.contains { shellCounts($0, at: clock) }
    }

    private var environmentGuard: GuardReason? {
        if config.lowBatteryThreshold > 0, environment.onBattery, let pct = environment.batteryPercent,
           pct < config.lowBatteryThreshold {
            return .lowBattery
        }
        if environment.lidClosed, environment.thermal.rawValue >= ThermalLevel.serious.rawValue {
            return .thermal
        }
        return nil
    }

    private func isBlocking(_ session: Session) -> Bool { !busyReasons(session).isEmpty }

    private var anyBlockingSession: Bool { sessions.contains(where: isBlocking) }

    /// An explicit "Nechat vzhůru" is running.
    public func keepAwakeActive(_ now: Date) -> Bool {
        if keepAwakeIndefinite { return true }
        if let until = keepAwakeUntil { return now < until }
        return false
    }

    private mutating func clearKeepAwake() {
        keepAwakeUntil = nil
        keepAwakeIndefinite = false
        keepAwakeStartedAt = nil
    }

    // MARK: handle

    public mutating func handle(_ event: Event, at now: Date) -> [Effect] {
        var fx: [Effect] = []
        clock = now

        switch event {
        case .hook(let hook):
            handleHook(hook, now: now, fx: &fx)

        case .tick:
            handleTick(now: now, fx: &fx)

        case .sessionsDied(let ids):
            for id in ids {
                if let idx = sessions.firstIndex(where: { $0.id == id }) {
                    fx.append(.record(removeSession(at: idx, reason: .interrupted, now: now)))
                }
            }

        case .setEnabled(let value):
            enabled = value
            if !value { clearKeepAwake(); latch = nil }

        case .cancelCountdown:
            if phase == .countdown {
                countdownDeadline = nil
                countdownStartedAt = nil
                fx.append(.dismissCountdown)
                // Back to armed; a still-blocking session would immediately flip us to working again,
                // so latch until everything is idle.
                if anyBlockingSession { latch = .manualSleep }
                // Force the release path even though "blocking" might be false.
                clearKeepAwake()
                forceArmed(now: now, fx: &fx)
            }

        case .keepAwake(let duration):
            guard enabled else { break }
            keepAwakeStartedAt = now
            if let seconds = duration.seconds {
                keepAwakeUntil = now.addingTimeInterval(seconds)
                keepAwakeIndefinite = false
            } else {
                keepAwakeUntil = nil
                keepAwakeIndefinite = true
            }
            latch = nil
            if countdownDeadline != nil {
                countdownDeadline = nil
                countdownStartedAt = nil
                fx.append(.dismissCountdown)
            }

        case .cancelKeepAwake:
            // Back to what the sessions say: the grace period starts if nothing else is busy.
            clearKeepAwake()

        case .sleepNow:
            // "Uspat hned" is the one sleep that never asks the gate: the user is right there asking for it.
            clearKeepAwake()
            if countdownDeadline != nil {
                countdownDeadline = nil
                countdownStartedAt = nil
                fx.append(.dismissCountdown)
            }
            if awakeHeld { fx.append(.releaseAwake) }
            awakeHeld = false
            awakeSince = nil
            fx.append(.sleepDecision(SleepDecisionRecord(date: now, trigger: .userRequested, slept: true, reason: .userRequested)))
            fx.append(.sleepNow)
            if anyBlockingSession { latch = .manualSleep }

        case .environment(let env):
            environment = env

        case .configChanged(let new):
            config = new

        case .presence(let snapshot):
            presence = snapshot
            checkCountdown(now: now, fx: &fx)

        case .processes(let observations):
            for o in observations {
                guard let i = sessions.firstIndex(where: { $0.id == o.sessionID }) else { continue }
                if o.activity { sessions[i].lastActivityAt = now }
                for (id, seen) in o.shells {
                    guard let k = sessions[i].shells.firstIndex(where: { $0.id == id }) else { continue }
                    if seen.exited, sessions[i].shells[k].processFound {
                        sessions[i].shells.remove(at: k)
                        sessions[i].lastActivityAt = now
                        continue
                    }
                    if seen.found {
                        sessions[i].shells[k].processFound = true
                        sessions[i].shells[k].processSeenAt = now
                    }
                    if let cpu = seen.cpuPercent { sessions[i].shells[k].cpuPercent = cpu }
                }
            }

        case .ignoreShell(let sessionID, let shellID):
            if let i = sessions.firstIndex(where: { $0.id == sessionID }),
               let k = sessions[i].shells.firstIndex(where: { $0.id == shellID }) {
                sessions[i].shells[k].ignored = true
            }
        }

        reconcile(now: now, fx: &fx)
        return fx
    }

    // MARK: hooks

    private mutating func handleHook(_ hook: HookEvent, now: Date, fx: inout [Effect]) {
        let index = sessions.firstIndex(where: { $0.id == hook.sessionID })

        switch hook.kind {
        case .selfTest:
            return

        case .taskCreated, .taskCompleted:
            // Task list progress feeds the (information-only) work-time estimate. Here it only counts as activity
            // of a session already known: it never creates one.
            if let index { sessions[index].lastActivityAt = now }
            return

        case .sessionEnd:
            if let index {
                fx.append(.record(removeSession(at: index, reason: .ended, now: now)))
            }
            return

        case .postToolUse:
            // Heartbeat. It wakes a session that was waiting on the user (a permission prompt that was approved
            // fires no UserPromptSubmit), and it adopts a session we have not seen yet (Vigil started or
            // restarted mid-task) - but only with a PID, so a dead process can always be pruned.
            // It never turns an idle session back into a turn: as activity it keeps the session busy for the
            // recent-activity window only, so a late, out-of-order heartbeat cannot pin the Mac awake.
            let i: Int
            if let index {
                i = index
                sessions[i].lastEventAt = now
                if let pid = hook.pid { sessions[i].pid = pid }
                if sessions[i].state == .waiting { setState(.working, at: i, now: now) }
            } else {
                guard let pid = hook.pid else { return }
                sessions.append(Session(id: hook.sessionID, cwd: hook.cwd, pid: pid, state: .working,
                                        startedAt: now, lastEventAt: now, stateSince: now))
                i = sessions.count - 1
            }
            sessions[i].lastActivityAt = now
            // A tool call of a subagent we never saw start (it started before Vigil did): track it from here.
            if let agentID = hook.agentID, !sessions[i].endedAgentIDs.contains(agentID),
               !sessions[i].subagents.contains(where: { $0.id == agentID }) {
                sessions[i].subagents.append(Subagent(id: agentID, type: Self.agentType(hook.agentType), startedAt: now))
                sessions[i].maxSubagents = max(sessions[i].maxSubagents, sessions[i].subagents.count)
            }
            if let shell = hook.startedShell, !sessions[i].shells.contains(where: { $0.id == shell.id }) {
                sessions[i].shells.append(BackgroundShell(id: shell.id, command: Self.shellLabel(shell), startedAt: now))
            }
            endTasks(hook.endedTaskIDs, at: i)
            return

        case .subagentStart:
            // Without an agent_id a later SubagentStop could never be matched, so it is not tracked.
            guard let agentID = hook.agentID, !agentID.isEmpty else { return }
            let i = sessionIndex(for: hook, existing: index, now: now)
            sessions[i].lastActivityAt = now
            if !sessions[i].subagents.contains(where: { $0.id == agentID }) {
                sessions[i].subagents.append(Subagent(id: agentID, type: Self.agentType(hook.agentType), startedAt: now))
                sessions[i].maxSubagents = max(sessions[i].maxSubagents, sessions[i].subagents.count)
            }
            return

        case .subagentStop:
            // Unknown session or agent (Vigil started mid-session, the agent was already dropped, or one of Claude
            // Code's internal agents with no agent_type, such as compaction or the away summary): ignored entirely.
            guard let index, let agentID = hook.agentID,
                  let a = sessions[index].subagents.firstIndex(where: { $0.id == agentID }) else { return }
            let agent = sessions[index].subagents.remove(at: a)
            sessions[index].endedAgentIDs = Array((sessions[index].endedAgentIDs + [agentID]).suffix(50))
            sessions[index].finishedSubagentTime += max(0, now.timeIntervalSince(agent.startedAt))
            sessions[index].lastEventAt = now
            sessions[index].lastActivityAt = now
            if let pid = hook.pid { sessions[index].pid = pid }
            // Its background_tasks still lists the agent itself as running; the shells in it are current.
            if let reported = hook.backgroundTasks { syncShells(reported, at: index, now: now) }
            return

        case .notification:
            switch ClaudeNotificationType.meaning(of: hook.notificationType) {
            case .waiting:
                break
            case .idle:
                // Claude finished and the prompt sits idle. It never creates a session, keeps anything awake,
                // or restarts a running countdown: an idle session simply stays idle.
                if let index, sessions[index].state != .idle { setState(.idle, at: index, now: now) }
                return
            case .unknown:
                fx.append(.ignoredNotification(type: hook.notificationType))
                return
            }

        case .sessionStart, .userPromptSubmit, .stop, .permissionRequest:
            break
        }

        let i = sessionIndex(for: hook, existing: index, now: now)

        let newState: SessionState?
        switch hook.kind {
        case .userPromptSubmit: newState = .working
        case .stop: newState = .idle
        case .notification, .permissionRequest: newState = .waiting
        // SessionStart never resets a session: resume, clear and compact keep whatever it was doing (a new
        // session starts idle).
        default: newState = nil
        }
        if let newState, sessions[i].state != newState { setState(newState, at: i, now: now) }

        switch hook.kind {
        case .userPromptSubmit, .permissionRequest:
            // Auto-continued turns arrive as UserPromptSubmit too: a `<task-notification>` (a background shell
            // ended) or an `<agent-message>` (a background agent handed back).
            sessions[i].lastActivityAt = now
            endTasks(hook.endedTaskIDs, at: i)
        case .sessionStart where hook.source == "compact":
            sessions[i].lastActivityAt = now
        case .stop:
            // background_tasks is the authoritative list of what still runs after the turn.
            if let reported = hook.backgroundTasks {
                syncShells(reported, at: i, now: now)
                syncSubagents(reported, at: i, now: now)
            }
        default:
            break
        }
        // A fresh prompt lifts a manual-sleep latch.
        if hook.kind == .userPromptSubmit, latch == .manualSleep { latch = nil }
    }

    /// Keeps the shells Claude Code reports as running, adds the ones Vigil missed and drops the rest.
    private mutating func syncShells(_ reported: [ReportedTask], at i: Int, now: Date) {
        let running = reported.filter { $0.kind == .shell && $0.isRunning }
        if running.contains(where: { r in !sessions[i].shells.contains { $0.id == r.id } }) { sessions[i].lastActivityAt = now }
        sessions[i].shells = running.map { r in
            sessions[i].shells.first { $0.id == r.id } ?? BackgroundShell(id: r.id, command: Self.shellLabel(r), startedAt: now)
        }
    }

    /// At Stop no foreground subagent can still run: tracked subagents missing from the list lost their
    /// SubagentStop and are dropped; running background agents Vigil never saw start are adopted.
    private mutating func syncSubagents(_ reported: [ReportedTask], at i: Int, now: Date) {
        let running = reported.filter { $0.kind == .subagent && $0.isRunning }
        let ids = Set(running.map(\.id))
        for agent in sessions[i].subagents where !ids.contains(agent.id) {
            sessions[i].finishedSubagentTime += max(0, now.timeIntervalSince(agent.startedAt))
        }
        sessions[i].subagents.removeAll { !ids.contains($0.id) }
        for r in running where !sessions[i].subagents.contains(where: { $0.id == r.id }) {
            sessions[i].subagents.append(Subagent(id: r.id, type: Self.agentType(r.agentType), startedAt: now))
        }
        sessions[i].maxSubagents = max(sessions[i].maxSubagents, sessions[i].subagents.count)
    }

    private mutating func endTasks(_ ids: [String], at i: Int) {
        guard !ids.isEmpty else { return }
        sessions[i].shells.removeAll { ids.contains($0.id) }
    }

    private static func shellLabel(_ r: ReportedTask) -> String {
        let text = (r.command ?? r.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "shell" : text
    }

    private mutating func setState(_ state: SessionState, at index: Int, now: Date) {
        sessions[index].state = state
        sessions[index].stateSince = now
        sessions[index].waitExpired = false
    }

    /// Index of the hook's session (created idle if new), with lastEventAt / cwd / pid refreshed.
    private mutating func sessionIndex(for hook: HookEvent, existing index: Int?, now: Date) -> Int {
        let i: Int
        if let index {
            i = index
        } else {
            // A session Vigil first sees counts as active now: it may already have shells or agents running.
            sessions.append(Session(id: hook.sessionID, cwd: hook.cwd, pid: hook.pid, state: .idle,
                                    startedAt: now, lastEventAt: now, stateSince: now, lastActivityAt: now))
            i = sessions.count - 1
        }
        sessions[i].lastEventAt = now
        if let cwd = hook.cwd, !cwd.isEmpty { sessions[i].cwd = cwd }
        if let pid = hook.pid { sessions[i].pid = pid }
        return i
    }

    private static func agentType(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "subagent" }
        return raw
    }

    /// Removing a session (SessionEnd, dead PID, timeout) also clears all its subagents.
    @discardableResult
    private mutating func removeSession(at index: Int, reason: SessionEndReason, now: Date) -> SessionRecord {
        let s = sessions.remove(at: index)

        return SessionRecord(id: s.id, project: s.projectName, startedAt: s.startedAt,
                             duration: max(0, now.timeIntervalSince(s.startedAt)), reason: reason,
                             maxSubagents: s.maxSubagents, subagentTime: s.subagentTime(at: now))
    }

    // MARK: tick

    private mutating func handleTick(now: Date, fx: inout [Effect]) {
        // Drop stale working sessions (no events for longer than the max duration).
        let stale = sessions.enumerated().filter {
            $0.element.state == .working && now.timeIntervalSince($0.element.lastEventAt) > config.maxKeepAwake
        }.map { $0.element.id }
        for id in stale {
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                fx.append(.record(removeSession(at: idx, reason: .timedOut, now: now)))
            }
        }

        // Stuck-subagent guard: a subagent whose SubagentStop never came is dropped after the limit.
        for i in sessions.indices {
            let stuck = sessions[i].subagents.filter { now.timeIntervalSince($0.startedAt) > config.stuckSubagentLimit }
            guard !stuck.isEmpty else { continue }
            sessions[i].subagents.removeAll { a in stuck.contains { $0.id == a.id } }
            for a in stuck {
                let age = now.timeIntervalSince(a.startedAt)
                sessions[i].finishedSubagentTime += age
                fx.append(.droppedStuckSubagent(project: sessions[i].projectName, agentID: a.id, agentType: a.type, age: age))
            }
        }

        // Max wait: a session that has waited for an answer too long stops keeping the Mac awake. Reconcile
        // then starts the normal sleep countdown (unless something else still works).
        if config.notificationPolicy == .keepAwake {
            for i in sessions.indices where sessions[i].state == .waiting && !sessions[i].waitExpired {
                let waited = now.timeIntervalSince(sessions[i].stateSince)
                guard waited >= config.maxWaiting else { continue }
                sessions[i].waitExpired = true
                fx.append(.waitTimedOut(project: sessions[i].projectName, waited: waited))
            }
        }

        if let until = keepAwakeUntil, now >= until { clearKeepAwake() }

        // Max keep-awake failsafe. An explicit "Nechat vzhůru" overrides it (the battery and heat guards still apply).
        if awakeHeld, !keepAwakeActive(now), let since = awakeSince, now.timeIntervalSince(since) >= config.maxKeepAwake {
            trip(.maxDuration, now: now, fx: &fx)
            return
        }

        // Countdown expiry: restore first, then ask the gate once more (with the freshest reading), sleep last.
        if phase == .countdown, let deadline = countdownDeadline, now >= deadline {
            countdownDeadline = nil
            countdownStartedAt = nil
            fx.append(.dismissCountdown)
            fx.append(.releaseAwake)
            awakeHeld = false
            awakeSince = nil
            let g = gate
            fx.append(.sleepDecision(SleepDecisionRecord(date: now, trigger: .countdownExpired, slept: g.allow, reason: g.reason)))
            if g.allow {
                fx.append(.sleepNow)
            } else {
                handedBack = SleepDecisionRecord(date: now, trigger: .countdownExpired, slept: false, reason: g.reason)
            }
            forceArmed(now: now, fx: &fx)
        }
    }

    // MARK: guards / latch

    /// Release immediately, sleep only if the gate allows, and refuse to re-acquire until the condition clears.
    /// Battery, heat and the max-duration failsafe all protect an unattended Mac; with someone at it, Vigil hands
    /// sleep back to macOS instead of yanking the machine to sleep under them.
    private mutating func trip(_ reason: GuardReason, now: Date, fx: inout [Effect]) {
        if countdownDeadline != nil {
            countdownDeadline = nil
            countdownStartedAt = nil
            fx.append(.dismissCountdown)
        }
        clearKeepAwake()
        fx.append(.notifyGuard(reason))
        if awakeHeld { fx.append(.releaseAwake) }
        awakeHeld = false
        awakeSince = nil
        let trigger: SleepTrigger = reason == .lowBattery ? .lowBattery : reason == .thermal ? .thermal : .maxDuration
        if reason != .manualSleep {
            let g = gate
            fx.append(.sleepDecision(SleepDecisionRecord(date: now, trigger: trigger, slept: g.allow, reason: g.reason)))
            if g.allow { fx.append(.sleepNow) }
        }
        if reason == .maxDuration || reason == .manualSleep { latch = reason }
    }

    /// While the countdown runs: any keyboard, mouse or trackpad input since it started, or the gate turning
    /// (lid opened, a video started), cancels it and hands sleep back to macOS. No notification, back to Ready.
    private mutating func checkCountdown(now: Date, fx: inout [Effect]) {
        guard phase == .countdown, countdownDeadline != nil, let started = countdownStartedAt, let presence else { return }
        let reason: GateReason?
        if presence.idleSeconds + 1 < now.timeIntervalSince(started) {
            reason = .inputDuringCountdown(seconds: Int(presence.idleSeconds))
        } else if !gate.allow {
            reason = gate.reason
        } else {
            reason = nil
        }
        guard let reason else { return }
        countdownDeadline = nil
        countdownStartedAt = nil
        clearKeepAwake()
        fx.append(.dismissCountdown)
        fx.append(.sleepDecision(SleepDecisionRecord(date: now, trigger: .countdownCancelled, slept: false, reason: reason)))
        // Someone is back at the Mac: "Připraveno", not "Hotovo · Mac běží normálně".
        handedBack = nil
        if anyBlockingSession { latch = .manualSleep }
        forceArmed(now: now, fx: &fx)
    }

    private mutating func forceArmed(now: Date, fx: inout [Effect]) {
        if awakeHeld {
            fx.append(.releaseAwake)
            awakeHeld = false
            awakeSince = nil
        }
        phase = enabled ? .armed : .off
    }

    // MARK: reconcile

    private mutating func reconcile(now: Date, fx: inout [Effect]) {
        // Latches clear once nothing blocks anymore.
        if latch != nil, !anyBlockingSession, !keepAwakeActive(now) { latch = nil }

        if !enabled {
            if countdownDeadline != nil { countdownDeadline = nil; countdownStartedAt = nil; fx.append(.dismissCountdown) }
            if awakeHeld { fx.append(.releaseAwake); awakeHeld = false; awakeSince = nil }
            phase = .off
            return
        }

        // Environment guard trips while we hold the Mac awake.
        if awakeHeld, let env = environmentGuard {
            trip(env, now: now, fx: &fx)
            phase = .armed
            return
        }

        let blocked = blockedReason != nil
        let blocking = anyBlockingSession || keepAwakeActive(now)

        if blocking && !blocked {
            if !awakeHeld {
                fx.append(.acquireAwake)
                awakeHeld = true
                awakeSince = now
                handedBack = nil
            }
            if countdownDeadline != nil {
                countdownDeadline = nil
                countdownStartedAt = nil
                fx.append(.dismissCountdown)
            }
            phase = .working
        } else if awakeHeld {
            // Was working, nothing blocks any more: the countdown only runs if the gate would allow the sleep.
            // Otherwise release at once and let macOS sleep by its own Energy settings: no countdown, no notification.
            if countdownDeadline == nil {
                let g = gate
                if g.allow {
                    let deadline = now.addingTimeInterval(config.graceSeconds)
                    countdownDeadline = deadline
                    countdownStartedAt = now
                    fx.append(.showCountdown(deadline: deadline))
                } else {
                    let record = SleepDecisionRecord(date: now, trigger: .finished, slept: false, reason: g.reason)
                    fx.append(.sleepDecision(record))
                    handedBack = record
                    clearKeepAwake()
                    forceArmed(now: now, fx: &fx)
                    return
                }
            }
            phase = .countdown
        } else {
            phase = .armed
        }
    }
}
