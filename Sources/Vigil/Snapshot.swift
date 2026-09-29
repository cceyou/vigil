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
            Shot(name: "window-history", width: 440, apply: { $0.previewScenario(.working) }, view: window(.history)),
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

enum PreviewScenario { case working, multi, waiting, countdown, keepAwake, idleSetup }
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
                _ = m.handle(hook(.notification, "a", "alwayson"), at: now.addingTimeInterval(-40))
            case .countdown:
                _ = m.handle(hook(.userPromptSubmit, "a", "alwayson"), at: now.addingTimeInterval(-900))
                _ = m.handle(hook(.stop, "a", "alwayson"), at: now.addingTimeInterval(-6))
            case .keepAwake:
                _ = m.handle(.keepAwake, at: now.addingTimeInterval(-3005))
            case .idleSetup:
                setup = SetupStatus(sudoers: true, hooks: true, notifications: false, loginItem: true, socket: true, statusLine: false)
            }
        }
        previewInject(history: history, setup: setup, selfTest: selfTestResults)
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
