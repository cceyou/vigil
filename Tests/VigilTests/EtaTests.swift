import Foundation
import Testing
@testable import VigilCore

private func turn(_ project: String, active: TimeInterval, tasks: [TimeInterval] = [], agents: [SubagentRun] = [],
                  startedAt: Date = t0, checkpoint: (low: TimeInterval, likely: TimeInterval, high: TimeInterval)? = nil,
                  tasksTotal: Int? = nil) -> TurnRecord {
    TurnRecord(id: UUID().uuidString, project: project, startedAt: startedAt, duration: active, activeDuration: active,
               taskCount: tasks.count, taskDurations: tasks, subagents: agents,
               checkpoints: checkpoint.map { [EtaCheckpoint(fraction: 0.25, low: $0.low, likely: $0.likely, high: $0.high,
                                                            confidence: .medium, tasksTotal: tasksTotal)] } ?? [])
}

private func created(_ id: String, _ subject: String) -> [TaskSignal] { [.created(id: id, subject: subject)] }

private func task(_ kind: HookKind, _ signals: [TaskSignal], session: String = "a") -> Event {
    .hook(HookEvent(kind: kind, sessionID: session, cwd: "/Users/me/proj", taskSignals: signals))
}

private func hookEvent(_ e: Event) -> HookEvent {
    if case .hook(let h) = e { return h }
    fatalError("not a hook")
}

// MARK: - Model

@Suite struct EtaModelTests {
    @Test func steadyPace() throws {
        // 7 tasks, 3 done at 5 min each, the 4th has run 2 min: 3 min + 3 × 5 min = 18 min.
        let input = EtaInput(project: "p", elapsed: 1020, tasksTotal: 7, tasksDone: 3, doneDurations: [300, 300, 300],
                             currentTaskElapsed: 120)
        let e = try #require(EtaModel.taskEstimate(input, historicalTaskDurations: []))
        #expect(e.likely == 180 + 3 * 300)
        #expect(e.confidence == .high)
        #expect(e.basis == .tasks(done: 3, total: 7))
        #expect(e.low < e.likely && e.likely < e.high)
        #expect(abs(e.high - e.likely - 0.15 * e.likely) < 0.001) // high confidence: ±15 %
    }

    @Test func listGrowingMidRunIsRecomputed() throws {
        var input = EtaInput(project: "p", elapsed: 900, tasksTotal: 4, tasksDone: 3, doneDurations: [300, 300, 300],
                             currentTaskElapsed: 0)
        let before = try #require(EtaModel.taskEstimate(input, historicalTaskDurations: []))
        input.tasksTotal = 7
        let after = try #require(EtaModel.taskEstimate(input, historicalTaskDurations: []))
        #expect(before.likely == 300)
        #expect(after.likely == 4 * 300)
        #expect(after.basis == .tasks(done: 3, total: 7))
    }

    @Test func oneSlowTaskCountsButNeverGoesNegative() throws {
        // The current task has run far longer than a typical task: its remainder floors at 10 % of a task.
        let input = EtaInput(project: "p", elapsed: 2000, tasksTotal: 5, tasksDone: 2, doneDurations: [300, 300],
                             currentTaskElapsed: 1400)
        let e = try #require(EtaModel.taskEstimate(input, historicalTaskDurations: []))
        #expect(e.likely == 30 + 2 * 300)
        #expect(e.low > 0)
        // A slow finished task widens the range (uneven tasks = less certain).
        let uneven = EtaInput(project: "p", elapsed: 2000, tasksTotal: 6, tasksDone: 3, doneDurations: [200, 250, 1500])
        let steady = EtaInput(project: "p", elapsed: 2000, tasksTotal: 6, tasksDone: 3, doneDurations: [640, 650, 660])
        let u = try #require(EtaModel.taskEstimate(uneven, historicalTaskDurations: []))
        let s = try #require(EtaModel.taskEstimate(steady, historicalTaskDurations: []))
        #expect((u.high - u.low) / u.likely > (s.high - s.low) / s.likely)
        #expect(u.confidence < s.confidence)
    }

    @Test func observedWeightGrowsWithCompletedTasks() throws {
        // History says 600 s per task, this run does 200 s.
        let w0 = try #require(EtaModel.perTaskTime(observed: [], historicalMedian: 600))
        let w1 = try #require(EtaModel.perTaskTime(observed: [200], historicalMedian: 600))
        let w2 = try #require(EtaModel.perTaskTime(observed: [200, 200], historicalMedian: 600))
        let w6 = try #require(EtaModel.perTaskTime(observed: Array(repeating: 200, count: 6), historicalMedian: 600))
        #expect(w0 == 600)
        #expect(abs(w1 - (200.0 / 3 + 400)) < 0.001) // weight 1/3
        #expect(w2 == 400)                            // weight 1/2
        #expect(w6 == 300)                            // weight 3/4
        #expect(EtaModel.perTaskTime(observed: [], historicalMedian: nil) == nil)
    }

    @Test func taskListWithoutAnyTimingIsLowConfidence() throws {
        let input = EtaInput(project: "p", elapsed: 40, tasksTotal: 3, tasksDone: 0, currentTaskElapsed: 40)
        let e = try #require(EtaModel.taskEstimate(input, historicalTaskDurations: []))
        #expect(e.confidence == .low)
        #expect((e.high - e.low) / e.likely > 1) // ±55 %: wide
    }

    @Test func conditionalHistoryPercentiles() throws {
        // Past turns lasting 10…19 min; 12 min elapsed: only 13…19 min remain comparable (7 turns).
        let history = (10...19).map { turn("p", active: Double($0) * 60) }
        let e = try #require(EtaModel.historyEstimate(EtaInput(project: "p", elapsed: 12 * 60 + 30), history: history))
        let remaining = (13...19).map { Double($0) * 60 - 750 }
        #expect(e.low == EtaModel.percentile(remaining, 0.25))
        #expect(e.likely == EtaModel.percentile(remaining, 0.5))
        #expect(e.high == EtaModel.percentile(remaining, 0.75))
        #expect(e.basis == .history(count: 7, scope: .project))
        #expect(e.confidence == .low) // fewer than 20 samples
    }

    @Test func historyFallsBackToAllProjectsAndThenToNothing() throws {
        let other = (1...6).map { turn("other", active: Double($0) * 600) }
        let few = (1...3).map { turn("p", active: Double($0) * 600) }
        let e = try #require(EtaModel.historyEstimate(EtaInput(project: "p", elapsed: 60), history: few + other))
        #expect(e.basis == .history(count: 9, scope: .all))
        // Not enough comparable turns anywhere (only 2 lasted longer than 40 min): no estimate at all.
        #expect(EtaModel.historyEstimate(EtaInput(project: "p", elapsed: 2400), history: few + other) == nil)
        #expect(EtaModel.estimate(EtaInput(project: "p", elapsed: 60), history: []) == nil)
    }

    @Test func percentileInterpolates() {
        #expect(EtaModel.percentile([], 0.5) == nil)
        #expect(EtaModel.percentile([5], 0.9) == 5)
        #expect(EtaModel.percentile([1, 2, 3, 4], 0.5) == 2.5)
        #expect(EtaModel.percentile([4, 1, 3, 2], 0.25) == 1.75)
    }

    @Test func runningSubagentSetsALowerBound() throws {
        let history = (0..<4).map { _ in turn("p", active: 600, agents: [SubagentRun(type: "Explore", duration: 1200)]) }
        let input = EtaInput(project: "p", elapsed: 300, tasksTotal: 2, tasksDone: 1, doneDurations: [120],
                             currentTaskElapsed: 30, runningAgents: [("Explore", 200)])
        let e = try #require(EtaModel.estimate(input, history: history))
        #expect(e.likely == 1000) // 1200 − 200 left for the Explore agent, far more than the 90 s task remainder
        #expect(e.low >= 1000)
        // An agent type without history adds nothing.
        #expect(EtaModel.subagentFloor([("unknown", 10)], history: history) == nil)
    }

    @Test func estimateNeverFeedsTheStateMachine() {
        // Same hook stream with and without task events: identical sleep decisions.
        func run(_ events: [(Event, TimeInterval)]) -> (StateMachine, [[Effect]]) {
            var m = machine()
            let fx = events.map { m.handle($0.0, at: at($0.1)) }
            return (m, fx)
        }
        let base: [(Event, TimeInterval)] = [(hook(.userPromptSubmit), 0), (hook(.postToolUse), 10), (hook(.stop), 60), (.tick, 90)]
        let withTasks: [(Event, TimeInterval)] = [(hook(.userPromptSubmit), 0), (task(.taskCreated, created("1", "x")), 5),
                                                  (task(.taskCreated, created("2", "y")), 6), (hook(.postToolUse), 10),
                                                  (task(.taskCompleted, [.completed(id: "1", subject: "x")]), 30),
                                                  (hook(.stop), 60), (.tick, 90)]
        let (a, fa) = run(base)
        let (b, fb) = run(withTasks)
        #expect(a == b)
        #expect(fa.flatMap { $0 } == fb.flatMap { $0 })
        // A task event for an unknown session creates nothing in the state machine.
        var m = machine()
        #expect(m.handle(task(.taskCreated, created("1", "x"), session: "ghost"), at: at(0)).isEmpty)
        #expect(m.sessions.isEmpty)
    }
}

// MARK: - Formatting and smoothing

@Suite struct EtaFormatTests {
    @Test(arguments: [(0.0, nil), (30, nil), (59, nil), (60, 60), (89, 60), (91, 120), (599, 600), (600, 600),
                      (720, 600), (760, 900), (3599, 3600), (3600, 3600), (4000, 3600), (4100, 4500)] as [(Double, Double?)])
    func rounding(_ seconds: Double, _ expected: Double?) {
        #expect(EtaFormat.rounded(seconds) == expected)
    }

    @Test func neverZeroWhileWorking() {
        for s in stride(from: 0.0, to: 7200, by: 7) {
            let text = EtaFormat.duration(s)
            #expect(text != "0 min" && !text.hasPrefix("0"), "\(s) → \(text)")
        }
        #expect(EtaFormat.duration(20) == "soon")
        #expect(EtaFormat.approx(20) == "soon")
    }

    @Test func texts() {
        #expect(EtaFormat.duration(12 * 60) == "10 min")
        #expect(EtaFormat.duration(6.4 * 60) == "6 min")
        #expect(EtaFormat.duration(75 * 60) == "1:15 h")
        #expect(EtaFormat.range(5 * 60, 15 * 60) == "5–15 min")
        #expect(EtaFormat.range(105 * 60, 120 * 60) == "1:45–2:00 h")
        #expect(EtaFormat.range(50 * 60, 75 * 60) == "50 min–1:15 h")
        #expect(EtaFormat.range(11 * 60, 12 * 60 + 20) == "~10 min") // both ends round to the same value
        #expect(EtaFormat.range(20, 4 * 60) == "soon–4 min")
        let confident = Estimate(low: 600, likely: 720, high: 840, confidence: .medium, basis: .tasks(done: 1, total: 4))
        #expect(EtaFormat.remaining(confident) == "~10 min")
        #expect(EtaFormat.plusMinus(confident) == "±2 min")
        var unsure = confident
        unsure.confidence = .low
        #expect(EtaFormat.remaining(unsure) == "10–15 min")
    }

    @Test func emaSmoothsTheFinishInstant() {
        var s = EtaSmoother(tau: 30)
        let e = Estimate(low: 500, likely: 600, high: 700, confidence: .high, basis: .tasks(done: 2, total: 5))
        #expect(s.update(e, at: at(0)) == e) // first value is taken as is
        // Steady model output: the remaining time counts down with the clock, no lag.
        var steady = e
        steady.likely = 590; steady.low = 490; steady.high = 690
        #expect(abs(s.update(steady, at: at(10)).likely - 590) < 0.001)
        // One outlier update (the model suddenly says 30 min) moves the display only part of the way.
        let spike = Estimate(low: 1700, likely: 1800, high: 1900, confidence: .high, basis: .tasks(done: 2, total: 5))
        let shown = s.update(spike, at: at(11))
        let alpha = 1 - exp(-1.0 / 30)
        #expect(abs(shown.likely - (589 + alpha * (1800 - 589))) < 0.01)
        #expect(shown.likely < 700)
        // Sustained, it converges.
        var last = shown
        for t in 12...300 {
            last = s.update(Estimate(low: 1800 - Double(t - 11) - 100, likely: 1800 - Double(t - 11),
                                     high: 1800 - Double(t - 11) + 100, confidence: .high, basis: .tasks(done: 2, total: 5)), at: at(Double(t)))
        }
        #expect(abs(last.likely - (1800 - 289)) < 1)
    }
}

// MARK: - Tracker

@Suite struct TurnTrackerTests {
    private func run(_ tracker: inout TurnTracker, _ steps: [(Event, TimeInterval)], history: [TurnRecord] = []) -> [TurnRecord] {
        var records: [TurnRecord] = []
        for (event, t) in steps {
            if let r = tracker.handle(hookEvent(event), at: at(t)) { records.append(r) }
            tracker.tick(at: at(t), history: history)
        }
        return records
    }

    @Test func turnLifecycleAndRecord() throws {
        var tracker = TurnTracker()
        let records = run(&tracker, [
            (hook(.userPromptSubmit), 0),
            (task(.taskCreated, created("1", "a")), 1), (task(.taskCreated, created("2", "b")), 2),
            (task(.postToolUse, [.started(id: "1")]), 5),
            (task(.taskCompleted, [.completed(id: "1", subject: "a")]), 125),
            (task(.postToolUse, [.completed(id: "1", subject: nil)]), 126), // same completion again: ignored
            (.hook(HookEvent(kind: .subagentStart, sessionID: "a", agentID: "x", agentType: "Explore")), 130),
            (.hook(HookEvent(kind: .subagentStop, sessionID: "a", agentID: "x")), 190),
            (task(.taskCompleted, [.completed(id: "2", subject: "b")]), 245),
            (hook(.stop), 250),
        ])
        let r = try #require(records.first)
        #expect(records.count == 1)
        #expect(r.project == "proj")
        #expect(r.activeDuration == 250)
        #expect(r.taskCount == 2)
        #expect(r.taskDurations == [120, 120])
        #expect(r.subagents == [SubagentRun(type: "Explore", duration: 60)])
        #expect(tracker.turns.isEmpty)
    }

    @Test func waitingTimeIsExcluded() throws {
        var tracker = TurnTracker()
        let records = run(&tracker, [
            (hook(.userPromptSubmit), 0),
            (hook(.permissionRequest), 100),
            (hook(.postToolUse), 1900), // answered 30 min later from the phone
            (hook(.stop), 2000),
        ])
        let r = try #require(records.first)
        #expect(r.duration == 2000)
        #expect(r.activeDuration == 200)
    }

    @Test func checkpointsAtQuarterHalfAndThreeQuarters() throws {
        var tracker = TurnTracker()
        var steps: [(Event, TimeInterval)] = [(hook(.userPromptSubmit), 0)]
        for i in 1...4 { steps.append((task(.taskCreated, created("\(i)", "t\(i)")), 1)) }
        for i in 1...4 { steps.append((task(.taskCompleted, [.completed(id: "\(i)", subject: nil)]), Double(i) * 100)) }
        // Ticks every 5 s so samples exist throughout.
        for t in stride(from: 2.0, to: 400, by: 5) { steps.append((.tick, t)) }
        steps.sort { $0.1 < $1.1 }
        var records: [TurnRecord] = []
        for (event, t) in steps {
            if case .hook(let h) = event, let r = tracker.handle(h, at: at(t)) { records.append(r) }
            tracker.tick(at: at(t), history: [])
        }
        if let r = tracker.handle(hookEvent(hook(.stop)), at: at(400)) { records.append(r) }
        let r = try #require(records.first)
        #expect(r.checkpoints.map(\.fraction) == [0.25, 0.5, 0.75])
        // At 50 % (200 s) two of four tasks were done at 100 s each: predicted total ≈ 400 s.
        let half = try #require(r.checkpoints.first { $0.fraction == 0.5 })
        #expect(half.tasksTotal == 4)
        #expect(half.low <= 400 && 400 <= half.high)
    }

    @Test func interruptedTurnIsDiscardedAndPartialTurnsAreNotStored() {
        var tracker = TurnTracker()
        _ = run(&tracker, [(hook(.userPromptSubmit), 0), (task(.taskCreated, created("1", "x")), 1)])
        tracker.discard(["a"])
        #expect(tracker.turns.isEmpty)
        // Vigil started mid-turn: a task event adopts a partial turn; its Stop is not stored as history.
        let records = run(&tracker, [(task(.taskCreated, created("1", "x"), session: "b"), 10),
                                     (hook(.stop, "b"), 50)])
        #expect(tracker.turns.isEmpty)
        #expect(records.isEmpty)
    }

    @Test func growthBadgeLastsThirtySeconds() throws {
        var tracker = TurnTracker()
        _ = run(&tracker, [
            (hook(.userPromptSubmit), 0),
            (task(.taskCreated, created("1", "a")), 1), (task(.taskCreated, created("2", "b")), 1),
            (task(.postToolUse, [.started(id: "1")]), 2),
        ])
        #expect(tracker.turns["a"]?.growth == nil) // the initial list is not "growth"
        _ = run(&tracker, [(task(.taskCreated, created("3", "c")), 50), (task(.taskCreated, created("4", "d")), 51)])
        #expect(tracker.turns["a"]?.growth?.count == 2)
        #expect(tracker.turns["a"]?.tasks.count == 4)
        tracker.tick(at: at(80), history: [])
        #expect(tracker.turns["a"]?.growth?.count == 2)
        tracker.tick(at: at(82), history: [])
        #expect(tracker.turns["a"]?.growth == nil)
    }

    @Test func unfinishedTasksCarryIntoTheNextTurn() {
        var tracker = TurnTracker()
        _ = run(&tracker, [(hook(.userPromptSubmit), 0), (task(.taskCreated, created("1", "a")), 1),
                           (task(.taskCreated, created("2", "b")), 1), (task(.taskCompleted, [.completed(id: "1", subject: nil)]), 60),
                           (hook(.stop), 70), (hook(.userPromptSubmit), 100)])
        #expect(tracker.turns["a"]?.tasks.map(\.id) == ["2"])
    }

    @Test func notificationOnlyOnce() {
        var tracker = TurnTracker()
        _ = run(&tracker, [(hook(.userPromptSubmit), 0)])
        let first = tracker.markNotified("a")
        let second = tracker.markNotified("a")
        let unknown = tracker.markNotified("nobody")
        #expect(first && !second && !unknown)
    }
}

// MARK: - Accuracy

@Suite struct EtaAccuracyTests {
    private let now = t0.addingTimeInterval(30 * 86400)

    @Test func verdicts() {
        #expect(EtaAccuracy.verdict(turn("p", active: 600, checkpoint: (500, 600, 700))) == .hit)
        #expect(EtaAccuracy.verdict(turn("p", active: 880, checkpoint: (500, 600, 700))) == .over(180))
        #expect(EtaAccuracy.verdict(turn("p", active: 400, checkpoint: (500, 600, 700))) == .under(100))
        #expect(EtaAccuracy.verdict(turn("p", active: 400)) == .noEstimate)
    }

    @Test func earliestCheckpointIsScored() {
        var r = turn("p", active: 600)
        r.checkpoints = [EtaCheckpoint(fraction: 0.75, low: 590, likely: 600, high: 610, confidence: .high, tasksTotal: 3),
                         EtaCheckpoint(fraction: 0.5, low: 100, likely: 200, high: 300, confidence: .low, tasksTotal: nil)]
        #expect(EtaAccuracy.checkpoint(r)?.fraction == 0.5)
        #expect(EtaAccuracy.verdict(r) == .over(300))
    }

    @Test func averageErrorAndHitsOverTheLast20() {
        // 25 scored turns (newest first): the 20 newest have error 60 s and are hits; 5 old ones are way off.
        let recent = (0..<20).map { i in turn("p", active: 660, startedAt: now.addingTimeInterval(-Double(i) * 3600), checkpoint: (500, 600, 700)) }
        let old = (0..<5).map { i in turn("p", active: 3000, startedAt: now.addingTimeInterval(-Double(100 + i) * 3600), checkpoint: (500, 600, 700)) }
        let unscored = [turn("p", active: 100, startedAt: now)]
        let s = EtaAccuracy.summary(unscored + recent + old, now: now)
        #expect(s.scored == 20)
        #expect(s.hits == 20)
        #expect(s.meanError == 60)
    }

    @Test func trend() {
        func week(_ offsetDays: Double, error: TimeInterval) -> [TurnRecord] {
            (0..<4).map { i in turn("p", active: 600 + error, startedAt: now.addingTimeInterval(-(offsetDays + Double(i) * 0.5) * 86400),
                                     checkpoint: (0, 600, 5000)) }
        }
        #expect(EtaAccuracy.summary(week(1, error: 120) + week(8, error: 540), now: now).trend == .improving(previous: 540))
        #expect(EtaAccuracy.summary(week(1, error: 540) + week(8, error: 120), now: now).trend == .worsening(previous: 120))
        #expect(EtaAccuracy.summary(week(1, error: 300) + week(8, error: 310), now: now).trend == .steady(previous: 310))
        #expect(EtaAccuracy.summary(week(1, error: 300), now: now).trend == .notEnoughData)
        #expect(EtaAccuracy.summary([], now: now) == EtaAccuracy.Summary(meanError: nil, hits: 0, scored: 0, trend: .notEnoughData))
    }

    @Test func recordsRoundTripAndOldOnesDecode() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TurnStore(url: dir.appendingPathComponent("turns.json"))
        let r = turn("p", active: 600, tasks: [100, 200], agents: [SubagentRun(type: "Explore", duration: 50)], checkpoint: (500, 600, 700), tasksTotal: 2)
        store.append(r)
        #expect(store.load() == [r])
        let minimal = #"[{"id":"x","project":"p","startedAt":"2026-09-01T10:00:00Z","duration":90}]"#
        try minimal.write(to: dir.appendingPathComponent("turns.json"), atomically: true, encoding: .utf8)
        #expect(store.load().first?.activeDuration == 90)
        store.clear()
        #expect(store.load().isEmpty)
    }
}

// MARK: - Czech

@Suite struct EtaCzechTests {
    @Test(arguments: [(1, PluralCategory.one), (2, .few), (4, .few), (5, .many), (22, .many)])
    func stepPluralCategory(_ n: Int, _ expected: PluralCategory) {
        // "+1 krok", "+2 kroky", "+4 kroky", "+5 kroků", "+22 kroků" (only the whole number decides).
        #expect(PluralCategory.czech(n) == expected)
    }

    @Test func stepPluralTranslations() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let strings = catalog["strings"] as! [String: Any]
        func cs(_ key: String) -> String? {
            (((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?["cs"] as? [String: Any])
                .flatMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
        }
        #expect(cs("+1 step") == "+1 krok")
        #expect(cs("+%d steps (2-4)") == "+%d kroky")
        #expect(cs("+%d steps") == "+%d kroků")
        #expect(cs("Step %d of %d") == "Krok %d z %d")
        #expect(cs("Step %d of %d (ze)") == "Krok %d ze %d")
    }

    @Test(arguments: [(2, false), (3, true), (4, true), (5, false), (6, true), (7, true), (8, false), (10, false), (12, false),
                      (13, true), (14, true), (17, true), (20, false), (33, true), (45, true), (50, false), (64, true),
                      (100, true), (150, true), (300, true), (500, false)])
    func zOrZe(_ n: Int, _ ze: Bool) {
        #expect(CzechPreposition.usesZe(n) == ze)
    }
}
