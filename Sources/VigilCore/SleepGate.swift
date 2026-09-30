import Foundation

/// A power assertion held by some process (from IOPMCopyAssertionsByProcess).
public struct PowerAssertion: Codable, Equatable, Sendable {
    public var pid: Int32
    public var process: String
    /// "PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", ...
    public var type: String
    public var name: String
    /// Name of the parent process (only looked up for caffeinate, to recognise the one Claude Code spawns).
    public var parentProcess: String?

    public init(pid: Int32, process: String, type: String, name: String, parentProcess: String? = nil) {
        self.pid = pid
        self.process = process
        self.type = type
        self.name = name
        self.parentProcess = parentProcess
    }
}

/// Everything the gate needs to know about whether someone is at the Mac, read fresh at the moment of a decision.
public struct PresenceSnapshot: Codable, Equatable, Sendable {
    public var lidClosed: Bool
    /// Active displays that are not the built-in panel.
    public var externalDisplays: Int
    /// Seconds since the last keyboard, mouse or trackpad input.
    public var idleSeconds: TimeInterval
    /// All idle-sleep assertions; the gate filters out its own, powerd's and Claude Code's caffeinate.
    public var assertions: [PowerAssertion]
    /// Vigil's own pid, whose assertions never count.
    public var ownPID: Int32

    public init(lidClosed: Bool, externalDisplays: Int, idleSeconds: TimeInterval, assertions: [PowerAssertion] = [],
                ownPID: Int32 = 0) {
        self.lidClosed = lidClosed
        self.externalDisplays = externalDisplays
        self.idleSeconds = idleSeconds
        self.assertions = assertions
        self.ownPID = ownPID
    }

    /// Lid closed, no external display: nobody can be using the Mac.
    public static let away = PresenceSnapshot(lidClosed: true, externalDisplays: 0, idleSeconds: 3600)

    public var clamshellAway: Bool { lidClosed && externalDisplays == 0 }
}

/// Why the gate allowed or refused a forced sleep. Logged and kept in the history.
public enum GateReason: Codable, Equatable, Sendable {
    case lidClosedNoDisplay
    case idle(seconds: Int, threshold: Int)
    /// "Uspat hned": the only bypass.
    case userRequested
    /// Lid open and "sleep with the lid open after inactivity" is Never.
    case lidOpen(idleSeconds: Int)
    /// Lid closed but an external display is active (desktop mode) and the setting is Never.
    case externalDisplay(idleSeconds: Int)
    /// The setting is on, but there was input more recently than the threshold.
    case recentInput(seconds: Int, threshold: Int)
    /// Another app wants the Mac awake (video, a call, a presentation).
    case assertion(process: String)
    /// Keyboard, mouse or trackpad input during the countdown.
    case inputDuringCountdown(seconds: Int)
    /// No presence reading yet: never force sleep blind.
    case unknown

    /// For the log: "lid closed, no external display", "user active 12 s ago", "assertion held by Zoom".
    public var logText: String {
        switch self {
        case .lidClosedNoDisplay: return "lid closed, no external display"
        case .idle(let s, let t): return "no input for \(s) s (threshold \(t) s)"
        case .userRequested: return "user pressed Sleep now"
        case .lidOpen(let s): return "lid open, user active \(s) s ago (sleep with lid open: never)"
        case .externalDisplay(let s): return "external display connected, user active \(s) s ago"
        case .recentInput(let s, let t): return "user active \(s) s ago (threshold \(t) s)"
        case .assertion(let p): return "assertion held by \(p)"
        case .inputDuringCountdown(let s): return "input \(s) s ago during the countdown"
        case .unknown: return "no presence reading yet"
        }
    }
}

public struct GateDecision: Codable, Equatable, Sendable {
    public var allow: Bool
    public var reason: GateReason

    public init(allow: Bool, reason: GateReason) {
        self.allow = allow
        self.reason = reason
    }
}

/// The single gate every automatic sleep goes through. Pure: all inputs come in the snapshot.
///
/// - Lid closed and no external display: allowed (nobody can be using the Mac). Assertions don't matter then.
/// - Otherwise not allowed, unless "sleep with the lid open after inactivity" is set and there has been no input
///   for that long, and no other app holds an idle-sleep assertion.
/// When the gate refuses, Vigil only releases its own keep-awake and macOS sleeps by the Energy settings.
public enum SleepGate {
    /// Assertion types that mean "someone is watching or presenting".
    public static let blockingTypes: Set<String> = ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep",
                                                    "NoDisplaySleepAssertion", "NoIdleSleepAssertion"]
    /// Parent processes whose caffeinate is Claude Code's own (it keeps the Mac awake while it works).
    public static let claudeProcesses: Set<String> = ["claude", "claude-code"]

    /// Whether an executable is Claude Code. Its native binary lives at `…/claude/versions/2.1.284`, so the kernel's
    /// process name is the version number, not "claude"; the path is what identifies it.
    public static func isClaudeCode(executablePath path: String?, processName: String?) -> Bool {
        if let name = processName, claudeProcesses.contains(name) { return true }
        guard let path else { return false }
        let base = (path as NSString).lastPathComponent
        return claudeProcesses.contains(base) || path.contains("/claude/versions/") || path.contains("/@anthropic-ai/claude-code/")
    }

    /// Assertions that count: another app's, of a blocking type. Never Vigil's own, never powerd's
    /// ("Prevent sleep while display is on" is always there), never the caffeinate Claude Code spawns.
    public static func foreignAssertions(_ s: PresenceSnapshot) -> [PowerAssertion] {
        s.assertions.filter { a in
            guard blockingTypes.contains(a.type), a.pid != s.ownPID, a.process != "powerd" else { return false }
            if a.process == "caffeinate", let parent = a.parentProcess, claudeProcesses.contains(parent) { return false }
            return true
        }
    }

    /// - Parameter lidOpenIdleThreshold: seconds of no input after which sleeping with the lid open is allowed;
    ///   0 = never (the default).
    public static func decide(_ s: PresenceSnapshot?, lidOpenIdleThreshold: TimeInterval) -> GateDecision {
        guard let s else { return GateDecision(allow: false, reason: .unknown) }
        if s.clamshellAway { return GateDecision(allow: true, reason: .lidClosedNoDisplay) }
        let idle = Int(s.idleSeconds)
        if let blocker = foreignAssertions(s).first { return GateDecision(allow: false, reason: .assertion(process: blocker.process)) }
        guard lidOpenIdleThreshold > 0 else {
            return GateDecision(allow: false, reason: s.lidClosed ? .externalDisplay(idleSeconds: idle) : .lidOpen(idleSeconds: idle))
        }
        let threshold = Int(lidOpenIdleThreshold)
        if s.idleSeconds >= lidOpenIdleThreshold { return GateDecision(allow: true, reason: .idle(seconds: idle, threshold: threshold)) }
        return GateDecision(allow: false, reason: .recentInput(seconds: idle, threshold: threshold))
    }
}

/// What set a sleep decision in motion.
public enum SleepTrigger: String, Codable, Equatable, Sendable {
    /// Claude finished (all sessions idle): would the countdown start?
    case finished
    case countdownExpired
    case countdownCancelled
    case maxDuration
    case lowBattery
    case thermal
    case userRequested
}

/// One sleep or skip, for the log and the history.
public struct SleepDecisionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(date.timeIntervalSince1970)-\(trigger.rawValue)" }
    public var date: Date
    public var trigger: SleepTrigger
    /// true = Vigil put the Mac to sleep (or started the countdown for it); false = it handed sleep back to macOS.
    public var slept: Bool
    public var reason: GateReason

    public init(date: Date, trigger: SleepTrigger, slept: Bool, reason: GateReason) {
        self.date = date
        self.trigger = trigger
        self.slept = slept
        self.reason = reason
    }

    public var logLine: String {
        "\(slept ? "sleep" : "skip"): \(reason.logText) [\(trigger.rawValue)]"
    }
}

/// User-facing (localized) texts for gate reasons.
public enum SleepGateText {
    public static func reason(_ r: GateReason) -> String {
        switch r {
        case .lidClosedNoDisplay: return L("lid closed, no external display")
        case .idle(let s, _): return L("no input for %@", Durations.short(TimeInterval(s)))
        case .userRequested: return L("you pressed Sleep now")
        case .lidOpen(let s): return L("lid open, last input %@ ago", Durations.short(TimeInterval(s)))
        case .externalDisplay: return L("external display connected")
        case .recentInput(let s, _): return L("lid open, last input %@ ago", Durations.short(TimeInterval(s)))
        case .assertion(let p): return L("%@ is keeping the Mac awake", p)
        case .inputDuringCountdown: return L("you used the Mac during the countdown")
        case .unknown: return L("no reading yet")
        }
    }
}
