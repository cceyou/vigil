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
        return subagents.map(\.startedAt).min()
    }

    /// Finished plus still-running subagent time.
    public func subagentTime(at now: Date) -> TimeInterval {
        finishedSubagentTime + subagents.reduce(0) { $0 + max(0, now.timeIntervalSince($1.startedAt)) }
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
    public var maxKeepAwake: TimeInterval = 8 * 3600
    /// Percent. 0 turns the guard off.
    public var lowBatteryThreshold: Int = 5
    public var sleepOnlyIfLidClosed: Bool = false
    public var notificationPolicy: NotificationPolicy = .keepAwake
    /// Under `.keepAwake`: after waiting this long for an answer, notify and start the normal sleep countdown.
    public var maxWaiting: TimeInterval = 2 * 3600
    public var manualKeepAwake: TimeInterval = 3600
    /// A subagent with no SubagentStop for this long is dropped (a lost hook must not pin the Mac awake).
    public var stuckSubagentLimit: TimeInterval = 2 * 3600

    public init() {}

    // Every key is optional so settings saved by an older build (missing newer keys) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        graceSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .graceSeconds) ?? d.graceSeconds
        maxKeepAwake = try c.decodeIfPresent(TimeInterval.self, forKey: .maxKeepAwake) ?? d.maxKeepAwake
        lowBatteryThreshold = try c.decodeIfPresent(Int.self, forKey: .lowBatteryThreshold) ?? d.lowBatteryThreshold
        sleepOnlyIfLidClosed = try c.decodeIfPresent(Bool.self, forKey: .sleepOnlyIfLidClosed) ?? d.sleepOnlyIfLidClosed
        notificationPolicy = try c.decodeIfPresent(NotificationPolicy.self, forKey: .notificationPolicy) ?? d.notificationPolicy
        maxWaiting = try c.decodeIfPresent(TimeInterval.self, forKey: .maxWaiting) ?? d.maxWaiting
        manualKeepAwake = try c.decodeIfPresent(TimeInterval.self, forKey: .manualKeepAwake) ?? d.manualKeepAwake
        stuckSubagentLimit = try c.decodeIfPresent(TimeInterval.self, forKey: .stuckSubagentLimit) ?? d.stuckSubagentLimit
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

    public init(kind: HookKind, sessionID: String, cwd: String? = nil, pid: Int32? = nil,
                agentID: String? = nil, agentType: String? = nil, notificationType: String? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.pid = pid
        self.agentID = agentID
        self.agentType = agentType
        self.notificationType = notificationType
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
    case keepAwake
    case sleepNow
    case environment(Environment)
    case configChanged(Config)
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
}

// MARK: - State machine

/// Pure, deterministic state machine. All time comes in through the `at now:` parameter.
public struct StateMachine: Equatable {
    public private(set) var phase: Phase = .off
    public private(set) var sessions: [Session] = []
    public private(set) var countdownDeadline: Date?
    public private(set) var keepAwakeUntil: Date?
    /// True while `disablesleep 1` is (supposed to be) in force.
    public private(set) var awakeHeld = false
    public private(set) var awakeSince: Date?
    public private(set) var latch: GuardReason?
    public private(set) var enabled: Bool
    public private(set) var environment = Environment()
    public private(set) var config: Config

    public init(enabled: Bool = true, config: Config = Config()) {
        self.enabled = enabled
        self.config = config
        self.phase = enabled ? .armed : .off
    }

    /// The reason acquiring is currently blocked, if any (latch or environment guard).
    public var blockedReason: GuardReason? { latch ?? environmentGuard }

    /// Sessions whose main agent or any subagent is working.
    public var workingSessions: [Session] { sessions.filter(\.isWorking) }

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

    private func isBlocking(_ session: Session) -> Bool {
        // Running subagents keep a session busy even after the main agent sent Stop (or is waiting on the user).
        if !session.subagents.isEmpty { return true }
        switch session.state {
        case .working: return true
        case .waiting: return config.notificationPolicy == .keepAwake && !session.waitExpired
        case .idle: return false
        }
    }

    private var anyBlockingSession: Bool { sessions.contains(where: isBlocking) }

    private func keepAwakeActive(_ now: Date) -> Bool {
        if let until = keepAwakeUntil { return now < until }
        return false
    }

    // MARK: handle

    public mutating func handle(_ event: Event, at now: Date) -> [Effect] {
        var fx: [Effect] = []

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
            if !value { keepAwakeUntil = nil; latch = nil }

        case .cancelCountdown:
            if phase == .countdown {
                countdownDeadline = nil
                fx.append(.dismissCountdown)
                // Back to armed; a still-blocking session would immediately flip us to working again,
                // so latch until everything is idle.
                if anyBlockingSession { latch = .manualSleep }
                // Force the release path even though "blocking" might be false.
                keepAwakeUntil = nil
                forceArmed(now: now, fx: &fx)
            }

        case .keepAwake:
            guard enabled else { break }
            keepAwakeUntil = now.addingTimeInterval(config.manualKeepAwake)
            latch = nil
            if countdownDeadline != nil {
                countdownDeadline = nil
                fx.append(.dismissCountdown)
            }

        case .sleepNow:
            keepAwakeUntil = nil
            if countdownDeadline != nil {
                countdownDeadline = nil
                fx.append(.dismissCountdown)
            }
            if awakeHeld { fx.append(.releaseAwake) }
            awakeHeld = false
            awakeSince = nil
            fx.append(.sleepNow)
            if anyBlockingSession { latch = .manualSleep }

        case .environment(let env):
            environment = env

        case .configChanged(let new):
            config = new
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

        case .sessionEnd:
            if let index {
                fx.append(.record(removeSession(at: index, reason: .ended, now: now)))
            }
            return

        case .postToolUse:
            // Heartbeat. It wakes a session that was waiting on the user (a permission prompt that was approved
            // fires no UserPromptSubmit), and it adopts a session we have not seen yet (Vigil started or
            // restarted mid-task) - but only with a PID, so a dead process can always be pruned.
            // It never revives an idle session: a late, out-of-order heartbeat must not pin the Mac awake.
            guard let index else {
                guard let pid = hook.pid else { return }
                sessions.append(Session(id: hook.sessionID, cwd: hook.cwd, pid: pid, state: .working,
                                        startedAt: now, lastEventAt: now, stateSince: now))
                return
            }
            sessions[index].lastEventAt = now
            if let pid = hook.pid { sessions[index].pid = pid }
            if sessions[index].state == .waiting { setState(.working, at: index, now: now) }
            return

        case .subagentStart:
            // Without an agent_id a later SubagentStop could never be matched, so it is not tracked.
            guard let agentID = hook.agentID, !agentID.isEmpty else { return }
            let i = sessionIndex(for: hook, existing: index, now: now)
            if !sessions[i].subagents.contains(where: { $0.id == agentID }) {
                sessions[i].subagents.append(Subagent(id: agentID, type: Self.agentType(hook.agentType), startedAt: now))
                sessions[i].maxSubagents = max(sessions[i].maxSubagents, sessions[i].subagents.count)
            }
            return

        case .subagentStop:
            // Unknown session or agent (Vigil started mid-session, or the agent was already dropped): ignore.
            guard let index, let agentID = hook.agentID,
                  let a = sessions[index].subagents.firstIndex(where: { $0.id == agentID }) else { return }
            let agent = sessions[index].subagents.remove(at: a)
            sessions[index].finishedSubagentTime += max(0, now.timeIntervalSince(agent.startedAt))
            sessions[index].lastEventAt = now
            if let pid = hook.pid { sessions[index].pid = pid }
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
        default: newState = nil // sessionStart: keeps current (idle for a new session)
        }
        if let newState, sessions[i].state != newState { setState(newState, at: i, now: now) }
        // A fresh prompt lifts a manual-sleep latch.
        if hook.kind == .userPromptSubmit, latch == .manualSleep { latch = nil }
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
            sessions.append(Session(id: hook.sessionID, cwd: hook.cwd, pid: hook.pid, state: .idle,
                                    startedAt: now, lastEventAt: now, stateSince: now))
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

        if let until = keepAwakeUntil, now >= until { keepAwakeUntil = nil }

        // Max keep-awake failsafe.
        if awakeHeld, let since = awakeSince, now.timeIntervalSince(since) >= config.maxKeepAwake {
            trip(.maxDuration, fx: &fx)
            return
        }

        // Countdown expiry: restore first, sleep second.
        if phase == .countdown, let deadline = countdownDeadline, now >= deadline {
            countdownDeadline = nil
            fx.append(.dismissCountdown)
            fx.append(.releaseAwake)
            awakeHeld = false
            awakeSince = nil
            if config.sleepOnlyIfLidClosed && !environment.lidClosed {
                // Lid is open: stay awake-capable but do not force sleep.
            } else {
                fx.append(.sleepNow)
            }
            forceArmed(now: now, fx: &fx)
        }
    }

    // MARK: guards / latch

    /// Release (and sleep, see below) immediately and refuse to re-acquire until the condition clears.
    private mutating func trip(_ reason: GuardReason, fx: inout [Effect]) {
        if countdownDeadline != nil {
            countdownDeadline = nil
            fx.append(.dismissCountdown)
        }
        keepAwakeUntil = nil
        fx.append(.notifyGuard(reason))
        if awakeHeld { fx.append(.releaseAwake) }
        awakeHeld = false
        awakeSince = nil
        // Battery and heat guards protect a closed laptop. With the lid open someone is at the Mac,
        // so hand sleep back to macOS instead of yanking the machine to sleep under them.
        let environmental = reason == .lowBattery || reason == .thermal
        if !environmental || environment.lidClosed { fx.append(.sleepNow) }
        if reason == .maxDuration || reason == .manualSleep { latch = reason }
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
            if countdownDeadline != nil { countdownDeadline = nil; fx.append(.dismissCountdown) }
            if awakeHeld { fx.append(.releaseAwake); awakeHeld = false; awakeSince = nil }
            phase = .off
            return
        }

        // Environment guard trips while we hold the Mac awake.
        if awakeHeld, let env = environmentGuard {
            trip(env, fx: &fx)
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
            }
            if countdownDeadline != nil {
                countdownDeadline = nil
                fx.append(.dismissCountdown)
            }
            phase = .working
        } else if awakeHeld {
            // Was working, nothing blocks any more (or blocked): start the countdown.
            if countdownDeadline == nil {
                let deadline = now.addingTimeInterval(config.graceSeconds)
                countdownDeadline = deadline
                fx.append(.showCountdown(deadline: deadline))
            }
            phase = .countdown
        } else {
            phase = .armed
        }
    }
}
