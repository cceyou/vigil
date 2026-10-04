import Foundation

/// The two sounds Vigil can play.
public enum ChimeCue: String, Equatable, Sendable {
    /// A session went from working to idle: the main agent stopped and no subagent is running.
    case done
    /// Claude started waiting for an answer (permission prompt, question, agent needing input).
    case waiting
}

/// "Zvuk" settings. Sounds are system sound names from /System/Library/Sounds.
public struct SoundSettings: Codable, Equatable, Sendable {
    public var doneEnabled = true
    public var doneSound = "Glass"
    /// Turns shorter than this stay silent (0 = always play).
    public var minTurnDuration: TimeInterval = 30
    public var waitingEnabled = true
    public var waitingSound = "Tink"
    /// 0...1, on top of the system alert volume.
    public var volume = 0.8

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SoundSettings()
        doneEnabled = try c.decodeIfPresent(Bool.self, forKey: .doneEnabled) ?? d.doneEnabled
        doneSound = try c.decodeIfPresent(String.self, forKey: .doneSound) ?? d.doneSound
        minTurnDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .minTurnDuration) ?? d.minTurnDuration
        waitingEnabled = try c.decodeIfPresent(Bool.self, forKey: .waitingEnabled) ?? d.waitingEnabled
        waitingSound = try c.decodeIfPresent(String.self, forKey: .waitingSound) ?? d.waitingSound
        volume = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume))
    }

    public func sound(for cue: ChimeCue) -> String { cue == .done ? doneSound : waitingSound }
}

/// Plays a named system sound. The app uses NSSound; tests inject a fake.
public protocol SoundPlaying: AnyObject {
    /// `volume` is Vigil's own 0...1 level; the player scales it by the system alert volume.
    func play(_ sound: String, volume: Double)
}

public enum SystemSounds {
    public static let directory = URL(fileURLWithPath: "/System/Library/Sounds")

    /// Names of the built-in alert sounds ("Basso", "Glass", ..., "Tink").
    public static func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }

    public static func url(_ name: String) -> URL { directory.appendingPathComponent("\(name).aiff") }

    /// The macOS alert volume (System Settings > Sound > Alert volume), 0...1. Missing key = full volume.
    public static func alertVolume() -> Double {
        let value = CFPreferencesCopyValue("com.apple.sound.beep.volume" as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let number = value as? NSNumber else { return 1 }
        return min(1, max(0, number.doubleValue))
    }
}

/// Decides when to play a sound, from the state machine's sessions before and after each event.
///
/// Kept beside the state machine rather than inside it: sound never affects sleep, so it adds no effects there.
/// - done: a session was busy (main agent working or waiting, or a subagent running) and a Stop or the last
///   SubagentStop left it idle with no subagents. Never on a removed session (Ctrl+C, killed, SessionEnd),
///   never on idle_prompt, never for a turn shorter than `minTurnDuration`.
/// - waiting: a session entered `.waiting` through a waiting-type Notification or PermissionRequest.
/// - Each cue plays at most once per `coalesceWindow`, so several sessions finishing together beep once.
public final class ChimeMachine {
    public static let coalesceWindow: TimeInterval = 3

    public var settings: SoundSettings
    private let player: SoundPlaying
    /// When each busy session's current turn started.
    private var turnStart: [String: Date] = [:]
    private var lastPlayed: [ChimeCue: Date] = [:]

    public init(settings: SoundSettings = SoundSettings(), player: SoundPlaying) {
        self.settings = settings
        self.player = player
    }

    private static func isBusy(_ s: Session) -> Bool { s.isWorking || s.state == .waiting }

    /// Call with the sessions before and after `StateMachine.handle(event)`. Returns the cues it played.
    @discardableResult
    public func observe(_ event: Event, before: [Session], after: [Session], at now: Date) -> [ChimeCue] {
        var cues: [ChimeCue] = []
        let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        if case .hook(let hook) = event, let new = after.first(where: { $0.id == hook.sessionID }) {
            let old = previous[hook.sessionID]
            switch hook.kind {
            case .stop, .subagentStop:
                if let old, Self.isBusy(old), !Self.isBusy(new), settings.doneEnabled {
                    let started = turnStart[hook.sessionID] ?? old.workingSince ?? old.stateSince
                    if now.timeIntervalSince(started) >= settings.minTurnDuration { cues.append(.done) }
                }
            case .notification, .permissionRequest:
                // Also for a session Vigil first sees on its prompt. Notification + PermissionRequest for the
                // same prompt: only the first one changes the state, so it plays once.
                if old?.state != .waiting, new.state == .waiting, settings.waitingEnabled { cues.append(.waiting) }
            default:
                break
            }
        }

        // Track turn starts: a session's turn begins when it becomes busy and ends when it is idle or gone.
        let busyNow = Set(after.filter(Self.isBusy).map(\.id))
        for id in busyNow where turnStart[id] == nil { turnStart[id] = now }
        for id in turnStart.keys where !busyNow.contains(id) { turnStart[id] = nil }

        return cues.filter { play($0, at: now) }
    }

    /// Plays `cue` unless the same cue already played within the coalescing window.
    private func play(_ cue: ChimeCue, at now: Date) -> Bool {
        if let last = lastPlayed[cue], now.timeIntervalSince(last) < Self.coalesceWindow { return false }
        lastPlayed[cue] = now
        player.play(settings.sound(for: cue), volume: settings.volume)
        return true
    }

    /// The ▶ buttons and the self-test: plays right away, ignoring the switches and the coalescing window.
    public func preview(_ sound: String) {
        player.play(sound, volume: settings.volume)
    }
}
