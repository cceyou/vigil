import AppKit
import SwiftUI
import VigilCore

/// History, Settings and Self-test open in standard macOS windows (title bar, toolbar, system background).
@MainActor
final class AuxWindowManager {
    private let model: AppModel
    private var windows: [AuxWindow: NSWindow] = [:]

    init(model: AppModel) { self.model = model }

    func show(_ kind: AuxWindow) {
        let window = windows[kind] ?? makeWindow(kind)
        windows[kind] = window
        if kind != .history { model.refreshSetup() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(_ kind: AuxWindow) -> NSWindow {
        let host = NSHostingController(rootView: AuxWindowRoot(model: model, kind: kind))
        // SwiftUI `.toolbar` items (the History tabs, Run again) become the window's NSToolbar.
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = AuxWindowRoot.title(kind)
        window.toolbarStyle = kind == .settings ? .preference : .unified
        window.isReleasedWhenClosed = false
        // History is wider: the estimate-accuracy table has six columns.
        window.setContentSize(NSSize(width: kind == .history ? 640 : kind == .selfTest ? 460 : 520,
                                     height: kind == .settings ? 680 : 560))
        window.contentMinSize = NSSize(width: 420, height: 320)
        window.center()
        window.setFrameAutosaveName("Vigil.\(kind.rawValue)")
        return window
    }
}

struct AuxWindowRoot: View {
    let model: AppModel
    let kind: AuxWindow

    static func title(_ kind: AuxWindow) -> String {
        switch kind {
        case .history: return L("History")
        case .settings: return L("Settings")
        case .selfTest: return L("Self-test")
        }
    }

    var body: some View {
        Group {
            switch kind {
            case .history: HistoryView(model: model)
            case .settings: SettingsView(model: model)
            case .selfTest: SelfTestView(model: model)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.message, kind != .history {
                MessageRow(text: message) { model.dismissMessage() }
                    .padding(12)
                    .background(.bar)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .tint(model.accent)
        .animation(.smooth, value: model.message)
    }
}
