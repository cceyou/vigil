import AppKit
import Observation
import ServiceManagement
import SwiftUI
import VigilCore

/// The small windows opened from the popover's "…" menu.
enum AuxWindow: String, CaseIterable {
    case history, settings, selfTest
}

/// What the island at the top of the popover (and the menu bar icon) shows, by priority.
enum IslandState: Equatable {
    case countdown(TimeInterval)
    /// Elapsed time, plus the estimate when the island is set to show it.
    case working(TimeInterval, eta: SessionEta? = nil)
    case waiting
    /// Claude finished, the sleep gate said no (someone is at the Mac): Vigil let go, macOS sleeps on its own.
    case handedBack
    case idle
    case off
    /// Claude wants the Mac awake but a guard (battery, heat, time limit, manual sleep) refuses.
    case paused(GuardReason)

    var kind: String {
        switch self {
        case .countdown: return "countdown"
        case .working: return "working"
        case .waiting: return "waiting"
        case .handedBack: return "handedBack"
        case .idle: return "idle"
        case .off: return "off"
        case .paused: return "paused"
        }
    }
}

struct SetupStatus: Equatable {
    var sudoers = false
    var hooks = false
    /// Our hooks are in settings.json but from an older hook set (e.g. without the subagent or PermissionRequest hooks).
    var hooksOutdated = false
    var notifications = false
    var loginItem = false
    var socket = false
    /// statusline.sh installed and referenced from settings.json (Claude usage data).
    var statusLine = false

    var checklistComplete: Bool { sudoers && hooks && notifications && loginItem && statusLine }
    var doneCount: Int { [sudoers, hooks, notifications, loginItem, statusLine].filter { $0 }.count }
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
    private(set) var usage: UsageState
    /// Work-time estimate per running turn (information only; the state machine never sees it).
    private(set) var tracker = TurnTracker()
    /// Finished turns, newest first: what the estimate learns from and is scored against.
    private(set) var turns: [TurnRecord]
    /// Every sleep and skip the sleep gate decided, newest first.
    private(set) var sleepDecisions: [SleepDecisionRecord]
    /// Index of the working-session page shown in the popover.
    var sessionPage: String?
    /// History window tab: sessions or estimate accuracy.
    var historyTab = HistoryTab.sessions

    // MARK: internals
    @ObservationIgnored let paths: VigilPaths
    @ObservationIgnored private let store = SettingsStore()
    @ObservationIgnored private let historyStore: HistoryStore
    @ObservationIgnored private let usageStore: UsageStore
    @ObservationIgnored private let turnStore: TurnStore
    @ObservationIgnored private let decisionStore: SleepDecisionStore
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
    @ObservationIgnored var onOpenWindow: ((AuxWindow) -> Void)?
    /// The edge notch's self-test line (set by the app delegate, which owns the notch controller).
    @ObservationIgnored var notchStatus: (() -> (detail: String, healthy: Bool))?
    /// Settings that the notch / hotkey controllers care about changed.
    @ObservationIgnored var onUISettingsChange: (() -> Void)?
    @ObservationIgnored private let log = Log.shared

    init(paths: VigilPaths = .standard) {
        self.paths = paths
        let loaded = store.load()
        self.settings = loaded
        self.machine = StateMachine(enabled: loaded.enabled, config: loaded.config)
        self.historyStore = HistoryStore(url: paths.history)
        self.history = historyStore.load()
        self.usageStore = UsageStore(url: paths.usage)
        self.usage = usageStore.load()
        self.turnStore = TurnStore(url: paths.turns)
        self.turns = turnStore.load()
        self.decisionStore = SleepDecisionStore(url: paths.sleepDecisions)
        self.sleepDecisions = decisionStore.load()
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
            onHistory: { [weak self] list in DispatchQueue.main.async { MainActor.assumeIsolated { self?.history = list } } },
            decisions: decisionStore,
            onDecisions: { [weak self] list in DispatchQueue.main.async { MainActor.assumeIsolated { self?.sleepDecisions = list } } })
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
        healStatusLineScript(alwaysRewrite: true)
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
        let s = HookServer(socketPath: paths.socket.path, onStatusLine: { [weak self] snapshot in
            probe.received(snapshot)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(snapshot) } }
        }) { [weak self] event in
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
        // The gate decides with what is true right now, not with a reading cached seconds ago.
        refreshPresence()
        let tasks = event.taskSignals.isEmpty ? "" : " tasks=\(event.taskSignals.count)"
        log.info("hook \(event.kind.rawValue) session=\(event.sessionID.prefix(8)) pid=\(event.pid.map(String.init) ?? "-")\(agent)\(tasks)")
        send(.hook(event))
        // The estimate follows the same events but is kept apart from the state machine on purpose.
        if let record = tracker.handle(event, at: Date()) {
            turns = turnStore.append(record)
            log.info("turn finished: \(record.project) \(Int(record.activeDuration)) s active, \(record.taskCount) tasks, "
                     + "\(record.subagentCount) subagents, \(record.checkpoints.count) checkpoints")
        }
    }

    /// A status line update from statusline.sh (self-test ones only go to the probe).
    private func receive(_ snapshot: StatusLineSnapshot) {
        guard !snapshot.sessionID.hasPrefix(SelfTest.sessionPrefix) else { return }
        let hadLimits = usage.hasRateLimits
        let alerts = usage.apply(snapshot, at: Date())
        usageStore.save(usage)
        if !hadLimits && usage.hasRateLimits { log.info("usage: first rate_limits received") }
        post(alerts)
    }

    /// Lid, displays, input idle time and assertions, read fresh (a few milliseconds). Only the state machine's
    /// sleep gate uses it; it is sent every second and before every hook event.
    private func refreshPresence() {
        let effects = machine.handle(.presence(PresenceReader.snapshot()), at: Date())
        if !effects.isEmpty { jobs?.yield(.effects(effects)) }
    }

    private func postEtaNotifications() {
        for due in etaNotificationsDue() where tracker.markNotified(due.sessionID) {
            log.info("eta notification: \(due.project) \(due.text)")
            notifier.postEta(project: due.project, remaining: due.text)
        }
    }

    private func post(_ alerts: [UsageAlert]) {
        for alert in alerts {
            log.info("usage alert: \(alert)")
            guard settings.ui.usageNotifications else { continue }
            let resetsAt: Date? = {
                if case .threshold(let kind, _) = alert { return usage.window(kind)?.resetsAt }
                return nil
            }()
            notifier.postUsage(alert, resetsAt: resetsAt)
        }
    }

    private func tick() {
        tickCount += 1
        refreshPresence()
        send(.tick)
        tracker.tick(at: Date(), history: turns)
        postEtaNotifications()
        let rolled = usage.rollover(at: Date())
        if !rolled.isEmpty { usageStore.save(usage); post(rolled) }
        if tickCount % 10 == 0 { maintenance() }
        if settings.dryRun { dryRunLog = Array(dryPower.recorded.suffix(6)) }
    }

    /// Every 10 s: drop dead Claude processes (Ctrl+C fires no Stop) and undo any stuck disablesleep.
    private func maintenance() {
        let dead = PIDLiveness.deadSessions(in: machine.sessions)
        if !dead.isEmpty {
            log.info("dropping \(dead.count) dead session(s)")
            send(.sessionsDied(dead))
            tracker.discard(dead)
        }
        if !settings.dryRun { jobs?.yield(.reconcile) }
        if server?.isRunning != true { startServer() }
        healHookScript(alwaysRewrite: false)
        healStatusLineScript(alwaysRewrite: false)
    }

    /// settings.json points at statusline.sh; if it is gone Claude Code shows no status line. Restore it.
    private func healStatusLineScript(alwaysRewrite: Bool) {
        let present = FileManager.default.isExecutableFile(atPath: paths.statusLineScript.path)
        if present && !alwaysRewrite { return }
        let installer = StatusLineInstaller(paths: paths)
        guard installer.status() == .installed else { return }
        do {
            try installer.installScript()
            if !present { log.warning("statusline.sh was missing; restored it") }
        } catch {
            log.error("could not restore statusline.sh: \(error)")
        }
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

    var accent: Color { Theme.accent(settings.ui.accent) }

    /// Sessions waiting for the user (a permission prompt or a question), most recent first.
    var waitingSessions: [Session] {
        machine.sessions.filter { $0.state == .waiting && $0.subagents.isEmpty }.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    /// Working sessions for the paged card stack, most recently active first.
    var workingByActivity: [Session] { workingSessions.sorted { $0.lastEventAt > $1.lastEventAt } }

    /// The session the main card shows when at most one is working: the most recently active one.
    var primarySession: Session? {
        workingByActivity.first ?? machine.sessions.max { $0.lastEventAt < $1.lastEventAt }
    }

    /// Waiting for an answer outranks "working": the Mac stays awake for it (default policy), but the user
    /// has to act. Only an imminent sleep (countdown), a guard or "off" rank higher.
    var island: IslandState {
        if let reason = pausedReason { return .paused(reason) }
        switch phase {
        case .off: return .off
        case .countdown: return .countdown(countdownRemaining ?? 0)
        case .working:
            if !waitingSessions.isEmpty { return .waiting }
            return .working(workingSessions.isEmpty ? awakeElapsed : workingElapsed, eta: islandEta)
        case .armed:
            if !waitingSessions.isEmpty { return .waiting }
            if let h = machine.handedBack, now.timeIntervalSince(h.date) < Self.handedBackDisplay { return .handedBack }
            return .idle
        }
    }

    /// How long "Hotovo · Mac běží normálně" stays up after Vigil handed sleep back to macOS.
    static let handedBackDisplay: TimeInterval = 15 * 60

    /// How long the Mac has been held awake (the "keep awake 1 h" case has no working session).
    var awakeElapsed: TimeInterval { machine.awakeSince.map { now.timeIntervalSince($0) } ?? 0 }

    /// 1 at the start of the countdown, 0 when it expires.
    var countdownProgress: Double {
        guard let r = countdownRemaining, settings.config.graceSeconds > 0 else { return 1 }
        return min(1, max(0, r / settings.config.graceSeconds))
    }

    /// Progress toward sleep for the track: nil means indeterminate (Claude works, no timer running).
    var sleepProgress: Double? {
        if phase == .countdown { return 1 - countdownProgress }
        if let r = keepAwakeRemaining, settings.config.manualKeepAwake > 0 {
            return min(1, max(0, 1 - r / settings.config.manualKeepAwake))
        }
        return phase == .working ? nil : 0
    }

    /// How much longer Vigil keeps the Mac awake at most: the manual hour, or the max keep-awake failsafe.
    var awakeRemaining: TimeInterval? {
        guard machine.awakeHeld else { return nil }
        let failsafe = machine.awakeSince.map { max(0, settings.config.maxKeepAwake - now.timeIntervalSince($0)) }
        return [keepAwakeRemaining, failsafe].compactMap { $0 }.min()
    }

    var statusItemTitle: String? {
        if phase == .countdown, let r = countdownRemaining { return " " + Format.clock(r) }
        return nil
    }

    /// Menu bar icon: mirrors the island (bolt / moon / exclamation mark).
    var iconName: String {
        switch island {
        case .working: return "bolt.fill"
        case .countdown: return "moon.fill"
        case .waiting: return "exclamationmark"
        case .handedBack: return "checkmark"
        case .idle: return "bolt"
        case .off: return "moon.zzz"
        case .paused: return "bolt.slash"
        }
    }

    // MARK: usage

    /// Claude usage as the card should show it right now (resets applied).
    func usageWindow(_ kind: UsageWindowKind) -> EffectiveWindow? { usage.effective(kind, at: now) }

    /// Up to three sessions for the usage card: running sessions first, then recent status lines.
    var usageSessions: [UsageCardSession] {
        var list: [UsageCardSession] = []
        var seen = Set<String>()
        for s in machine.sessions.sorted(by: { $0.lastEventAt > $1.lastEventAt }) {
            let info = usage.sessions[s.id]
            let eta = eta(for: s.id)
            list.append(UsageCardSession(id: s.id, project: s.projectName, model: info?.model,
                                         contextPercent: info?.contextPercent, working: s.isWorking,
                                         step: eta?.step.flatMap { step in eta?.total.map { "\(step)/\($0)" } },
                                         eta: eta?.remainingText, etaConfident: eta?.confident ?? false))
            seen.insert(s.id)
        }
        for (id, info) in usage.recentSessions(at: now, within: 600) where !seen.contains(id) {
            list.append(UsageCardSession(id: id, project: info.projectName, model: info.model,
                                         contextPercent: info.contextPercent, working: false))
        }
        return Array(list.prefix(3))
    }

    // MARK: windows and apps

    func open(_ window: AuxWindow) { onOpenWindow?(window) }

    /// Brings the terminal app that runs `session` to the front: walks up from the Claude PID to the first process
    /// that is a regular app. Falls back to the Claude app.
    func openApp(for session: Session) {
        if let pid = session.pid {
            for p in ProcessTree.ancestry(of: pid) {
                if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                    log.info("open: activating \(app.localizedName ?? "?") (pid \(p)) for \(session.projectName)")
                    app.activate()
                    return
                }
            }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            message = L("Could not find the app running this session.")
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
        if settings.ui != old.ui { onUISettingsChange?() }
        onChange?()
    }

    func markOnboardingSeen() { update { $0.hasSeenOnboarding = true } }

    func clearEtaHistory() {
        turnStore.clear()
        turns = []
    }

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
                                     socket: HookServer.probe(socketPath: paths.socket.path),
                                     statusLine: StatusLineInstaller(paths: paths).isInstalled)
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

    func installStatusLine() {
        let paths = self.paths
        perform("statusLine", success: L("Status line installed. Claude usage appears after the next response in Claude Code.")) {
            try StatusLineInstaller(paths: paths).install()
        }
    }

    func removeStatusLine() {
        let paths = self.paths
        perform("statusLine", success: L("Status line removed. Your previous status line is back.")) {
            try StatusLineInstaller(paths: paths).remove()
        }
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
        if showing { open(.selfTest) }
        let test = SelfTest(paths: paths, probe: probe,
                            isNotificationAuthorized: { [notifier] in await notifier.isAuthorized() },
                            awakeHeld: machine.awakeHeld, lidOpenIdleSleep: settings.config.lidOpenIdleSleep,
                            notchReport: notchStatus?())
        Task {
            // hook.sh must exist for the round trip; installing the script alone does not touch settings.json.
            if !FileManager.default.isExecutableFile(atPath: paths.hookScript.path) { try? HookInstaller(paths: paths).installScript() }
            selfTestResults = await test.run()
            selfTestRunning = false
            let summary = selfTestResults.map { "\($0.id.rawValue)=\($0.passed ? "PASS" : "FAIL")" }.joined(separator: " ")
            log.info("self-test: \(summary)")
            for r in selfTestResults where !r.passed { log.warning("self-test \(r.id.rawValue): \(r.detail)") }
            for id in [CheckID.sleepGate, .notch] {
                if let r = selfTestResults.first(where: { $0.id == id }) {
                    log.info("self-test \(id.rawValue): \(r.detail.replacingOccurrences(of: "\n", with: " → "))")
                }
            }
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
        case .installStatusLine: installStatusLine()
        }
    }

    // MARK: preview (snapshots)

    func previewInject(history: [SessionRecord], setup: SetupStatus, selfTest: [CheckResult], usage: UsageState? = nil) {
        self.history = history
        self.setup = setup
        self.selfTestResults = selfTest
        if let usage { self.usage = usage }
    }

    /// Snapshots only: replaces the state machine with one built by `build`.
    func previewMachine(_ build: (inout StateMachine) -> Void) {
        var m = StateMachine(enabled: true, config: settings.config, presence: .away)
        build(&m)
        machine = m
        now = Date()
    }

    func previewSettings(_ mutate: (inout AppSettings) -> Void) { mutate(&settings) }

    /// Snapshots only: replaces the estimate history and replays hook events through a fresh tracker.
    func previewEta(turns: [TurnRecord], events: [(HookEvent, Date)], at time: Date) {
        self.turns = turns
        var t = TurnTracker()
        for (event, date) in events.sorted(by: { $0.1 < $1.1 }) {
            _ = t.handle(event, at: date)
            t.tick(at: date, history: turns)
        }
        t.tick(at: time, history: turns)
        tracker = t
        now = time
    }

    /// Builds a fresh state machine in the requested phase (snapshots only; no side effects are executed).
    func previewSessions(phase: Phase) {
        var m = StateMachine(enabled: phase != .off, config: settings.config, presence: .away)
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
            _ = m.handle(hook(.permissionRequest, "b", "/Users/me/Projects/website"), at: t.addingTimeInterval(500))
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
        var m = StateMachine(enabled: true, config: settings.config, presence: .away)
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
        var m = StateMachine(enabled: true, config: settings.config, presence: .away)
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

    /// "1 subagent", "3 subagents" (Czech: 1 subagent, 2-4 subagenti, 0 and 5+ subagentů).
    static func subagents(_ n: Int) -> String {
        switch PluralCategory.czech(n) {
        case .one: return L("1 subagent")
        case .few: return L("%d subagents (2-4)", n)
        case .many: return L("%d subagents", n)
        }
    }

    /// "Main agent + 2 subagents"; just "Main agent" without subagents.
    static func agents(_ subagentCount: Int) -> String {
        subagentCount == 0 ? L("Main agent") : L("Main agent + %@", subagents(subagentCount))
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
