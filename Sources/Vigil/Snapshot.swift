import AppKit
import SwiftUI
import VigilCore

/// `Vigil --snapshot <dir>` renders the popover, the small windows and the usage card offscreen into PNGs
/// (no screen-recording permission needed). Never starts the socket server, timers or any power handling.
@MainActor
enum Snapshot {
    static func run(into directory: String, then finish: @escaping () -> Void) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = AppModel()
        model.loadPreviewData()
        let card = UsageCardState()
        card.shown = true

        struct Shot { let name: String; let width: CGFloat?; let apply: (AppModel) -> Void; let view: () -> AnyView }
        let popover: () -> AnyView = { AnyView(PopoverView(model: model)) }
        let usageCard: () -> AnyView = {
            AnyView(UsageCardView(model: model, state: card)
                .padding(40)
                .background(LinearGradient(colors: [Color(hex: 0x2B5876), Color(hex: 0x4E4376), Color(hex: 0xC06C84)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
        func window(_ kind: AuxWindow) -> () -> AnyView {
            { AnyView(AuxWindowRoot(model: model, kind: kind).frame(width: 440)) }
        }
        let shots: [Shot] = [
            Shot(name: "popover-working", width: nil, apply: { $0.previewScenario(.working) }, view: popover),
            Shot(name: "popover-multi", width: nil, apply: { $0.previewScenario(.multi) }, view: popover),
            Shot(name: "popover-waiting", width: nil, apply: { $0.previewScenario(.waiting) }, view: popover),
            Shot(name: "popover-countdown", width: nil, apply: { $0.previewScenario(.countdown) }, view: popover),
            Shot(name: "popover-keepawake", width: nil, apply: { $0.previewScenario(.keepAwake) }, view: popover),
            Shot(name: "popover-idle-setup", width: nil, apply: { $0.previewScenario(.idleSetup) }, view: popover),
            Shot(name: "window-history", width: 440, apply: { $0.previewScenario(.working); $0.historyTab = .sessions }, view: window(.history)),
            Shot(name: "popover-eta-tasks", width: nil, apply: { $0.previewScenario(.etaTasks) }, view: popover),
            Shot(name: "popover-eta-history", width: nil, apply: { $0.previewScenario(.etaHistory) }, view: popover),
            Shot(name: "popover-eta-island", width: nil, apply: {
                $0.previewSettings { $0.ui.islandContent = .estimate }
                $0.previewScenario(.etaHistory)
            }, view: popover),
            Shot(name: "card-usage-eta", width: nil, apply: {
                $0.previewSettings { $0.ui.islandContent = .elapsed }
                $0.previewScenario(.etaTasks); $0.previewUsage(.data)
            }, view: usageCard),
            Shot(name: "window-history-accuracy", width: 480, apply: {
                $0.previewScenario(.etaTasks); $0.historyTab = .accuracy
            }, view: { AnyView(AuxWindowRoot(model: model, kind: .history).frame(width: 480)) }),
            Shot(name: "window-settings", width: 440, apply: { $0.previewScenario(.working) }, view: window(.settings)),
            Shot(name: "window-selftest", width: 440, apply: { $0.previewScenario(.working) }, view: window(.selfTest)),
            Shot(name: "card-usage", width: nil, apply: { $0.previewScenario(.working); $0.previewUsage(.data) }, view: usageCard),
            Shot(name: "card-critical", width: nil, apply: { $0.previewScenario(.countdown); $0.previewUsage(.critical) }, view: usageCard),
            Shot(name: "card-stale", width: nil, apply: { $0.previewScenario(.idleSetup); $0.previewUsage(.stale) }, view: usageCard),
            Shot(name: "card-empty", width: nil, apply: { $0.previewScenario(.idleSetup); $0.previewUsage(.empty) }, view: usageCard),
            Shot(name: "card-nolimits", width: nil, apply: { $0.previewScenario(.working); $0.previewUsage(.noLimits) }, view: usageCard),
        ]

        Task {
            for scheme in [ColorScheme.dark, .light] {
                for shot in shots {
                    // The popover and windows are always dark; only the glass card follows the system appearance.
                    if scheme == .light && !shot.name.hasPrefix("card") { continue }
                    shot.apply(model)
                    try? await Task.sleep(for: .milliseconds(200))
                    let host = NSHostingView(rootView: shot.view().environment(\.colorScheme, scheme))
                    var size = host.fittingSize
                    if let w = shot.width { size.width = w }
                    host.frame = NSRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.backgroundColor = .black
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let path = "\(directory)/\(shot.name)-\(scheme == .dark ? "dark" : "light").png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path)")
                }
            }
            finish()
        }
    }
}

enum PreviewScenario { case working, multi, waiting, countdown, keepAwake, idleSetup, etaTasks, etaHistory }
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
        func hook(_ kind: HookKind, _ id: String, _ project: String, agent: String? = nil, type: String? = nil) -> Event {
            .hook(HookEvent(kind: kind, sessionID: id, cwd: "/Users/me/Projects/\(project)", pid: 1, agentID: agent, agentType: type))
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
                _ = m.handle(.keepAwake, at: now.addingTimeInterval(-5))
            case .multi:
                _ = m.handle(hook(.userPromptSubmit, "a", "alwayson"), at: now.addingTimeInterval(-4008))
                _ = m.handle(hook(.userPromptSubmit, "b", "website"), at: now.addingTimeInterval(-900))
                _ = m.handle(hook(.subagentStart, "b", "website", agent: "y1", type: "Explore"), at: now.addingTimeInterval(-60))
                _ = m.handle(hook(.userPromptSubmit, "c", "rasinova-residence"), at: now.addingTimeInterval(-120))
            case .waiting:
                _ = m.handle(hook(.userPromptSubmit, "a", "alwayson"), at: now.addingTimeInterval(-1500))
                _ = m.handle(.hook(HookEvent(kind: .notification, sessionID: "a", cwd: "/Users/me/Projects/alwayson", pid: 1,
                                             notificationType: "permission_prompt")), at: now.addingTimeInterval(-40))
            case .countdown:
                _ = m.handle(hook(.userPromptSubmit, "a", "alwayson"), at: now.addingTimeInterval(-900))
                _ = m.handle(hook(.stop, "a", "alwayson"), at: now.addingTimeInterval(-6))
            case .keepAwake:
                _ = m.handle(.keepAwake, at: now.addingTimeInterval(-3005))
            case .idleSetup:
                setup = SetupStatus(sudoers: true, hooks: true, notifications: false, loginItem: true, socket: true, statusLine: false)
            case .etaTasks:
                for e in Self.etaEvents(now: now) { _ = m.handle(.hook(e.0), at: e.1) }
                _ = m.handle(.keepAwake, at: now.addingTimeInterval(-1044))
            case .etaHistory:
                for e in Self.etaEvents(now: now) where e.0.sessionID == "b" { _ = m.handle(.hook(e.0), at: e.1) }
                _ = m.handle(.keepAwake, at: now.addingTimeInterval(-1044))
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
        if scenario == .etaTasks { sessionPage = "a" }
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
