import Foundation

// The work-time estimate. Information only: nothing in here is ever read by the StateMachine, so it can never
// keep the Mac awake or put it to sleep. All functions are pure; time always comes in as a parameter.

public enum EtaConfidence: Int, Codable, Comparable, Sendable {
    case low, medium, high
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum HistoryScope: String, Codable, Equatable, Sendable {
    /// Past turns of the same project.
    case project
    /// Too few in the project: past turns of all projects.
    case all
}

public enum EtaBasis: Equatable, Sendable {
    /// Claude's task list: `done` of `total` items completed.
    case tasks(done: Int, total: Int)
    /// Conditional history: `count` comparable past turns.
    case history(count: Int, scope: HistoryScope)

    public var isTasks: Bool { if case .tasks = self { return true } else { return false } }
}

/// Remaining work time as a range. `low ≤ likely ≤ high`, all in seconds from now.
public struct Estimate: Equatable, Sendable {
    public var low: TimeInterval
    public var likely: TimeInterval
    public var high: TimeInterval
    public var confidence: EtaConfidence
    public var basis: EtaBasis

    public init(low: TimeInterval, likely: TimeInterval, high: TimeInterval, confidence: EtaConfidence, basis: EtaBasis) {
        self.low = max(0, min(low, likely))
        self.likely = max(0, likely)
        self.high = max(self.likely, high)
        self.confidence = confidence
        self.basis = basis
    }
}

/// Everything the model needs about the running turn, in *active* seconds (time spent waiting for the user
/// is excluded, it says nothing about how long the work takes).
public struct EtaInput: Equatable, Sendable {
    public var project: String
    public var elapsed: TimeInterval
    /// Task list size; 0 = no task list.
    public var tasksTotal: Int
    public var tasksDone: Int
    /// Durations of the tasks completed in this turn.
    public var doneDurations: [TimeInterval]
    /// How long the task in progress (or the next one) has been running.
    public var currentTaskElapsed: TimeInterval
    /// Running subagents: type and how long they have been running.
    public var runningAgents: [(type: String, elapsed: TimeInterval)]

    public init(project: String, elapsed: TimeInterval, tasksTotal: Int = 0, tasksDone: Int = 0,
                doneDurations: [TimeInterval] = [], currentTaskElapsed: TimeInterval = 0,
                runningAgents: [(type: String, elapsed: TimeInterval)] = []) {
        self.project = project
        self.elapsed = elapsed
        self.tasksTotal = tasksTotal
        self.tasksDone = tasksDone
        self.doneDurations = doneDurations
        self.currentTaskElapsed = currentTaskElapsed
        self.runningAgents = runningAgents
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.project == b.project && a.elapsed == b.elapsed && a.tasksTotal == b.tasksTotal && a.tasksDone == b.tasksDone
            && a.doneDurations == b.doneDurations && a.currentTaskElapsed == b.currentTaskElapsed
            && a.runningAgents.map(\.type) == b.runningAgents.map(\.type)
            && a.runningAgents.map(\.elapsed) == b.runningAgents.map(\.elapsed)
    }
}

public enum EtaModel {
    /// Fewer comparable past turns than this and no task list: no estimate.
    public static let minimumHistory = 5
    /// Historical per-task samples needed before they count.
    public static let minimumTaskSamples = 3
    /// Relative half-width of a task-mode range per confidence (low confidence = wider).
    public static func spread(_ c: EtaConfidence) -> Double {
        switch c {
        case .high: return 0.15
        case .medium: return 0.30
        case .low: return 0.55
        }
    }

    // MARK: statistics

    /// Linear-interpolated percentile, `p` in 0...1. `nil` for an empty list.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let pos = min(1, max(0, p)) * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    public static func median(_ values: [Double]) -> Double? { percentile(values, 0.5) }

    /// Interquartile range relative to the median (0 = perfectly steady).
    public static func dispersion(_ values: [Double]) -> Double {
        guard values.count >= 2, let m = median(values), m > 0,
              let q1 = percentile(values, 0.25), let q3 = percentile(values, 0.75) else { return 0 }
        return (q3 - q1) / m
    }

    // MARK: task mode

    /// Blends this run's observed average with the project's historical median per task. The observed weight
    /// is k / (k + 2): nothing after 0 tasks, 1/3 after 1, 1/2 after 2, 3/4 after 6.
    public static func perTaskTime(observed: [TimeInterval], historicalMedian: TimeInterval?) -> TimeInterval? {
        let k = Double(observed.count)
        let mean = observed.isEmpty ? nil : observed.reduce(0, +) / k
        switch (mean, historicalMedian) {
        case let (m?, h?):
            let w = k / (k + 2)
            return w * m + (1 - w) * h
        case let (m?, nil): return m
        case let (nil, h?): return h
        case (nil, nil): return nil
        }
    }

    public static func taskEstimate(_ input: EtaInput, historicalTaskDurations: [TimeInterval]) -> Estimate? {
        let n = input.tasksTotal, k = min(input.tasksDone, input.tasksTotal)
        guard n > 0 else { return nil }
        let history = historicalTaskDurations.count >= minimumTaskSamples ? historicalTaskDurations : []
        // Neither observed nor historical: the task in progress is the only hint (low confidence, wide range).
        let perTask = perTaskTime(observed: input.doneDurations, historicalMedian: median(history))
            ?? max(2 * input.currentTaskElapsed, 60)
        let observedSpread = dispersion(input.doneDurations)
        let confidence: EtaConfidence
        if k >= 3 && observedSpread < 0.5 { confidence = .high }
        else if k >= 1 || history.count >= minimumHistory { confidence = .medium }
        else { confidence = .low }
        let basis = EtaBasis.tasks(done: k, total: n)

        if k >= n {
            // Every item is done but Claude still works (wrapping up): a short, low-confidence tail.
            return Estimate(low: 0, likely: 0.25 * perTask, high: 0.5 * perTask, confidence: .low, basis: basis)
        }
        // The elapsed time of the task in progress counts; a slow task never makes its own remainder negative.
        let current = max(perTask - input.currentTaskElapsed, 0.1 * perTask)
        let likely = current + Double(n - k - 1) * perTask
        // The range grows with the uncertainty tier and with how uneven the tasks have been.
        let s = min(0.8, max(spread(confidence), observedSpread / 2, dispersion(history) / 2))
        return Estimate(low: likely * (1 - s), likely: likely, high: likely * (1 + s), confidence: confidence, basis: basis)
    }

    // MARK: history mode

    /// Past turns that already lasted longer than the current one: how much longer did they go on?
    /// 25th–75th percentile of that. Project first, all projects when the project has fewer than 5.
    public static func historyEstimate(_ input: EtaInput, history: [TurnRecord]) -> Estimate? {
        func remaining(_ turns: [TurnRecord]) -> [Double] {
            turns.filter { $0.activeDuration > input.elapsed }.map { $0.activeDuration - input.elapsed }
        }
        var scope = HistoryScope.project
        var samples = remaining(history.filter { $0.project == input.project })
        if samples.count < minimumHistory {
            scope = .all
            samples = remaining(history)
        }
        guard samples.count >= minimumHistory, let low = percentile(samples, 0.25), let likely = median(samples),
              let high = percentile(samples, 0.75) else { return nil }
        // History alone never earns "high": it knows nothing about this particular task.
        let confidence: EtaConfidence = samples.count >= 20 && (high - low) <= likely ? .medium : .low
        return Estimate(low: low, likely: likely, high: high, confidence: confidence,
                        basis: .history(count: samples.count, scope: scope))
    }

    // MARK: subagents

    /// The longest typical remaining time among the running subagents, from past runs of the same agent_type
    /// that lasted longer than this one has so far.
    public static func subagentFloor(_ running: [(type: String, elapsed: TimeInterval)], history: [TurnRecord]) -> TimeInterval? {
        var floor: TimeInterval?
        for agent in running {
            let samples = history.flatMap(\.subagents).filter { $0.type == agent.type && $0.duration > agent.elapsed }
                .map { $0.duration - agent.elapsed }
            guard samples.count >= minimumTaskSamples, let m = median(samples) else { continue }
            floor = max(floor ?? 0, m)
        }
        return floor
    }

    // MARK: combined

    /// Task list first, conditional history otherwise; running subagents set a lower bound.
    /// No task list and fewer than 5 comparable past turns: nil (no estimate is better than a made-up one).
    public static func estimate(_ input: EtaInput, history: [TurnRecord]) -> Estimate? {
        let projectTasks = history.filter { $0.project == input.project }.flatMap(\.taskDurations)
        let taskHistory = projectTasks.count >= minimumTaskSamples ? projectTasks : history.flatMap(\.taskDurations)
        guard var e = taskEstimate(input, historicalTaskDurations: taskHistory) ?? historyEstimate(input, history: history)
        else { return nil }
        if let floor = subagentFloor(input.runningAgents, history: history), floor > e.likely {
            e = Estimate(low: max(e.low, floor), likely: floor, high: max(e.high, floor * (e.high / max(e.likely, 1))),
                         confidence: e.confidence, basis: e.basis)
        }
        return e
    }
}

/// Exponential smoothing of the *finish instant* (not of "remaining", which would lag behind the clock).
/// alpha = 1 − e^(−dt/τ), so the smoothing is the same whether updates come every second or every ten.
public struct EtaSmoother: Equatable, Sendable {
    public var tau: TimeInterval
    private var ends: (low: Date, likely: Date, high: Date)?
    private var last: Date?

    public init(tau: TimeInterval = 30) { self.tau = tau }

    public static func == (a: Self, b: Self) -> Bool {
        a.tau == b.tau && a.last == b.last && a.ends?.low == b.ends?.low && a.ends?.likely == b.ends?.likely
            && a.ends?.high == b.ends?.high
    }

    public mutating func reset() { ends = nil; last = nil }

    public mutating func update(_ e: Estimate, at now: Date) -> Estimate {
        let target = (low: now + e.low, likely: now + e.likely, high: now + e.high)
        guard let current = ends, let last else {
            ends = target
            self.last = now
            return e
        }
        let dt = max(0, now.timeIntervalSince(last))
        let alpha = 1 - exp(-dt / tau)
        func blend(_ a: Date, _ b: Date) -> Date { a + alpha * b.timeIntervalSince(a) }
        let next = (low: blend(current.low, target.low), likely: blend(current.likely, target.likely),
                    high: blend(current.high, target.high))
        ends = next
        self.last = now
        return Estimate(low: next.low.timeIntervalSince(now), likely: next.likely.timeIntervalSince(now),
                        high: next.high.timeIntervalSince(now), confidence: e.confidence, basis: e.basis)
    }
}

/// Display rounding. Under 10 min to 1 min, under 1 h to 5 min, above to 15 min; never 0 while working
/// (under a minute is "soon").
public enum EtaFormat {
    /// Rounded seconds, or nil for "soon".
    public static func rounded(_ seconds: TimeInterval) -> TimeInterval? {
        guard seconds >= 60 else { return nil }
        let step: TimeInterval = seconds < 600 ? 60 : seconds < 3600 ? 300 : 900
        return max(step, (seconds / step).rounded() * step)
    }

    /// "12 min", "1:15 h", or "soon".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard let r = rounded(seconds) else { return L("soon") }
        return clock(r)
    }

    private static func clock(_ r: TimeInterval) -> String {
        let m = Int(r / 60)
        return m < 60 ? "\(m) min" : String(format: "%d:%02d h", m / 60, m % 60)
    }

    /// "5–15 min", "1:45–2:00 h", "50 min–1:15 h", "up to 4 min"; collapses to "~12 min" when both ends round the same.
    public static func range(_ low: TimeInterval, _ high: TimeInterval) -> String {
        let lo = rounded(low), hi = rounded(high)
        if lo == hi { return approx(high) }
        guard let hi else { return L("soon") }
        // The lower end rounds below a minute: "up to 15 min" (Czech "do 15 min"), never "soon–15 min".
        guard let lo else { return L("up to %@", clock(hi)) }
        let lm = Int(lo / 60), hm = Int(hi / 60)
        if lm < 60 && hm < 60 { return "\(lm)–\(hm) min" }
        if lm >= 60 { return String(format: "%d:%02d–%d:%02d h", lm / 60, lm % 60, hm / 60, hm % 60) }
        return "\(lm) min–\(clock(hi))"
    }

    /// "~12 min", or "soon".
    public static func approx(_ seconds: TimeInterval) -> String {
        rounded(seconds) == nil ? L("soon") : "~" + duration(seconds)
    }

    /// The main text: "~likely" when the estimate is confident, the whole range when it is not.
    public static func remaining(_ e: Estimate) -> String {
        e.confidence >= .medium ? approx(e.likely) : range(e.low, e.high)
    }

    /// "±5 min": half the range, at least one minute.
    public static func plusMinus(_ e: Estimate) -> String {
        "±" + clock(max(60, rounded((e.high - e.low) / 2) ?? 60))
    }
}
