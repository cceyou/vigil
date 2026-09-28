import AppKit
import SwiftUI
import VigilCore

/// `Vigil --snapshot <dir>` renders the popover offscreen (no screen-recording permission needed) into PNGs.
/// Never starts the socket server, timers or any power handling.
@MainActor
enum Snapshot {
    static func run(into directory: String, then finish: @escaping () -> Void) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = AppModel()
        model.loadPreviewData()

        struct Shot { let name: String; let tab: Tab; let apply: (AppModel) -> Void }
        let shots: [Shot] = [
            Shot(name: "overview-working", tab: .overview) { m in m.preview(phase: .working) },
            Shot(name: "overview-countdown", tab: .overview) { m in m.preview(phase: .countdown) },
            Shot(name: "overview-armed", tab: .overview) { m in m.preview(phase: .armed) },
            Shot(name: "history", tab: .history) { m in m.preview(phase: .armed) },
            Shot(name: "settings", tab: .settings) { m in m.preview(phase: .armed) },
            Shot(name: "selftest", tab: .selfTest) { m in m.preview(phase: .armed) },
        ]

        Task {
            for scheme in [ColorScheme.light, .dark] {
                for shot in shots {
                    model.tab = shot.tab
                    shot.apply(model)
                    try? await Task.sleep(for: .milliseconds(250))
                    let view = PopoverView(model: model).environment(\.colorScheme, scheme)
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: 380, height: 600)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.backgroundColor = scheme == .dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(150))
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

extension AppModel {
    /// Sample data for snapshots only.
    func loadPreviewData() {
        previewInject(history: [
            SessionRecord(id: "1", project: "alwayson", startedAt: Date().addingTimeInterval(-3600), duration: 1834, reason: .ended),
            SessionRecord(id: "2", project: "website", startedAt: Date().addingTimeInterval(-9000), duration: 412, reason: .interrupted),
            SessionRecord(id: "3", project: "dotfiles", startedAt: Date().addingTimeInterval(-90000), duration: 28800, reason: .timedOut),
        ], setup: SetupStatus(sudoers: true, hooks: true, notifications: false, loginItem: false, socket: true),
        selfTest: [
            CheckResult(id: .sudoers, passed: true, detail: "sudo -n pmset -a disablesleep 0 works without a password", fix: nil),
            CheckResult(id: .hooks, passed: true, detail: "All hooks are in settings.json and hook.sh is installed", fix: nil),
            CheckResult(id: .socket, passed: true, detail: "The socket is listening", fix: nil),
            CheckResult(id: .roundTrip, passed: true, detail: "A fake hook event went through hook.sh to the app in 41 ms", fix: nil),
            CheckResult(id: .notifications, passed: false, detail: "Notifications are not authorized", fix: .requestNotifications),
        ])
    }

    func preview(phase: Phase) {
        previewSessions(phase: phase)
    }
}
