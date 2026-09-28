import Foundation

// MARK: - Model

public enum SessionState: String, Codable, Equatable, Sendable {
    case idle
    case working
    /// Claude sent a Notification ("waiting for me").
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

public struct Session: Equatable, Identifiable, Sendable {
    public var id: String
    public var cwd: String?
    public var pid: Int32?
    public var state: SessionState
    public var startedAt: Date
    public var lastEventAt: Date
    public var stateSince: Date

    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var project: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var reason: SessionEndReason

    public init(id: String, project: String, startedAt: Date, duration: TimeInterval, reason: SessionEndReason) {
        self.id = id
        self.project = project
        self.startedAt = startedAt
        self.duration = duration
        self.reason = reason
    }
}

public enum Phase: String, Equatable, Sendable {
    case off
    case armed
    case working
    case countdown
}

public enum NotificationPolicy: String, Codable, CaseIterable, Sendable {
    /// "Claude is waiting for me" counts as idle and starts the sleep countdown.
    case treatAsIdle
    /// "Claude is waiting for me" keeps the Mac awake.
    case keepAwake
}

public enum ThermalLevel: Int, Codable, Equatable, Sendable {
    case nominal, fair, serious, critical
}

public struct Environment: Equatable, Sendable {
    public var lidClosed: Bool
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var thermal: ThermalLevel

    public init(lidClosed: Bool = false, onBattery: Bool = false, batteryPercent: Int? = nil, thermal: ThermalLevel = .nominal) {
        self.lidClosed = lidClosed
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }
}

public struct Config: Equatable, Codable, Sendable {
    public var graceSeconds: TimeInterval = 30
    public var maxKeepAwake: TimeInterval = 8 * 3600
    public var lowBatteryThreshold: Int = 15
    public var sleepOnlyIfLidClosed: Bool = false
    public var notificationPolicy: NotificationPolicy = .treatAsIdle
    public var manualKeepAwake: TimeInterval = 3600

    public init() {}
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
    /// Heartbeat: a tool call finished, so Claude is working.
    case postToolUse = "PostToolUse"
    /// Used by the self-test round trip; never reaches the state machine.
    case selfTest = "VigilSelfTest"
}

public struct HookEvent: Equatable, Sendable {
    public var kind: HookKind
    public var sessionID: String
    public var cwd: String?
    public var pid: Int32?

    public init(kind: HookKind, sessionID: String, cwd: String? = nil, pid: Int32? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.pid = pid
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

    public var workingSessions: [Session] { sessions.filter { $0.state == .working } }

    private var environmentGuard: GuardReason? {
        if environment.onBattery, let pct = environment.batteryPercent, pct < config.lowBatteryThreshold {
            return .lowBattery
        }
        if environment.lidClosed, environment.thermal.rawValue >= ThermalLevel.serious.rawValue {
            return .thermal
        }
        return nil
    }

    private func isBlocking(_ session: Session) -> Bool {
        switch session.state {
        case .working: return true
        case .waiting: return config.notificationPolicy == .keepAwake
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
            if sessions[index].state == .waiting {
                sessions[index].state = .working
                sessions[index].stateSince = now
            }
            return

        case .sessionStart, .userPromptSubmit, .stop, .notification:
            break
        }

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

        let newState: SessionState?
        switch hook.kind {
        case .userPromptSubmit: newState = .working
        case .stop: newState = .idle
        case .notification: newState = .waiting
        default: newState = nil // sessionStart: keeps current (idle for a new session)
        }
        if let newState, sessions[i].state != newState {
            sessions[i].state = newState
            sessions[i].stateSince = now
        }
        // A fresh prompt lifts a manual-sleep latch.
        if hook.kind == .userPromptSubmit, latch == .manualSleep { latch = nil }
    }

    @discardableResult
    private mutating func removeSession(at index: Int, reason: SessionEndReason, now: Date) -> SessionRecord {
        let s = sessions.remove(at: index)
        return SessionRecord(id: s.id, project: s.projectName, startedAt: s.startedAt,
                             duration: max(0, now.timeIntervalSince(s.startedAt)), reason: reason)
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

    /// Release + sleep immediately and refuse to re-acquire until the condition clears.
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
        fx.append(.sleepNow)
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
