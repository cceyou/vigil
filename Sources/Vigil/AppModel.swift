import AppKit
import Observation
import ServiceManagement
import SwiftUI
import VigilCore

enum Tab: String, CaseIterable, Identifiable {
    case overview, history, settings, selfTest
    var id: String { rawValue }
}

struct SetupStatus: Equatable {
    var sudoers = false
    var hooks = false
    /// Our hooks are in settings.json but from an older hook set (e.g. without the subagent hooks).
    var hooksOutdated = false
    var notifications = false
    var loginItem = false
    var socket = false

    var checklistComplete: Bool { sudoers && hooks && notifications && loginItem }
}

/// Owns the state machine and every side-effecting component. All mutation happens on the main actor;
/// power side effects are executed in order by `EffectExecutor`.
@MainActor
@Observable
final class AppModel {
    // MARK: observable state
    private(set) var machine: StateMachine
    private(set) var settings: AppSettings
    private(set) var history: [SessionRecord]
    private(set) var now = Date()
    private(set) var powerError: String?
    private(set) var setup = SetupStatus()
    private(set) var selfTestResults: [CheckResult] = []
    private(set) var selfTestRunning = false
    private(set) var busy: Set<String> = []
    private(set) var message: String?
    private(set) var hooksJustInstalled = false
    private(set) var dryRunLog: [String] = []
    /// Session rows whose subagent list is disclosed.
    var expandedSessions: Set<String> = []
    var tab: Tab = .overview

    // MARK: internals
    @ObservationIgnored let paths: VigilPaths
    @ObservationIgnored private let store = SettingsStore()
    @ObservationIgnored private let historyStore: HistoryStore
    @ObservationIgnored private let realPower: SystemPowerController
    @ObservationIgnored private let dryPower = DryRunPowerController()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let probe = SelfTestProbe()
    @ObservationIgnored private let monitor = BatteryThermalMonitor()
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var executor: EffectExecutor!
    @ObservationIgnored private var jobs: AsyncStream<Job>.Continuation!
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var signalSources: [DispatchSourceSignal] = []
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let log = Log.shared

    init(paths: VigilPaths = .standard) {
        self.paths = paths
        let loaded = store.load()
        self.settings = loaded
        self.machine = StateMachine(enabled: loaded.enabled, config: loaded.config)
        self.historyStore = HistoryStore(url: paths.history)
        self.history = historyStore.load()
        self.realPower = SystemPowerController(paths: paths)
    }

    // MARK: lifecycle

    func start() {
        log.info("Vigil starting (pid \(ProcessInfo.processInfo.processIdentifier))")
        try? paths.ensureSupportDir()
        signal(SIGPIPE, SIG_IGN)

        // Effect pipeline: one consumer, so effects run strictly in order.
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        jobs = continuation
        executor = EffectExecutor(
            power: settings.dryRun ? dryPower : realPower, notifier: Notifier.isAvailable ? notifier : nil,
            history: historyStore,
            onPowerError: { [weak self] error in DispatchQueue.main.async { MainActor.assumeIsolated { self?.powerError = error; self?.onChange?() } } },
            onHistory: { [weak self] list in DispatchQueue.main.async { MainActor.assumeIsolated { self?.history = list } } })
        let executor = self.executor!
        let grace = Int(settings.config.graceSeconds)
        Task.detached {
            await executor.setGrace(grace)
            for await job in stream { await executor.run(job) }
        }

        // Safety: a stuck SleepDisabled=1 from a previous crash is undone before anything else happens.
        jobs?.yield(.reconcile)

        notifier.setUp()
        notifier.onAction = { [weak self] action in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                switch action {
                case .cancel: self?.cancelCountdown()
                case .keepAwake: self?.keepAwake()
                }
            } }
        }

        // If macOS was never asked about notifications, ask now (the system prompt needs one click on Allow).
        Task { [notifier] in
            guard let state = await notifier.authorizationState() else { return }
            log.info("notifications: authorization state = \(state)")
            if state == "notDetermined" {
                NSApp.activate(ignoringOtherApps: true)
                _ = await notifier.requestAuthorization()
                refreshSetup()
            }
        }

        // Keep hook.sh current, and put it back if it vanished while the hooks are still in settings.json.
        healHookScript(alwaysRewrite: true)
        startServer()
        installSafetyNets()

        monitor.start { [weak self] env in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.send(.environment(env)) } }
        }

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }

        refreshSetup()
        onChange?()

        // Quiet self-test a moment after launch; the result is logged (and shown on the self-test screen).
        Task {
            try? await Task.sleep(for: .seconds(2))
            runSelfTest(showing: false)
        }
    }

    private func startServer() {
        server?.stop()
        let probe = self.probe
        let s = HookServer(socketPath: paths.socket.path) { [weak self] event in
            probe.received(event)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(event) } }
        }
        do {
            try s.start()
            server = s
            log.info("listening on \(paths.socket.path)")
        } catch {
            server = nil
            log.error("could not start hook server: \(error)")
            message = L("Could not open the hook socket: %@", "\(error)")
        }
    }

    /// Restore disablesleep on quit, SIGTERM/SIGINT/SIGHUP and logout/shutdown.
    private func installSafetyNets() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.log.info("received signal \(sig)")
                    self?.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    /// Synchronous restore; safe to call more than once.
    func shutdown() {
        timerTask?.cancel()
        monitor.stop()
        if !settings.dryRun, machine.awakeHeld || realPower.sleepDisabled() == true {
            let ok = realPower.releaseAwakeBlocking()
            log.info("shutdown restore: \(ok ? "ok" : "FAILED")")
        }
        server?.stop()
        try? FileManager.default.removeItem(at: paths.socket)
        log.flush()
    }

    // MARK: event plumbing

    func send(_ event: Event) {
        let effects = machine.handle(event, at: Date())
        if !effects.isEmpty { jobs?.yield(.effects(effects)) }
        now = Date()
        onChange?()
    }

    private func receive(_ event: HookEvent) {
        guard !SelfTest.isSelfTestEvent(event) else { return }
        let agent = event.agentID.map { " agent=\(event.agentType ?? "?")/\($0.prefix(8))" } ?? ""
        log.info("hook \(event.kind.rawValue) session=\(event.sessionID.prefix(8)) pid=\(event.pid.map(String.init) ?? "-")\(agent)")
        send(.hook(event))
    }

    private func tick() {
        tickCount += 1
        send(.tick)
        if tickCount % 10 == 0 { maintenance() }
        if settings.dryRun { dryRunLog = Array(dryPower.recorded.suffix(6)) }
    }

    /// Every 10 s: drop dead Claude processes (Ctrl+C fires no Stop) and undo any stuck disablesleep.
    private func maintenance() {
        let dead = PIDLiveness.deadSessions(in: machine.sessions)
        if !dead.isEmpty {
            log.info("dropping \(dead.count) dead session(s)")
            send(.sessionsDied(dead))
        }
        if !settings.dryRun { jobs?.yield(.reconcile) }
        if server?.isRunning != true { startServer() }
        healHookScript(alwaysRewrite: false)
    }

    /// settings.json points at hook.sh; if the file is gone every Claude Code hook would fail. Restore it.
    private func healHookScript(alwaysRewrite: Bool) {
        let installer = HookInstaller(paths: paths)
        let present = FileManager.default.isExecutableFile(atPath: paths.hookScript.path)
        if present && !alwaysRewrite { return }
        guard present || !installer.installedEvents().isEmpty else { return }
        do {
            try installer.installScript()
            if !present { log.warning("hook.sh was missing; restored it") }
        } catch {
            log.error("could not restore hook.sh: \(error)")
        }
    }

    // MARK: derived UI state

    var phase: Phase { machine.phase }
    var enabled: Bool { machine.enabled }

    var countdownRemaining: TimeInterval? {
        machine.countdownDeadline.map { max(0, $0.timeIntervalSince(now)) }
    }

    var keepAwakeRemaining: TimeInterval? {
        guard let until = machine.keepAwakeUntil, until > now else { return nil }
        return until.timeIntervalSince(now)
    }

    var workingSessions: [Session] { machine.workingSessions }

    /// How long the longest-running working session has been working.
    var workingElapsed: TimeInterval {
        workingSessions.compactMap { $0.workingSince.map { now.timeIntervalSince($0) } }.max() ?? 0
    }

    var activeSubagentCount: Int { machine.sessions.reduce(0) { $0 + $1.subagents.count } }

    /// Every main agent is done but subagents still run: the header shows that instead of a countdown.
    var onlySubagentsWorking: Bool {
        phase == .working && activeSubagentCount > 0 && !machine.sessions.contains { $0.state == .working }
    }

    var environment: VigilCore.Environment { machine.environment }

    /// Set when Claude wants the Mac awake but a guard refuses (the case that used to look like "armed").
    var pausedReason: GuardReason? {
        guard enabled, phase == .armed, !workingSessions.isEmpty || keepAwakeRemaining != nil else { return nil }
        return machine.blockedReason
    }

    var mood: Mood {
        if pausedReason != nil { return .paused }
        switch phase {
        case .off: return .off
        case .armed: return .armed
        case .working: return .working
        case .countdown: return .countdown
        }
    }

    /// 1 at the start of the countdown, 0 when it expires.
    var countdownProgress: Double {
        guard let r = countdownRemaining, settings.config.graceSeconds > 0 else { return 1 }
        return min(1, max(0, r / settings.config.graceSeconds))
    }

    var statusItemTitle: String? {
        if phase == .countdown, let r = countdownRemaining { return " " + Format.clock(r) }
        return nil
    }

    var iconName: String {
        if pausedReason != nil { return "bolt.slash" }
        switch phase {
        case .off: return "moon.zzz"
        case .armed: return "eye"
        case .working: return "bolt.fill"
        case .countdown: return "timer"
        }
    }

    // MARK: user actions

    func setEnabled(_ value: Bool) {
        update { $0.enabled = value }
        send(.setEnabled(value))
    }

    func toggle() { setEnabled(!enabled) }
    func sleepNow() { send(.sleepNow) }
    func keepAwake() { send(.keepAwake) }
    func cancelCountdown() { send(.cancelCountdown) }

    func update(_ mutate: (inout AppSettings) -> Void) {
        let old = settings
        mutate(&settings)
        store.save(settings)
        if settings.config != old.config {
            send(.configChanged(settings.config))
            let grace = Int(settings.config.graceSeconds)
            Task { [executor] in await executor?.setGrace(grace) }
        }
        if settings.dryRun != old.dryRun {
            jobs?.yield(.usePower(settings.dryRun ? dryPower : realPower))
            log.info("dry run \(settings.dryRun ? "on" : "off")")
        }
        onChange?()
    }

    func markOnboardingSeen() { update { $0.hasSeenOnboarding = true } }

    func clearHistory() {
        historyStore.clear()
        history = []
    }

    func dismissMessage() { message = nil }

    func openLog() {
        try? FileManager.default.createDirectory(at: paths.logDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: paths.logFile.path) {
            FileManager.default.createFile(atPath: paths.logFile.path, contents: Data())
        }
        NSWorkspace.shared.open(paths.logFile)
    }

    func quit() { NSApp.terminate(nil) }

    // MARK: setup (onboarding)

    func refreshSetup() {
        let paths = self.paths
        let notifier = self.notifier
        Task {
            let sudoers = await Self.background { SudoersInstaller.isInstalled() }
            let status = HookInstaller(paths: paths).hookStatus()
            let hooks = status == .current && FileManager.default.isExecutableFile(atPath: paths.hookScript.path)
            let notifications = await notifier.isAuthorized()
            self.setup = SetupStatus(sudoers: sudoers, hooks: hooks, hooksOutdated: status == .outdated,
                                     notifications: notifications,
                                     loginItem: SMAppService.mainApp.status == .enabled,
                                     socket: HookServer.probe(socketPath: paths.socket.path))
            self.onChange?()
        }
    }

    private static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) } }
    }

    private static func backgroundThrowing(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try work(); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    private func perform(_ key: String, success: String? = nil, _ work: @escaping @Sendable () throws -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            do {
                try await Self.backgroundThrowing(work)
                if let success { message = success }
            } catch {
                log.error("\(key) failed: \(error)")
                message = "\(error)"
            }
            refreshSetup()
        }
    }

    func installSudoers() {
        perform("sudoers", success: L("Sleep permission installed")) { try SudoersInstaller().install() }
    }

    func removeSudoers() {
        perform("sudoers", success: L("Sleep permission removed")) { try SudoersInstaller().remove() }
    }

    func installHooks() {
        let paths = self.paths
        perform("hooks", success: L("Hooks installed. Restart running Claude Code sessions so they load the new hooks.")) {
            try HookInstaller(paths: paths).installHooks()
        }
        hooksJustInstalled = true
    }

    /// Same merge as install: replaces only our entries (any version) and leaves everyone else's alone.
    func updateHooks() {
        let paths = self.paths
        perform("hooks", success: L("Hooks updated. Restart running Claude Code sessions so they load the new hooks.")) {
            try HookInstaller(paths: paths).installHooks()
        }
        hooksJustInstalled = true
    }

    func removeHooks() {
        let paths = self.paths
        perform("hooks", success: L("Hooks removed")) { try HookInstaller(paths: paths).removeHooks() }
        hooksJustInstalled = false
    }

    func requestNotifications() {
        Task {
            let granted = await notifier.requestAuthorization()
            if !granted { message = L("Notifications are off. Enable them in System Settings > Notifications > Vigil.") }
            refreshSetup()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("launch at login failed: \(error)")
            message = L("Could not change launch at login: %@", "\(error.localizedDescription)")
        }
        refreshSetup()
    }

    // MARK: self-test

    func runSelfTest(showing: Bool = true) {
        guard !selfTestRunning else { return }
        selfTestRunning = true
        if showing { tab = .selfTest }
        let test = SelfTest(paths: paths, probe: probe,
                            isNotificationAuthorized: { [notifier] in await notifier.isAuthorized() },
                            awakeHeld: machine.awakeHeld)
        Task {
            // hook.sh must exist for the round trip; installing the script alone does not touch settings.json.
            if !FileManager.default.isExecutableFile(atPath: paths.hookScript.path) { try? HookInstaller(paths: paths).installScript() }
            selfTestResults = await test.run()
            selfTestRunning = false
            let summary = selfTestResults.map { "\($0.id.rawValue)=\($0.passed ? "PASS" : "FAIL")" }.joined(separator: " ")
            log.info("self-test: \(summary)")
            for r in selfTestResults where !r.passed { log.warning("self-test \(r.id.rawValue): \(r.detail)") }
            refreshSetup()
        }
    }

    func fix(_ action: FixAction) {
        switch action {
        case .installSudoers: installSudoers()
        case .installHooks: installHooks()
        case .updateHooks: updateHooks()
        case .restartServer: startServer(); refreshSetup()
        case .requestNotifications: requestNotifications()
        }
    }

    // MARK: preview (snapshots)

    func previewInject(history: [SessionRecord], setup: SetupStatus, selfTest: [CheckResult]) {
        self.history = history
        self.setup = setup
        self.selfTestResults = selfTest
    }

    /// Builds a fresh state machine in the requested phase (snapshots only; no side effects are executed).
    func previewSessions(phase: Phase) {
        var m = StateMachine(enabled: phase != .off, config: settings.config)
        let t = Date().addingTimeInterval(-754)
        func hook(_ kind: HookKind, _ id: String, _ cwd: String, agent: String? = nil, type: String? = nil) -> Event {
            .hook(HookEvent(kind: kind, sessionID: id, cwd: cwd, agentID: agent, agentType: type))
        }
        switch phase {
        case .working:
            _ = m.handle(hook(.userPromptSubmit, "a", "/Users/me/Projects/alwayson"), at: t)
            _ = m.handle(hook(.subagentStart, "a", "/Users/me/Projects/alwayson", agent: "x1", type: "Explore"), at: t.addingTimeInterval(60))
            _ = m.handle(hook(.subagentStart, "a", "/Users/me/Projects/alwayson", agent: "x2", type: "code-reviewer"), at: t.addingTimeInterval(90))
            _ = m.handle(hook(.userPromptSubmit, "b", "/Users/me/Projects/website"), at: t.addingTimeInterval(300))
            _ = m.handle(hook(.notification, "b", "/Users/me/Projects/website"), at: t.addingTimeInterval(500))
            _ = m.handle(hook(.userPromptSubmit, "c", "/Users/me/Projects/dotfiles"), at: t.addingTimeInterval(20))
            _ = m.handle(hook(.stop, "c", "/Users/me/Projects/dotfiles"), at: t.addingTimeInterval(400))
        case .countdown:
            _ = m.handle(hook(.userPromptSubmit, "a", "/Users/me/Projects/alwayson"), at: t)
            _ = m.handle(hook(.stop, "a", "/Users/me/Projects/alwayson"), at: Date().addingTimeInterval(-6))
        case .armed:
            _ = m.handle(hook(.sessionStart, "a", "/Users/me/Projects/alwayson"), at: t)
        case .off:
            break
        }
        machine = m
        now = Date()
    }

    /// Snapshot state: the main agent has finished, two subagents are still running.
    func previewSubagentsOnly() {
        var m = StateMachine(enabled: true, config: settings.config)
        let t = Date().addingTimeInterval(-760)
        let cwd = "/Users/me/Projects/rasinova-residence"
        _ = m.handle(.hook(HookEvent(kind: .userPromptSubmit, sessionID: "a", cwd: cwd)), at: t.addingTimeInterval(-120))
        _ = m.handle(.hook(HookEvent(kind: .subagentStart, sessionID: "a", cwd: cwd, agentID: "x1", agentType: "Explore")), at: t)
        _ = m.handle(.hook(HookEvent(kind: .subagentStart, sessionID: "a", cwd: cwd, agentID: "x2", agentType: "code-reviewer")), at: t.addingTimeInterval(30))
        _ = m.handle(.hook(HookEvent(kind: .stop, sessionID: "a", cwd: cwd)), at: t.addingTimeInterval(45))
        machine = m
        now = Date()
    }

    /// Snapshot state: Claude working, lid closed, battery under the threshold.
    func previewPaused() {
        var m = StateMachine(enabled: true, config: settings.config)
        let t = Date().addingTimeInterval(-754)
        _ = m.handle(.environment(VigilCore.Environment(lidClosed: true, onBattery: true, batteryPercent: 3)), at: t)
        _ = m.handle(.hook(HookEvent(kind: .userPromptSubmit, sessionID: "a", cwd: "/Users/me/Projects/alwayson")), at: t)
        machine = m
        now = Date()
    }

    // MARK: dry run

    /// Feeds a fake session through the real state machine (only useful with dry run on): the main agent
    /// stops while a subagent keeps working, so the countdown only starts when the subagent finishes.
    func simulateSession() {
        let id = "dry-run-\(UUID().uuidString.prefix(6))"
        let agent = "dry-run-agent-\(UUID().uuidString.prefix(6))"
        func hook(_ kind: HookKind) -> Event {
            .hook(HookEvent(kind: kind, sessionID: id, cwd: "/dry-run/demo", agentID: agent, agentType: "Explore"))
        }
        send(hook(.sessionStart))
        send(hook(.userPromptSubmit))
        Task {
            try? await Task.sleep(for: .seconds(2))
            send(hook(.subagentStart))
            try? await Task.sleep(for: .seconds(2))
            send(hook(.stop))
            try? await Task.sleep(for: .seconds(4))
            send(hook(.subagentStop))
            try? await Task.sleep(for: .seconds(1))
            send(hook(.sessionEnd))
        }
    }
}

enum Format {
    /// 754 -> "12:34", 3723 -> "1:02:03"
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "1 subagent", "3 subagents" (Czech: 1 subagent, 2-4 subagenti, 5+ subagentů).
    static func subagents(_ n: Int) -> String {
        if n == 1 { return L("1 subagent") }
        if (2...4).contains(n) { return L("%d subagents (2-4)", n) }
        return L("%d subagents", n)
    }

    /// "Explore ×2, code-reviewer", in start order.
    static func agentTypes(_ agents: [Subagent]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for a in agents {
            if counts[a.type] == nil { order.append(a.type) }
            counts[a.type, default: 0] += 1
        }
        return order.map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }.joined(separator: ", ")
    }
}
