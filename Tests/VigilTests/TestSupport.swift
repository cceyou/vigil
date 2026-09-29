import Foundation
@testable import VigilCore

let t0 = Date(timeIntervalSince1970: 1_000_000)

func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

func hook(_ kind: HookKind, _ id: String = "a", cwd: String? = "/Users/me/proj", pid: Int32? = nil,
          type notificationType: String? = nil) -> Event {
    .hook(HookEvent(kind: kind, sessionID: id, cwd: cwd, pid: pid, notificationType: notificationType))
}

/// Claude Code's Notification hook for a permission prompt.
func permissionPrompt(_ id: String = "a") -> Event { hook(.notification, id, type: "permission_prompt") }

func machine(enabled: Bool = true, _ configure: (inout Config) -> Void = { _ in }) -> StateMachine {
    var config = Config()
    configure(&config)
    return StateMachine(enabled: enabled, config: config)
}

/// A unique temp directory removed by the caller.
func makeTempDir(_ name: String = "vigil-test") -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Thread-safe collector for events arriving from the socket server.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HookEvent] = []
    func add(_ e: HookEvent) { lock.withLock { events.append(e) } }
    var all: [HookEvent] { lock.withLock { events } }
    func waitForCount(_ n: Int, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if all.count >= n { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return all.count >= n
    }
}

/// A private UserDefaults suite for one test, so nothing ever lands in ~/Library/Preferences.
///
/// A plain suite name is not enough: even after `removePersistentDomain` (or removing every key, with or without
/// `CFPreferencesAppSynchronize`), cfprefsd writes an empty 42-byte `~/Library/Preferences/<suite>.plist` once
/// the test process exits. So the suite name is an absolute path in a temp directory: CFPreferences then keeps
/// the domain in `<path>.plist` there instead. `tearDown()` still removes the domain, and each run clears the
/// directory of files left by earlier runs. Call `tearDown()` from the suite's `deinit` (Swift Testing makes a
/// fresh suite instance per test, so `deinit` is the per-test tearDown).
final class TestDefaults {
    static let prefix = "vigil-test-"
    static let directory: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vigil-test-prefs")
        try? FileManager.default.removeItem(at: dir) // leftovers from earlier runs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    let id = "\(TestDefaults.prefix)\(UUID().uuidString)"
    /// The suite name: an absolute path, so the backing plist is `<name>.plist` in the temp directory.
    let name: String
    let defaults: UserDefaults

    init() {
        name = Self.directory.appendingPathComponent(id).path
        defaults = UserDefaults(suiteName: name)!
    }

    /// Where a plain `UserDefaults(suiteName: id)` would have put its file. Must never exist.
    var realPreferencesPlist: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences/\(id).plist")
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(atPath: name + ".plist")
    }
}
