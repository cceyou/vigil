import Foundation
import Testing
@testable import VigilCore

/// Everything that goes through `SettingsStore`. Each test gets its own UserDefaults suite, removed in tearDown.
@Suite final class SettingsStoreTests {
    private let prefs = TestDefaults()
    private var store: SettingsStore { SettingsStore(defaults: prefs.defaults) }

    deinit { prefs.tearDown() }

    private func saveRaw(_ json: String) { prefs.defaults.set(Data(json.utf8), forKey: "vigil.settings.v1") }

    private func load(_ json: String) -> AppSettings {
        saveRaw(json)
        return store.load()
    }

    @Test func settingsRoundTrip() {
        #expect(store.load() == AppSettings())
        var s = AppSettings()
        s.enabled = false
        s.config.graceSeconds = 90
        s.config.notificationPolicy = .treatAsIdle
        s.config.maxWaiting = 1800
        store.save(s)
        #expect(store.load() == s)
    }

    @Test func oldSettingsLoadWithNewDefaults() {
        // Saved before the UI settings existed: nothing may reset to defaults.
        let loaded = load(#"{"enabled":false,"hasSeenOnboarding":true,"dryRun":true,"revision":2,"config":{"graceSeconds":120}}"#)
        #expect(loaded.enabled == false)
        #expect(loaded.dryRun == true)
        #expect(loaded.hasSeenOnboarding)
        #expect(loaded.config.graceSeconds == 120)
        #expect(loaded.ui == UISettings())
        #expect(loaded.ui.notchEnabled && !loaded.ui.hideInFullScreen && loaded.ui.usageNotifications)
        #expect(loaded.ui.shortcut == HotKeySpec(enabled: true, keyCode: 32, modifiers: 0x0900))

        var changed = loaded
        changed.ui.accent = .purple
        changed.ui.notchPosition = 0.3
        changed.ui.notchDisplays = .main
        store.save(changed)
        #expect(store.load() == changed)
    }

    // MARK: migrations

    @Test func migrationMovesOldBatteryDefault() {
        // Saved by a build before migrations existed: no "revision" key, threshold at the old 15 % default.
        let loaded = load(#"{"enabled":true,"hasSeenOnboarding":true,"dryRun":false,"config":{"lowBatteryThreshold":15,"maxKeepAwake":28800,"sleepOnlyIfLidClosed":true,"notificationPolicy":"treatAsIdle","manualKeepAwake":3600,"graceSeconds":300}}"#)
        #expect(loaded.config.lowBatteryThreshold == 5)
        #expect(loaded.config.graceSeconds == 300)
        #expect(loaded.revision == AppSettings.currentRevision)

        // A value the user picked on purpose (after migration) is left alone.
        var chosen = loaded
        chosen.config.lowBatteryThreshold = 15
        store.save(chosen)
        #expect(store.load().config.lowBatteryThreshold == 15)
    }

    @Test func migrationMovesTheOldDefaultWaitingPolicyToKeepAwake() {
        let rev2 = load(#"{"revision":2,"config":{"notificationPolicy":"treatAsIdle","graceSeconds":120}}"#)
        #expect(rev2.config.notificationPolicy == .keepAwake)
        #expect(rev2.config.graceSeconds == 120)
        #expect(rev2.config.maxWaiting == 2 * 3600)
        #expect(rev2.revision == AppSettings.currentRevision)
        let unversioned = load(#"{"config":{"notificationPolicy":"treatAsIdle"}}"#)
        #expect(unversioned.config.notificationPolicy == .keepAwake)
    }

    @Test func migrationKeepsAWaitingPolicyTheUserChanged() {
        #expect(load(#"{"revision":2,"config":{"notificationPolicy":"keepAwake","maxWaiting":1800}}"#).config.maxWaiting == 1800)
        // Chosen after the migration ran: "sleep after a delay" sticks.
        #expect(load(#"{"revision":3,"config":{"notificationPolicy":"treatAsIdle"}}"#).config.notificationPolicy == .treatAsIdle)
    }

    @Test func waitingPolicyMigrationRunsOnlyOnce() {
        saveRaw(#"{"revision":2,"config":{"notificationPolicy":"treatAsIdle"}}"#)
        var s = store.load()
        #expect(s.config.notificationPolicy == .keepAwake)
        s.config.notificationPolicy = .treatAsIdle
        store.save(s)
        #expect(store.load().config.notificationPolicy == .treatAsIdle)
    }

    @Test func freshSettingsDefaultToKeepAwake() {
        #expect(Config().notificationPolicy == .keepAwake)
        #expect(Config().maxWaiting == 2 * 3600)
    }

    // MARK: hygiene

    @Test func testSuitesLiveOutsideTheRealPreferences() {
        let other = TestDefaults()
        let store = SettingsStore(defaults: other.defaults)
        var s = AppSettings()
        s.config.graceSeconds = 77
        store.save(s)
        #expect(store.load().config.graceSeconds == 77)
        #expect(other.name.hasPrefix("/"))
        #expect(!other.name.contains("/Library/Preferences"))
        other.tearDown()
        #expect(store.load() == AppSettings())
        #expect(!FileManager.default.fileExists(atPath: other.realPreferencesPlist.path))
    }

    /// Regression guard: no test suite plist in the real Preferences (earlier builds left dozens there).
    @Test func noTestPlistsInTheRealPreferences() throws {
        let prefs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: prefs.path).filter { $0.hasPrefix(TestDefaults.prefix) }
        #expect(leftovers.isEmpty, "\(leftovers.count) leftover test plists in ~/Library/Preferences")
    }

    /// Tests may only reach UserDefaults through `TestDefaults`; `SettingsStore()` without arguments would
    /// write to the real (test runner's) preferences.
    @Test func testsNeverTouchRealPreferences() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var scanned = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            scanned += 1
            // TestSupport defines TestDefaults; this file names the patterns it looks for.
            if name == "TestSupport.swift" || name == URL(fileURLWithPath: #filePath).lastPathComponent { continue }
            #expect(!text.contains("UserDefaults(suiteName"), "\(name) creates its own UserDefaults suite; use TestDefaults")
            #expect(!text.contains("UserDefaults.standard"), "\(name) uses UserDefaults.standard")
            #expect(!text.contains("SettingsStore()"), "\(name) uses SettingsStore() (real preferences)")
        }
        #expect(scanned > 5)
    }
}
