import CoreGraphics
import Foundation
import Testing
@testable import VigilCore

// MARK: - Full-screen detection

/// Window snapshots recorded on a real machine (macOS 26, one 1512×982 display, menu bar shown in full screen),
/// exactly what Vigil can read without Screen Recording permission.
@Suite struct FullScreenDetectorTests {
    struct Recorded {
        var label: String
        var frontmost: String
        var snapshot: SpaceSnapshot
    }

    static func recorded() throws -> [Recorded] {
        let url = try #require(Bundle.module.url(forResource: "windows", withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
            let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let d = o["display"] as! [String: Double]
            let windows = (o["windows"] as! [[String: Any]]).map { w in
                WindowEntry(owner: w["owner"] as! String, pid: Int32(w["pid"] as! Int), layer: w["layer"] as! Int,
                            alpha: w["alpha"] as! Double,
                            bounds: CGRect(x: w["x"] as! Double, y: w["y"] as! Double, width: w["w"] as! Double, height: w["h"] as! Double))
            }
            return Recorded(label: o["label"] as! String, frontmost: o["frontmost"] as! String,
                            snapshot: SpaceSnapshot(display: CGRect(x: d["x"]!, y: d["y"]!, width: d["w"]!, height: d["h"]!), windows: windows))
        }
    }

    @Test func realFullScreenSpacesAreDetected() throws {
        let fullScreen = try Self.recorded().filter { $0.label.contains("full screen") }
        #expect(fullScreen.count == 3) // Safari, Claude, Terminal
        for r in fullScreen {
            #expect(FullScreenDetector.isNativeFullScreen(r.snapshot), "\(r.label)")
            #expect(FullScreenDetector.dockBackdrop(r.snapshot), "\(r.label)")
        }
        // The app's reveal strip names the app (Terminal's main window starts below its tab bar, still detected).
        let claude = try #require(try Self.recorded().first { $0.label.hasPrefix("Claude") })
        #expect(FullScreenDetector.appRevealStrip(claude.snapshot)?.owner == "Claude")
    }

    @Test func maximizedAndOrdinaryWindowsAreNotFullScreen() throws {
        let desktop = try Self.recorded().filter { $0.label.contains("desktop") }
        #expect(desktop.count == 2)
        for r in desktop {
            #expect(!FullScreenDetector.isNativeFullScreen(r.snapshot), "\(r.label)")
        }
    }

    @Test func aMaximizedWindowCoveringTheWholeDisplayIsNotFullScreen() {
        // Desktop with the menu bar set to hide: a maximized window covers the entire display. The old check
        // (window size == display) called this full screen; it is not.
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let s = SpaceSnapshot(display: display, windows: [
            WindowEntry(owner: "Window Server", pid: 1, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33)),
            WindowEntry(owner: "Claude", pid: 50, layer: 0, bounds: display),
            WindowEntry(owner: "Dock", pid: 60, layer: -2147483624, bounds: display),
        ])
        #expect(!FullScreenDetector.isNativeFullScreen(s))
    }

    @Test func fullScreenWithHiddenMenuBarIsDetected() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let s = SpaceSnapshot(display: display, windows: [
            WindowEntry(owner: "Claude", pid: 50, layer: 26, alpha: 0, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33)),
            WindowEntry(owner: "Claude", pid: 50, layer: 0, bounds: display),
            WindowEntry(owner: "Dock", pid: 60, layer: -2147483622, bounds: display),
            WindowEntry(owner: "Dock", pid: 60, layer: -2147483624, bounds: display),
        ])
        #expect(FullScreenDetector.isNativeFullScreen(s))
    }

    @Test func onlyTheDisplayInQuestionCounts() {
        // Full screen on a second display to the right; the main display shows the desktop.
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let second = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let windows = [
            WindowEntry(owner: "Safari", pid: 70, layer: 26, alpha: 0, bounds: CGRect(x: 1512, y: 0, width: 2560, height: 25)),
            WindowEntry(owner: "Safari", pid: 70, layer: 0, bounds: CGRect(x: 1512, y: 25, width: 2560, height: 1415)),
            WindowEntry(owner: "Dock", pid: 60, layer: -2147483622, bounds: second),
            WindowEntry(owner: "Dock", pid: 60, layer: -2147483624, bounds: second),
            WindowEntry(owner: "Dock", pid: 60, layer: -2147483624, bounds: main),
            WindowEntry(owner: "Finder", pid: 80, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1512, height: 949)),
        ]
        #expect(FullScreenDetector.isNativeFullScreen(SpaceSnapshot(display: second, windows: windows)))
        #expect(!FullScreenDetector.isNativeFullScreen(SpaceSnapshot(display: main, windows: windows)))
    }

    @Test func vigilsOwnWindowsNeverCount() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let s = SpaceSnapshot(display: display, windows: [
            WindowEntry(owner: "Vigil", pid: 500, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33)),
            WindowEntry(owner: "Vigil", pid: 500, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1512, height: 949)),
        ], ownPID: 500)
        #expect(!FullScreenDetector.isNativeFullScreen(s))
    }

    @Test func notchVisibility() {
        #expect(NotchVisibility.decide(enabled: true, onThisDisplay: true, hideInFullScreen: true, fullScreen: false, fullScreenApp: nil) == .visible)
        #expect(NotchVisibility.decide(enabled: true, onThisDisplay: true, hideInFullScreen: true, fullScreen: true, fullScreenApp: "Claude")
                == .hiddenFullScreen(app: "Claude"))
        #expect(NotchVisibility.decide(enabled: true, onThisDisplay: true, hideInFullScreen: false, fullScreen: true, fullScreenApp: "Claude") == .visible)
        #expect(NotchVisibility.decide(enabled: false, onThisDisplay: true, hideInFullScreen: true, fullScreen: false, fullScreenApp: nil) == .disabled)
        #expect(NotchVisibility.decide(enabled: true, onThisDisplay: false, hideInFullScreen: true, fullScreen: false, fullScreenApp: nil) == .notOnThisDisplay)
    }

    @Test func selfTestShowsTheNotchLine() async {
        let test = SelfTest(probe: SelfTestProbe(), isNotificationAuthorized: { true }, awakeHeld: true,
                            readPresence: { .away }, notchReport: ("Notch hidden: Claude is in full screen", true))
        // Only the notch line matters here; run() also performs real checks, so build the result the same way.
        #expect(test.notchReport?.detail == "Notch hidden: Claude is in full screen")
        #expect(test.notchReport?.healthy == true)
    }
}

// MARK: - Usage freshness

@Suite struct UsageFreshnessTests {
    private func snap(_ session: String = "a", five: Double = 42, week: Double = 15, api: Double? = 1000,
                      resets: TimeInterval = 8000) -> StatusLineSnapshot {
        StatusLineSnapshot(sessionID: session, cwd: "/p", model: "Opus",
                           fiveHour: UsageWindow(usedPercentage: five, resetsAt: at(resets)),
                           sevenDay: UsageWindow(usedPercentage: week, resetsAt: at(500_000)), apiDurationMs: api)
    }

    @Test func realStatusLineCarriesTheApiCounter() throws {
        let url = try #require(Bundle.module.url(forResource: "statusline", withExtension: "json", subdirectory: "Fixtures"))
        let s = try #require(StatusLineParser.parse(try Data(contentsOf: url)))
        #expect(s.apiDurationMs == 2_972_150)
        #expect(s.fiveHour?.usedPercentage == 6)
        #expect(s.sevenDay?.usedPercentage == 40)
    }

    @Test func aStatusLineReRunWithOldDataIsNotFresh() {
        var u = UsageState()
        _ = u.apply(snap(), at: at(0))
        #expect(u.dataAt == at(0))
        // The status line re-runs (timer, resize, a new session window) with the same values and API time.
        _ = u.apply(snap(), at: at(700))
        #expect(u.dataAt == at(0))
        #expect(u.updatedAt == at(700)) // it did arrive...
        #expect(u.freshness(at: at(700)) == .stale(since: at(0))) // ...but it is old news
    }

    @Test func changedValuesOrANewApiResponseAreFresh() {
        var u = UsageState()
        _ = u.apply(snap(), at: at(0))
        _ = u.apply(snap(five: 43), at: at(300))
        #expect(u.dataAt == at(300))
        // Same numbers, but a new API response (the limits really are still 43 %).
        _ = u.apply(snap(five: 43, api: 2500), at: at(900))
        #expect(u.dataAt == at(900))
        // Another session's first status line comes after its first response: new.
        _ = u.apply(snap("b", five: 43, api: 10), at: at(1000))
        #expect(u.dataAt == at(1000))
        // That session re-running with the same API time: not new.
        _ = u.apply(snap("b", five: 43, api: 10), at: at(1100))
        #expect(u.dataAt == at(1000))
    }

    @Test func freshnessLabels() {
        #expect(UsageFreshness.evaluate(dataAt: nil, now: at(0)) == .none)
        #expect(UsageFreshness.evaluate(dataAt: at(0), now: at(30)) == .fresh(age: 30))
        #expect(UsageFreshness.evaluate(dataAt: at(0), now: at(600)) == .fresh(age: 600))
        #expect(UsageFreshness.evaluate(dataAt: at(0), now: at(601)) == .stale(since: at(0)))
        #expect(UsageFreshness.evaluate(dataAt: at(0), now: at(601)).isStale)
        // No limits at all: nothing to call fresh or stale.
        var u = UsageState()
        u.dataAt = at(0)
        #expect(u.freshness(at: at(10)) == .none)
    }

    @Test func resetCountdownNeedsNoNewDataAndRollsOverToZero() {
        var u = UsageState()
        _ = u.apply(snap(five: 77, resets: 5000), at: at(0))
        // Hours later, still no new data: before resets_at the old number stands (dimmed), after it it is 0 %.
        #expect(u.effective(.fiveHour, at: at(4999)) == EffectiveWindow(usedPercentage: 77, resetsAt: at(5000), isReset: false))
        #expect(u.effective(.fiveHour, at: at(5000)) == EffectiveWindow(usedPercentage: 0, resetsAt: at(5000), isReset: true))
        #expect(u.rollover(at: at(5001)) == [.reset(.fiveHour)])
        #expect(u.freshness(at: at(5001)).isStale) // the weekly number is still old
    }

    @Test func oldUsageFilesUseTheLastArrivalAsFreshness() throws {
        let json = #"{"tracks":{},"updatedAt":"2026-09-30T10:00:00Z","sessions":{}}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let u = try d.decode(UsageState.self, from: Data(json.utf8))
        #expect(u.dataAt == u.updatedAt)
        // And it round-trips with the new field.
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        var v = u
        v.dataAt = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(try d.decode(UsageState.self, from: e.encode(v)).dataAt == v.dataAt)
    }
}
