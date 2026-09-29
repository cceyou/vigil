import Foundation

public enum UsageWindowKind: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    /// The rolling 5-hour session window.
    case fiveHour
    /// The weekly window.
    case sevenDay

    public var length: TimeInterval { self == .fiveHour ? 5 * 3600 : 7 * 24 * 3600 }

    /// Percent levels that trigger a notification when crossed.
    public var alertThresholds: [Int] { self == .fiveHour ? [80, 95] : [80] }
}

public enum UsageAlert: Equatable, Sendable {
    case threshold(UsageWindowKind, percent: Int)
    /// A window with usage in it has passed its reset time.
    case reset(UsageWindowKind)
}

/// A window as it should be shown right now: once `resetsAt` has passed, the old number is meaningless.
public struct EffectiveWindow: Equatable, Sendable {
    public var usedPercentage: Double
    public var resetsAt: Date
    public var isReset: Bool
}

/// Last status line seen for one Claude Code session.
public struct UsageSessionInfo: Codable, Equatable, Sendable {
    public var cwd: String?
    public var model: String?
    public var contextPercent: Double?
    public var updatedAt: Date

    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

/// Persisted usage picture built from status line updates. Pure: all time comes in as parameters.
public struct UsageState: Codable, Equatable, Sendable {
    public struct Track: Codable, Equatable, Sendable {
        public var window: UsageWindow
        /// Highest threshold already announced in this window cycle (0 = none).
        public var alertedLevel: Int = 0
        /// The reset of this cycle has been handled (announced, or there was nothing to announce).
        public var resetHandled = false
    }

    public var tracks: [UsageWindowKind: Track] = [:]
    /// Last status line that carried rate_limits.
    public var updatedAt: Date?
    /// Last status line of any kind (tells "status line works, but no rate_limits" apart from "nothing arrives").
    public var lastStatusLineAt: Date?
    public var sessions: [String: UsageSessionInfo] = [:]

    /// Session info older than this is forgotten.
    static let sessionRetention: TimeInterval = 24 * 3600

    public init() {}

    public var hasRateLimits: Bool { !tracks.isEmpty }

    public func window(_ kind: UsageWindowKind) -> UsageWindow? { tracks[kind]?.window }

    public func effective(_ kind: UsageWindowKind, at now: Date) -> EffectiveWindow? {
        guard let w = tracks[kind]?.window else { return nil }
        if now >= w.resetsAt { return EffectiveWindow(usedPercentage: 0, resetsAt: w.resetsAt, isReset: true) }
        return EffectiveWindow(usedPercentage: w.usedPercentage, resetsAt: w.resetsAt, isReset: false)
    }

    /// Takes one status line update and returns the notifications it causes.
    public mutating func apply(_ snapshot: StatusLineSnapshot, at now: Date) -> [UsageAlert] {
        lastStatusLineAt = now
        var info = sessions[snapshot.sessionID] ?? UsageSessionInfo(updatedAt: now)
        if let cwd = snapshot.cwd, !cwd.isEmpty { info.cwd = cwd }
        if let model = snapshot.model { info.model = model }
        if let ctx = snapshot.contextPercent { info.contextPercent = ctx }
        info.updatedAt = now
        sessions[snapshot.sessionID] = info
        sessions = sessions.filter { now.timeIntervalSince($0.value.updatedAt) < Self.sessionRetention }

        var alerts: [UsageAlert] = []
        for kind in UsageWindowKind.allCases {
            guard let new = kind == .fiveHour ? snapshot.fiveHour : snapshot.sevenDay else { continue }
            updatedAt = now
            var track: Track
            if let old = tracks[kind], new.resetsAt.timeIntervalSince(old.window.resetsAt) < 60 {
                // Same cycle (resets_at jitters by a few seconds between updates).
                track = old
                track.window = new
            } else {
                // A new cycle. If the tick has not announced the old cycle's reset yet, do it now.
                if let old = tracks[kind], !old.resetHandled, old.window.usedPercentage > 0, now >= old.window.resetsAt {
                    alerts.append(.reset(kind))
                }
                track = Track(window: new)
            }
            if let level = kind.alertThresholds.last(where: { Double($0) <= new.usedPercentage }), level > track.alertedLevel {
                alerts.append(.threshold(kind, percent: level))
                track.alertedLevel = level
            }
            tracks[kind] = track
        }
        return alerts
    }

    /// Call periodically: announces windows whose reset time has passed.
    public mutating func rollover(at now: Date) -> [UsageAlert] {
        var alerts: [UsageAlert] = []
        for kind in UsageWindowKind.allCases {
            guard var track = tracks[kind], !track.resetHandled, now >= track.window.resetsAt else { continue }
            track.resetHandled = true
            if track.window.usedPercentage > 0 { alerts.append(.reset(kind)) }
            tracks[kind] = track
        }
        return alerts
    }

    /// Sessions with a status line in the last `within` seconds, newest first.
    public func recentSessions(at now: Date, within: TimeInterval) -> [(id: String, info: UsageSessionInfo)] {
        sessions.filter { now.timeIntervalSince($0.value.updatedAt) <= within }
            .map { (id: $0.key, info: $0.value) }
            .sorted { $0.info.updatedAt > $1.info.updatedAt }
    }
}

/// Is the weekly budget being used faster than time passes?
public enum UsagePace: Equatable, Sendable {
    case onTrack
    /// At the current average rate the window runs out at this time (before it resets).
    case exhausts(at: Date)

    /// Linear projection from the start of the window. Too early in the window (under ~2 %) there is no
    /// meaningful rate, so that counts as on track.
    public static func evaluate(usedPercentage used: Double, resetsAt: Date, length: TimeInterval, now: Date) -> UsagePace {
        let start = resetsAt.addingTimeInterval(-length)
        let elapsed = now.timeIntervalSince(start)
        guard now < resetsAt, used > 0, elapsed > length * 0.02 else { return .onTrack }
        // Using no more than the elapsed share of the window is on track by definition.
        guard used / 100 > elapsed / length else { return .onTrack }
        let exhaust = start.addingTimeInterval(elapsed * 100 / used)
        return exhaust < resetsAt ? .exhausts(at: max(now, exhaust)) : .onTrack
    }
}

/// usage.json in Application Support.
public final class UsageStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func load() -> UsageState {
        lock.withLock {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: url), let state = try? d.decode(UsageState.self, from: data) else { return UsageState() }
            return state
        }
    }

    public func save(_ state: UsageState) {
        lock.withLock {
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? e.encode(state) { try? data.write(to: url, options: .atomic) }
        }
    }
}
