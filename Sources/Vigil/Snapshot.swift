import AppKit
import SwiftUI
import VigilCore

/// `Vigil --snapshot <dir>` renders the popover, the usage card and the small windows offscreen into PNGs
/// (no screen-recording permission needed). Never starts the socket server, timers or any power handling.
///
/// Every state is rendered in light, dark and with Reduce Transparency (`vigilForceSolid`), as
/// `popover-<state>-<variant>.png`, `card-<state>-<variant>.png` and `compare-<state>-<variant>.png` (both side by side).
@MainActor
enum Snapshot {
    enum Variant: String, CaseIterable { case light, dark, solid }

    static func run(into directory: String, then finish: @escaping () -> Void) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = AppModel()
        model.loadPreviewData()
        let card = UsageCardState()
        card.shown = true

        let backdrop = LinearGradient(colors: [Color(hex: 0x2B5876), Color(hex: 0x4E4376), Color(hex: 0xC06C84)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        // The real popover gets its glass from NSPopover; here the same surface is drawn around it.
        let popover = { AnyView(PopoverView(model: model).glassSurface()) }
        let usageCard = { AnyView(UsageCardView(model: model, state: card)) }

        struct State { let name: String; let apply: (AppModel) -> Void }
        let states: [State] = [
            State(name: "working-tasks") { $0.previewScenario(.etaTasks); $0.previewUsage(.data) },
            State(name: "working-no-tasklist") { $0.previewScenario(.etaHistory); $0.previewUsage(.data) },
            State(name: "working-no-estimate") { $0.previewScenario(.working); $0.previewUsage(.data) },
            State(name: "waiting") { $0.previewScenario(.waiting); $0.previewUsage(.data) },
            State(name: "countdown") { $0.previewScenario(.countdown); $0.previewUsage(.data) },
            State(name: "idle") { $0.previewScenario(.idle); $0.previewUsage(.data) },
            State(name: "multi") { $0.previewScenario(.multi); $0.previewUsage(.data) },
            State(name: "shell") { $0.previewScenario(.shell); $0.previewUsage(.data) },
            State(name: "keep-awake") { $0.previewScenario(.keepAwake); $0.previewUsage(.data) },
            State(name: "keep-awake-forever") { $0.previewScenario(.keepAwakeForever); $0.previewUsage(.data) },
        ]

        func render(_ view: AnyView, _ variant: Variant, size: NSSize? = nil, padded: Bool = true, to name: String) async {
            let scheme: ColorScheme = variant == .light ? .light : .dark
            let root = Group {
                if padded { view.padding(32).background(backdrop) } else { view }
            }
            .environment(\.colorScheme, scheme)
            .environment(\.vigilForceSolid, variant == .solid)
            .environment(\.vigilSnapshot, true)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = "\(directory)/\(name).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }

        Task {
            for state in states {
                state.apply(model)
                try? await Task.sleep(for: .milliseconds(150))
                for variant in Variant.allCases {
                    let suffix = "\(state.name)-\(variant.rawValue)"
                    await render(popover(), variant, to: "popover-\(suffix)")
                    await render(usageCard(), variant, to: "card-\(suffix)")
                    let pair = AnyView(HStack(alignment: .top, spacing: 32) { popover(); usageCard() })
                    await render(pair, variant, to: "compare-\(suffix)")
                }
            }
            let windows: [(String, AuxWindow, (AppModel) -> Void)] = [
                ("window-settings", .settings, { $0.previewScenario(.working) }),
                ("window-history", .history, { $0.previewScenario(.working); $0.historyTab = .sessions }),
                ("window-history-accuracy", .history, { $0.previewScenario(.etaTasks); $0.historyTab = .accuracy }),
                ("window-selftest", .selfTest, { $0.previewScenario(.working) }),
            ]
            for (name, kind, apply) in windows {
                apply(model)
                for variant in [Variant.light, .dark] {
                    let view = AnyView(AuxWindowRoot(model: model, kind: kind).background(Color(nsColor: .windowBackgroundColor)))
                    await render(view, variant, size: NSSize(width: kind == .history ? 640 : 520, height: 680), padded: false,
                                 to: "\(name)-\(variant.rawValue)")
                }
            }
            finish()
        }
    }
}

enum PreviewScenario { case working, multi, waiting, countdown, keepAwake, keepAwakeForever, shell, idle, idleSetup, etaTasks, etaHistory }
enum PreviewUsage { case data, critical, stale, empty, noLimits }

extension AppModel {
    /// Sample data for snapshots only.
    func loadPreviewData() {
        previewInject(history: [
            SessionRecord(id: "1", project: "alwayson", startedAt: Date().addingTimeInterval(-3600), duration: 1834, reason: .ended,
                          maxSubagents: 3, subagentTime: 2710),
            SessionRecord(id: "2", project: "website", startedAt: Date().addingTimeInterval(-9000), duration: 412, reason: .interrupted),
            SessionRecord(id: "3", project: "dotfiles", startedAt: Date().addingTimeInterval(-90000), duration: 28800, reason: .timedOut),
        ], setup: SetupStatus(sudoers: true, hooks: true, notifications: true, loginItem: true, socket: true, statusLine: true),
        selfTest: [
            CheckResult(id: .sudoers, passed: true, detail: "sudo -n pmset -a disablesleep 0 works without a password", fix: nil),
            CheckResult(id: .hooks, passed: true, detail: "All hooks are in settings.json and hook.sh is installed", fix: nil),
            CheckResult(id: .socket, passed: true, detail: "The socket is listening", fix: nil),
            CheckResult(id: .roundTrip, passed: true, detail: "A fake hook event went through hook.sh to the app in 41 ms", fix: nil),
            CheckResult(id: .subagents, passed: true, detail: "A fake SubagentStart and SubagentStop took a session from working to idle", fix: nil),
            CheckResult(id: .statusLine, passed: true, detail: "Installed, and a fake status line reached Vigil in 23 ms", fix: nil),
            CheckResult(id: .notifications, passed: false, detail: "Notifications are not authorized", fix: .requestNotifications),
        ])
    }

    func previewScenario(_ scenario: PreviewScenario) {
        let now = Date()
        func hook(_ kind: HookKind, _ id: String, _ project: String, agent: String? = nil, type: String? = nil,
                  cwd: String? = nil) -> Event {
            .hook(HookEvent(kind: kind, sessionID: id, cwd: cwd ?? "/Users/me/Projects/\(project)", pid: 1, agentID: agent, agentType: type))
        }
        let env = VigilCore.Environment(lidClosed: false, onBattery: false, batteryPercent: 87, thermal: .nominal, isCharging: true)
        var setup = SetupStatus(sudoers: true, hooks: true, notifications: true, loginItem: true, socket: true, statusLine: true)
        previewMachine { m in
            _ = m.handle(.environment(env), at: now.addingTimeInterval(-5000))
            switch scenario {
            case .working:
                _ = m.handle(hook(.userPromptSubmit, "a", "alwayson"), at: now.addingTimeInterval(-4008))
                _ = m.handle(hook(.subagentStart, "a", "alwayson", agent: "x1", type: "Explore"), at: now.addingTimeInterval(-300))
                _ = m.handle(hook(.subagentStart, "a", "alwayson", agent: "x2", type: "code-reviewer"), at: now.addingTimeInterval(-200))
                _ = m.handle(.keepAwake(.minutes(60)), at: now.addingTimeInterval(-5))
            case .multi:
                // a works (with usage data), b works in the home folder with a subagent, c finished and has no
                // status line data yet.
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                _ = m.handle(hook(.userPromptSubmit, "a", "alwayson"), at: now.addingTimeInterval(-4008))
                _ = m.handle(hook(.userPromptSubmit, "b", "home", cwd: home), at: now.addingTimeInterval(-900))
                _ = m.handle(hook(.subagentStart, "b", "home", agent: "y1", type: "Explore", cwd: home), at: now.addingTimeInterval(-60))
                _ = m.handle(hook(.userPromptSubmit, "c", "rasinova-residence-booking-calendar-v2"), at: now.addingTimeInterval(-720))
                _ = m.handle(hook(.stop, "c", "rasinova-residence-booking-calendar-v2"), at: now.addingTimeInterval(-90))
            case .waiting:
                _ = m.handle(hook(.userPromptSubmit, "a", "alwayson"), at: now.addingTimeInterval(-1500))
                _ = m.handle(.hook(HookEvent(kind: .notification, sessionID: "a", cwd: "/Users/me/Projects/alwayson", pid: 1,
                                             notificationType: "permission_prompt")), at: now.addingTimeInterval(-40))
            case .countdown:
                _ = m.handle(hook(.userPromptSubmit, "a", "alwayson"), at: now.addingTimeInterval(-900))
                _ = m.handle(hook(.stop, "a", "alwayson"), at: now.addingTimeInterval(-6))
            case .keepAwake:
                _ = m.handle(.keepAwake(.minutes(120)), at: now.addingTimeInterval(-60))
            case .keepAwakeForever:
                _ = m.handle(.keepAwake(.untilCancelled), at: now.addingTimeInterval(-60))
            case .shell:
                // Claude finished; its test run keeps going in the background.
                _ = m.handle(hook(.userPromptSubmit, "a", "alwayson"), at: now.addingTimeInterval(-600))
                _ = m.handle(.hook(HookEvent(kind: .stop, sessionID: "a", cwd: "/Users/me/Projects/alwayson", pid: 1,
                                             backgroundTasks: [ReportedTask(id: "b1", kind: .shell, command: "npm test")])),
                             at: now.addingTimeInterval(-200))
            case .idle:
                break
            case .idleSetup:
                setup = SetupStatus(sudoers: true, hooks: true, notifications: false, loginItem: true, socket: true, statusLine: false)
            case .etaTasks:
                for e in Self.etaEvents(now: now) { _ = m.handle(.hook(e.0), at: e.1) }
                _ = m.handle(.keepAwake(.minutes(60)), at: now.addingTimeInterval(-1044))
            case .etaHistory:
                for e in Self.etaEvents(now: now) where e.0.sessionID == "b" { _ = m.handle(.hook(e.0), at: e.1) }
                _ = m.handle(.keepAwake(.minutes(60)), at: now.addingTimeInterval(-1044))
            }
        }
        previewInject(history: history, setup: setup, selfTest: selfTestResults)
        let events: [(HookEvent, Date)]
        switch scenario {
        case .etaTasks: events = Self.etaEvents(now: now)
        case .etaHistory: events = Self.etaEvents(now: now).filter { $0.0.sessionID == "b" }
        default: events = []
        }
        previewEta(turns: Self.sampleTurns(now: now), events: events, at: now)
        selectedSessionID = scenario == .etaTasks ? "a" : nil
    }

    /// Session "a" (rasinova-residence) works through a 7-step task list with two subagents; session "b" (code)
    /// has no task list, so its estimate comes from history.
    static func etaEvents(now: Date) -> [(HookEvent, Date)] {
        let a = "/Users/me/Projects/rasinova-residence", b = "/Users/me/Projects/code"
        func ev(_ kind: HookKind, _ id: String, _ cwd: String, _ t: TimeInterval, signals: [TaskSignal] = [],
                agent: String? = nil, type: String? = nil) -> (HookEvent, Date) {
            (HookEvent(kind: kind, sessionID: id, cwd: cwd, pid: 1, agentID: agent, agentType: type, taskSignals: signals),
             now.addingTimeInterval(t))
        }
        let subjects = ["Načíst stávající formulář rezervace", "Sjednotit model termínů", "Upravit API pro dostupnost",
                        "Přidat validaci termínů do formuláře", "Doplnit chybové hlášky", "Napsat testy validace",
                        "Aktualizovat dokumentaci"]
        var list = [ev(.userPromptSubmit, "a", a, -1226)]
        for (i, subject) in subjects.enumerated() {
            list.append(ev(.taskCreated, "a", a, -1220 + Double(i), signals: [.created(id: "\(i + 1)", subject: subject)]))
        }
        let starts: [TimeInterval] = [-1210, -900, -610, -290]
        for (i, start) in starts.enumerated() {
            list.append(ev(.postToolUse, "a", a, start, signals: [.started(id: "\(i + 1)")]))
            if i < 3 { list.append(ev(.taskCompleted, "a", a, starts[i + 1] - 2, signals: [.completed(id: "\(i + 1)", subject: nil)])) }
        }
        list.append(ev(.subagentStart, "a", a, -200, agent: "x1", type: "Explore"))
        list.append(ev(.subagentStart, "a", a, -120, agent: "x2", type: "code-reviewer"))
        list.append(ev(.userPromptSubmit, "b", b, -520))
        list.append(ev(.postToolUse, "b", b, -30))
        return list
    }

    /// Five weeks of finished turns across three projects, with the checkpoints the estimate would have shown.
    static func sampleTurns(now: Date) -> [TurnRecord] {
        var seed: UInt64 = 42
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let projects = ["rasinova-residence", "code", "alwayson"]
        var turns: [TurnRecord] = []
        for i in 0..<60 {
            let project = projects[i % 3]
            let started = now.addingTimeInterval(-Double(i) * 16_000 - 1800 - rnd() * 3000)
            let tasks = project == "code" && i % 2 == 0 ? 0 : 3 + Int(rnd() * 8)
            let perTask = 180 + rnd() * 240
            let durations = (0..<tasks).map { _ in perTask * (0.7 + rnd() * 0.6) }
            let active = tasks > 0 ? durations.reduce(0, +) + 40 : 360 + rnd() * 900
            // Older turns were estimated worse than recent ones, so the trend improves.
            let errorScale = i < 20 ? 0.18 : 0.35
            var checkpoints: [EtaCheckpoint] = []
            if i % 7 != 3 {
                let likely = active * (1 + (rnd() - 0.45) * 2 * errorScale)
                let half = likely * (tasks > 0 ? 0.15 : 0.35)
                checkpoints = [EtaCheckpoint(fraction: 0.25, low: likely - half, likely: likely, high: likely + half,
                                             confidence: tasks > 0 ? .medium : .low, tasksTotal: tasks > 0 ? tasks : nil)]
            }
            turns.append(TurnRecord(id: "t\(i)", project: project, startedAt: started, duration: active + rnd() * 60,
                                    activeDuration: active, taskCount: tasks, taskDurations: durations,
                                    subagents: i % 4 == 0 ? [SubagentRun(type: "Explore", duration: 200 + rnd() * 300)] : [],
                                    toolCount: 20 + Int(rnd() * 60), checkpoints: checkpoints))
        }
        return turns
    }

    func previewUsage(_ kind: PreviewUsage) {
        let now = Date()
        var u = UsageState()
        func snap(_ id: String, _ project: String, _ model: String, _ ctx: Double, five: Double?, week: Double?) -> StatusLineSnapshot {
            StatusLineSnapshot(sessionID: id, cwd: "/Users/me/Projects/\(project)", model: model, contextPercent: ctx,
                               fiveHour: five.map { UsageWindow(usedPercentage: $0, resetsAt: now.addingTimeInterval(8040)) },
                               sevenDay: week.map { UsageWindow(usedPercentage: $0, resetsAt: now.addingTimeInterval(4 * 86400 + 3600)) })
        }
        switch kind {
        case .data:
            _ = u.apply(snap("a", "alwayson", "Opus 5.5", 34, five: 42, week: 15), at: now.addingTimeInterval(-70))
            _ = u.apply(snap("b", "website", "Sonnet 5", 86, five: 42, week: 15), at: now.addingTimeInterval(-65))
        case .critical:
            _ = u.apply(snap("a", "alwayson", "Opus 5.5", 91, five: 96, week: 83), at: now.addingTimeInterval(-20))
        case .stale:
            _ = u.apply(snap("z", "dotfiles", "Opus 5.5", 12, five: 55, week: 30), at: now.addingTimeInterval(-3000))
        case .empty:
            break
        case .noLimits:
            _ = u.apply(snap("a", "alwayson", "Opus 5.5", 34, five: nil, week: nil), at: now.addingTimeInterval(-10))
        }
        previewInject(history: history, setup: setup, selfTest: selfTestResults, usage: u)
    }
}
