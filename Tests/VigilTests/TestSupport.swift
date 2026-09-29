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
