import Foundation

public enum CheckID: String, CaseIterable, Identifiable, Sendable {
    case sudoers, hooks, socket, roundTrip, notifications
    public var id: String { rawValue }
}

public enum FixAction: Equatable, Sendable {
    case installSudoers, installHooks, restartServer, requestNotifications
}

public struct CheckResult: Identifiable, Equatable, Sendable {
    public var id: CheckID
    public var passed: Bool
    public var detail: String
    public var fix: FixAction?

    public init(id: CheckID, passed: Bool, detail: String, fix: FixAction?) {
        self.id = id
        self.passed = passed
        self.detail = detail
        self.fix = fix
    }
}

/// Lets the self-test see its own fake hook event arrive at the server.
public final class SelfTestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<String>()
    public init() {}
    public func received(_ event: HookEvent) {
        guard event.kind == .selfTest else { return }
        lock.withLock { _ = seen.insert(event.sessionID) }
    }
    private func hasSeen(_ id: String) -> Bool { lock.withLock { seen.contains(id) } }

    func wait(for sessionID: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasSeen(sessionID) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}

public struct SelfTest: Sendable {
    public var paths: VigilPaths
    public var probe: SelfTestProbe
    public var isNotificationAuthorized: @Sendable () async -> Bool
    /// When true the sudoers check uses `sudo -n -l` instead of actually running `pmset ... 0`.
    public var awakeHeld: Bool

    public init(paths: VigilPaths = .standard, probe: SelfTestProbe,
                isNotificationAuthorized: @escaping @Sendable () async -> Bool, awakeHeld: Bool) {
        self.paths = paths
        self.probe = probe
        self.isNotificationAuthorized = isNotificationAuthorized
        self.awakeHeld = awakeHeld
    }

    public func run() async -> [CheckResult] {
        var results: [CheckResult] = []
        results.append(await checkSudoers())
        results.append(checkHooks())
        results.append(checkSocket())
        results.append(await checkRoundTrip())
        results.append(await checkNotifications())
        return results
    }

    private func checkSudoers() async -> CheckResult {
        let ok: Bool = await onBackground {
            if awakeHeld { return SudoersInstaller.isInstalled() }
            return Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"], timeout: 10).ok
        }
        return CheckResult(id: .sudoers, passed: ok,
                           detail: ok ? L("sudo -n pmset -a disablesleep 0 works without a password")
                                      : L("sudo would ask for a password. Install the sleep permission."),
                           fix: ok ? nil : .installSudoers)
    }

    private func checkHooks() -> CheckResult {
        let installer = HookInstaller(paths: paths)
        let events = installer.installedEvents()
        let missing = ClaudeSettingsMerger.events.filter { !events.contains($0) }
        let scriptOK = FileManager.default.isExecutableFile(atPath: paths.hookScript.path)
        if missing.isEmpty && scriptOK {
            return CheckResult(id: .hooks, passed: true, detail: L("All hooks are in settings.json and hook.sh is installed"), fix: nil)
        }
        let detail = scriptOK
            ? L("Missing hooks: %@", missing.map(\.rawValue).joined(separator: ", "))
            : L("hook.sh is not installed")
        return CheckResult(id: .hooks, passed: false, detail: detail, fix: .installHooks)
    }

    private func checkSocket() -> CheckResult {
        let ok = HookServer.probe(socketPath: paths.socket.path)
        return CheckResult(id: .socket, passed: ok,
                           detail: ok ? L("The socket is listening") : L("Nothing is listening on the socket"),
                           fix: ok ? nil : .restartServer)
    }

    private func checkRoundTrip() async -> CheckResult {
        let script = paths.hookScript.path
        guard FileManager.default.isExecutableFile(atPath: script) else {
            return CheckResult(id: .roundTrip, passed: false, detail: L("hook.sh is not installed"), fix: .installHooks)
        }
        let sessionID = "vigil-selftest-\(UUID().uuidString)"
        let payload = "{\"session_id\":\"\(sessionID)\",\"cwd\":\"/tmp\",\"hook_event_name\":\"VigilSelfTest\"}"
        let started = Date()
        let result: ShellResult = await onBackground {
            Shell.run("/bin/sh", [script, "VigilSelfTest"], stdin: payload,
                      environment: ["HOME": paths.home.path, "PATH": "/usr/bin:/bin", "VIGIL_SOCKET": paths.socket.path], timeout: 5)
        }
        let elapsed = Date().timeIntervalSince(started)
        let arrived = await probe.wait(for: sessionID, timeout: 3)
        let clean = result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty
        let ok = arrived && clean
        let detail: String
        if ok { detail = L("A fake hook event went through hook.sh to the app in %d ms", Int(elapsed * 1000)) }
        else if !clean { detail = L("hook.sh misbehaved (exit %d, output not empty)", Int(result.status)) }
        else { detail = L("The fake hook event did not arrive") }
        return CheckResult(id: .roundTrip, passed: ok, detail: detail, fix: ok ? nil : .restartServer)
    }

    private func checkNotifications() async -> CheckResult {
        let ok = await isNotificationAuthorized()
        return CheckResult(id: .notifications, passed: ok,
                           detail: ok ? L("Notifications are authorized") : L("Notifications are not authorized"),
                           fix: ok ? nil : .requestNotifications)
    }
}

/// Runs blocking work off the cooperative thread pool.
func onBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}
