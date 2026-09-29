import AppKit
import SwiftUI
import VigilCore

/// History, Settings and Self-test open in their own small windows, in the same black "Live Activity" style.
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
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = AuxWindowRoot.title(kind)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        // History is wider: the estimate-accuracy table has six columns.
        window.setContentSize(NSSize(width: kind == .selfTest ? 400 : kind == .history ? 480 : 440, height: kind == .settings ? 640 : 560))
        window.contentMinSize = NSSize(width: 380, height: 320)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Self.title(kind))
                    .font(.system(size: 26, weight: .bold))
                    .padding(.leading, 6)
                switch kind {
                case .history: HistoryView(model: model)
                case .settings: SettingsView(model: model)
                case .selfTest: SelfTestView(model: model)
                }
                if let message = model.message, kind != .history {
                    MessageBar(text: message) { model.dismissMessage() }
                }
            }
            .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        .tint(model.accent)
        .animation(.smooth, value: model.message)
    }
}
