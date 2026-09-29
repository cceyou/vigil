import Foundation
import Testing
@testable import VigilCore

@Suite struct StatusLineParserTests {
    private static let full = """
    {"session_id":"s1","cwd":"/Users/me/alwayson","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
     "context_window":{"used_percentage":37.5},
     "rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1790000000},
                    "seven_day":{"used_percentage":15.25,"resets_at":1790400000}}}
    """

    @Test func parsesRateLimitsWithEpochResets() throws {
        let s = try #require(StatusLineParser.parse(Data(Self.full.utf8)))
        #expect(s.sessionID == "s1")
        #expect(s.cwd == "/Users/me/alwayson")
        #expect(s.model == "Opus 5.5")
        #expect(s.contextPercent == 37.5)
        #expect(s.fiveHour == UsageWindow(usedPercentage: 42, resetsAt: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(s.sevenDay == UsageWindow(usedPercentage: 15.25, resetsAt: Date(timeIntervalSince1970: 1_790_400_000)))
        #expect(s.hasRateLimits)
    }

    @Test func parsesWithoutRateLimits() throws {
        // API-key login, old Claude Code, or before the first API response of a session.
        let json = #"{"session_id":"s2","cwd":"/x","model":{"display_name":"Sonnet 5"},"context_window":{"used_percentage":0}}"#
        let s = try #require(StatusLineParser.parse(Data(json.utf8)))
        #expect(s.fiveHour == nil && s.sevenDay == nil)
        #expect(!s.hasRateLimits)
        #expect(s.contextPercent == 0) // 0 is a number, not "false"
        #expect(s.model == "Sonnet 5")
    }

    @Test func acceptsTheWrappedSocketMessage() throws {
        let wrapped = #"{"vigil_event":"StatusLine","payload":\#(Self.full)}"#
            .replacingOccurrences(of: "\n", with: " ")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(wrapped.utf8)) as? [String: Any])
        #expect(StatusLineParser.isStatusLine(object))
        #expect(StatusLineParser.parse(Data(wrapped.utf8))?.fiveHour?.usedPercentage == 42)
    }

    @Test func toleratesPartialAndOddValues() throws {
        // One window only, percentages clamped, a window without resets_at is ignored.
        let json = #"{"session_id":"s3","rate_limits":{"five_hour":{"used_percentage":130,"resets_at":1790000000},"seven_day":{"used_percentage":5}}}"#
        let s = try #require(StatusLineParser.parse(Data(json.utf8)))
        #expect(s.fiveHour?.usedPercentage == 100)
        #expect(s.sevenDay == nil)
        #expect(s.model == nil && s.cwd == nil)
    }

    @Test func rejectsGarbage() {
        for bad in ["", "nope", "[]", #"{"cwd":"/x"}"#, #"{"session_id":""}"#] {
            #expect(StatusLineParser.parse(Data(bad.utf8)) == nil)
        }
    }
}

@Suite struct UsagePaceTests {
    private let week: TimeInterval = 7 * 86400
    private let resets = Date(timeIntervalSince1970: 2_000_000_000)
    private var start: Date { resets.addingTimeInterval(-week) }

    @Test func onTrackWhenUsageIsBelowElapsedShare() {
        // Half the week gone, 40 % used.
        #expect(UsagePace.evaluate(usedPercentage: 40, resetsAt: resets, length: week, now: start.addingTimeInterval(week / 2)) == .onTrack)
        // Exactly on the line.
        #expect(UsagePace.evaluate(usedPercentage: 50, resetsAt: resets, length: week, now: start.addingTimeInterval(week / 2)) == .onTrack)
    }

    @Test func projectsWhenTheLimitRunsOut() {
        // A quarter of the week gone (42 h), 50 % used: 100 % after 84 h, before the reset.
        let now = start.addingTimeInterval(week / 4)
        let pace = UsagePace.evaluate(usedPercentage: 50, resetsAt: resets, length: week, now: now)
        #expect(pace == .exhausts(at: start.addingTimeInterval(week / 2)))
    }

    @Test func tooEarlyOrNothingUsedIsOnTrack() {
        #expect(UsagePace.evaluate(usedPercentage: 10, resetsAt: resets, length: week, now: start.addingTimeInterval(600)) == .onTrack)
        #expect(UsagePace.evaluate(usedPercentage: 0, resetsAt: resets, length: week, now: start.addingTimeInterval(week / 2)) == .onTrack)
        #expect(UsagePace.evaluate(usedPercentage: 90, resetsAt: resets, length: week, now: resets.addingTimeInterval(1)) == .onTrack)
    }

    @Test func alreadyAtTheLimitRunsOutNow() {
        let now = start.addingTimeInterval(week / 2)
        #expect(UsagePace.evaluate(usedPercentage: 100, resetsAt: resets, length: week, now: now) == .exhausts(at: now))
    }
}

@Suite struct UsageStateTests {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)
    private func snap(five: Double? = nil, fiveReset: TimeInterval = 3600, week: Double? = nil, weekReset: TimeInterval = 86400,
                      id: String = "s", ctx: Double? = nil) -> StatusLineSnapshot {
        StatusLineSnapshot(sessionID: id, cwd: "/p/\(id)", model: "Opus", contextPercent: ctx,
                           fiveHour: five.map { UsageWindow(usedPercentage: $0, resetsAt: t.addingTimeInterval(fiveReset)) },
                           sevenDay: week.map { UsageWindow(usedPercentage: $0, resetsAt: t.addingTimeInterval(weekReset)) })
    }

    @Test func resetRolloverShowsZeroAndAnnouncesOnce() {
        var u = UsageState()
        _ = u.apply(snap(five: 60, week: 20), at: t)
        #expect(u.effective(.fiveHour, at: t.addingTimeInterval(10))?.usedPercentage == 60)
        #expect(u.rollover(at: t.addingTimeInterval(100)).isEmpty)

        // Past the 5-hour reset: show 0 % / reset, announce once.
        let after = t.addingTimeInterval(3601)
        let eff = u.effective(.fiveHour, at: after)
        #expect(eff?.usedPercentage == 0 && eff?.isReset == true)
        #expect(u.effective(.sevenDay, at: after)?.isReset == false)
        #expect(u.rollover(at: after) == [.reset(.fiveHour)])
        #expect(u.rollover(at: after.addingTimeInterval(60)).isEmpty)

        // New data for the next cycle: a normal window again, and no second reset alert.
        let next = StatusLineSnapshot(sessionID: "s", fiveHour: UsageWindow(usedPercentage: 3, resetsAt: after.addingTimeInterval(5 * 3600)))
        #expect(u.apply(next, at: after.addingTimeInterval(120)).isEmpty)
        #expect(u.effective(.fiveHour, at: after.addingTimeInterval(120))?.usedPercentage == 3)
    }

    @Test func resetIsAnnouncedWhenNewDataArrivesBeforeTheTick() {
        var u = UsageState()
        _ = u.apply(snap(five: 50), at: t)
        let later = t.addingTimeInterval(4000)
        let next = StatusLineSnapshot(sessionID: "s", fiveHour: UsageWindow(usedPercentage: 1, resetsAt: later.addingTimeInterval(18000)))
        #expect(u.apply(next, at: later) == [.reset(.fiveHour)])
        #expect(u.rollover(at: later).isEmpty)
    }

    @Test func emptyWindowResetIsSilent() {
        var u = UsageState()
        _ = u.apply(snap(five: 0), at: t)
        #expect(u.rollover(at: t.addingTimeInterval(4000)).isEmpty)
    }

    @Test func thresholdCrossingsFireOncePerCycle() {
        var u = UsageState()
        #expect(u.apply(snap(five: 70, week: 50), at: t).isEmpty)
        #expect(u.apply(snap(five: 81, week: 50), at: t.addingTimeInterval(60)) == [.threshold(.fiveHour, percent: 80)])
        #expect(u.apply(snap(five: 85, week: 50), at: t.addingTimeInterval(120)).isEmpty)
        #expect(u.apply(snap(five: 96, week: 80), at: t.addingTimeInterval(180))
                == [.threshold(.fiveHour, percent: 95), .threshold(.sevenDay, percent: 80)])
        #expect(u.apply(snap(five: 99, week: 99), at: t.addingTimeInterval(240)).isEmpty) // weekly only alerts at 80
        // Jitter in resets_at is still the same cycle.
        #expect(u.apply(snap(five: 97, fiveReset: 3620, week: 99), at: t.addingTimeInterval(300)).isEmpty)
        // A jump straight past both levels announces only the highest.
        var v = UsageState()
        #expect(v.apply(snap(five: 97), at: t) == [.threshold(.fiveHour, percent: 95)])
    }

    @Test func tracksSessionsAndForgetsOldOnes() {
        var u = UsageState()
        _ = u.apply(snap(id: "a", ctx: 40), at: t)
        _ = u.apply(StatusLineSnapshot(sessionID: "a", contextPercent: nil), at: t.addingTimeInterval(5)) // keeps old values
        #expect(u.sessions["a"]?.contextPercent == 40)
        #expect(u.sessions["a"]?.projectName == "a")
        #expect(!u.hasRateLimits)
        #expect(u.lastStatusLineAt == t.addingTimeInterval(5))
        _ = u.apply(snap(id: "b"), at: t.addingTimeInterval(25 * 3600))
        #expect(u.sessions["a"] == nil)
        #expect(u.recentSessions(at: t.addingTimeInterval(25 * 3600 + 30), within: 600).map(\.id) == ["b"])
    }

    @Test func persistsAcrossReload() {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("usage.json")
        var u = UsageState()
        _ = u.apply(snap(five: 81, week: 12, ctx: 50), at: t)
        UsageStore(url: url).save(u)
        let loaded = UsageStore(url: url).load()
        #expect(loaded == u)
        #expect(loaded.tracks[.fiveHour]?.alertedLevel == 80)
        #expect(UsageStore(url: dir.appendingPathComponent("missing.json")).load() == UsageState())
    }
}

@Suite struct CzechPluralTests {
    @Test(arguments: [(0, PluralCategory.many), (1, .one), (2, .few), (3, .few), (4, .few), (5, .many), (11, .many),
                      (21, .many), (22, .many), (100, .many)])
    func categories(_ n: Int, _ expected: PluralCategory) {
        #expect(PluralCategory.czech(n) == expected)
    }
}
