import Foundation
import IOKit.pwr_mgt

public protocol PowerControlling: AnyObject, Sendable {
    /// `pmset -a disablesleep 1` + IOPM assertions. Throws if the privileged part failed
    /// (idle-sleep assertions are still held in that case).
    func acquireAwake() async throws
    /// `pmset -a disablesleep 0` + release assertions. Best effort, returns whether pmset succeeded.
    @discardableResult func releaseAwake() async -> Bool
    func sleepNow() async
    /// Current `SleepDisabled` value from `pmset -g`, nil if unknown.
    func sleepDisabled() -> Bool?
}

public enum PowerError: Error, CustomStringConvertible {
    case pmsetFailed(String)
    public var description: String {
        switch self { case .pmsetFailed(let m): return m }
    }
}

public func parseSleepDisabled(pmsetOutput: String) -> Bool? {
    for line in pmsetOutput.split(separator: "\n") where line.contains("SleepDisabled") {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if let last = fields.last { return last == "1" }
    }
    return nil
}

/// Real implementation: sudo -n pmset (needs the sudoers rule) + IOPMAssertions + crash watchdog.
public final class SystemPowerController: PowerControlling, @unchecked Sendable {
    private let paths: VigilPaths
    private let lock = NSLock()
    private var assertionIDs: [IOPMAssertionID] = []
    private let log = Log.shared

    public init(paths: VigilPaths = .standard) { self.paths = paths }

    public func acquireAwake() async throws {
        createAssertions()
        // Arm before flipping the setting: if we die in between, the watchdog restores.
        armWatchdog()
        let r = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"], timeout: 10)
        if r.ok {
            log.info("disablesleep 1 set")
        } else {
            disarmWatchdog()
            let message = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            log.error("disablesleep 1 failed (status \(r.status)): \(message)")
            throw PowerError.pmsetFailed(message.isEmpty ? "pmset failed (status \(r.status))" : message)
        }
    }

    @discardableResult
    public func releaseAwake() async -> Bool {
        releaseAssertions()
        let r = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"], timeout: 10)
        if r.ok {
            disarmWatchdog()
            log.info("disablesleep 0 restored")
        } else {
            log.error("disablesleep 0 FAILED (status \(r.status)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return r.ok
    }

    public func sleepNow() async {
        log.info("pmset sleepnow")
        Shell.run("/usr/bin/pmset", ["sleepnow"], timeout: 10)
    }

    public func sleepDisabled() -> Bool? {
        let r = Shell.run("/usr/bin/pmset", ["-g"], timeout: 5)
        return r.ok ? parseSleepDisabled(pmsetOutput: r.stdout) : nil
    }

    /// Synchronous restore for signal handlers / termination (the async API may not get to run).
    @discardableResult
    public func releaseAwakeBlocking() -> Bool {
        releaseAssertions()
        let r = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"], timeout: 8)
        if r.ok { disarmWatchdog() }
        return r.ok
    }

    // MARK: assertions

    private func createAssertions() {
        lock.lock(); defer { lock.unlock() }
        guard assertionIDs.isEmpty else { return }
        for type in ["PreventUserIdleSystemSleep", "PreventSystemSleep"] {
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Vigil: Claude Code is working" as CFString, &id)
            if rc == kIOReturnSuccess { assertionIDs.append(id) } else { log.warning("IOPMAssertion \(type) failed: \(rc)") }
        }
    }

    private func releaseAssertions() {
        lock.lock(); defer { lock.unlock() }
        for id in assertionIDs { IOPMAssertionRelease(id) }
        assertionIDs.removeAll()
    }

    // MARK: watchdog (restores disablesleep 0 if the app dies)

    private func armWatchdog() {
        try? paths.ensureSupportDir()
        FileManager.default.createFile(atPath: paths.watchdogArmFile.path, contents: Data())
        ensureWatchdogRunning()
    }

    private func disarmWatchdog() {
        try? FileManager.default.removeItem(at: paths.watchdogArmFile)
    }

    private func ensureWatchdogRunning() {
        if let text = try? String(contentsOf: paths.watchdogPidFile, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), PIDLiveness.systemIsAlive(pid) {
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        let script = Self.watchdogScript(appPID: me, appName: name, armFile: paths.watchdogArmFile.path)
        // The subshell is backgrounded so it is re-parented to launchd and survives our death (even SIGKILL).
        let launcher = "( \(script) ) </dev/null >/dev/null 2>&1 & echo $! > '\(paths.watchdogPidFile.path)'"
        Shell.run("/bin/sh", ["-c", launcher], timeout: 5)
        log.info("watchdog started for pid \(me)")
    }

    public static func watchdogScript(appPID: Int32, appName: String, armFile: String) -> String {
        let safeName = appName.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return """
        while [ "$(/bin/ps -p \(appPID) -o comm= 2>/dev/null | /usr/bin/grep -c '\(safeName)')" != "0" ]; do /bin/sleep 1; done; \
        if [ -e '\(armFile)' ]; then /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0; /bin/rm -f '\(armFile)'; fi
        """
    }
}

/// Dry run: logs what would happen and never touches pmset.
public final class DryRunPowerController: PowerControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var held = false
    private let log = Log.shared

    public init() {}

    public var recorded: [String] { lock.withLock { _log } }

    private func record(_ line: String) {
        lock.withLock { _log.append(line) }
        log.info("[dry-run] \(line)")
    }

    public func acquireAwake() async throws { record("would run: pmset -a disablesleep 1"); setHeld(true) }
    @discardableResult public func releaseAwake() async -> Bool { record("would run: pmset -a disablesleep 0"); setHeld(false); return true }
    public func sleepNow() async { record("would run: pmset sleepnow") }
    public func sleepDisabled() -> Bool? { lock.withLock { held } }

    private func setHeld(_ value: Bool) { lock.withLock { held = value } }
}
