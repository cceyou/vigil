import AppKit
import Carbon.HIToolbox
import SwiftUI
import VigilCore

/// Borderless panel that never becomes key or main, so hovering or clicking it never steals focus.
final class NonKeyPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reports hover through its own NSTrackingArea (no global event monitors).
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onClick: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }
}

@MainActor
@Observable
final class NotchPillState {
    var hovering = false
}

/// The thin glass pill on the right screen edge. It grows when the pointer comes close.
struct NotchPill: View {
    let state: NotchPillState
    var body: some View {
        let hover = state.hovering
        ZStack(alignment: .trailing) {
            Color.clear
            Capsule()
                .fill(.white.opacity(hover ? 0.35 : 0.18))
                .frame(width: hover ? 9 : 5, height: hover ? 72 : 56)
                .modifier(PillGlass())
                .opacity(hover ? 1 : 0.55)
                .shadow(color: .black.opacity(hover ? 0.25 : 0), radius: 4)
                .padding(.trailing, 2)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hover)
    }
}

private struct PillGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        }
    }
}

/// One notch per display (or only the main one), plus the usage card that slides out of the edge.
///
/// Hover: pointer on the notch for `hoverDelay` (and no mouse button held, so dragging a window to the edge
/// never opens it) shows the card; leaving both notch and card hides it after 400 ms. A click on the card pins it;
/// Esc (a Carbon hotkey registered only while pinned) or a click on the notch closes it.
@MainActor
final class EdgeNotchController {
    private struct Notch {
        let screenID: CGDirectDisplayID
        let panel: NonKeyPanel
        let state: NotchPillState
    }

    static let panelSize = NSSize(width: 24, height: 96)
    /// Keeps the notch (and so the hover zone) away from the screen corners (Hot Corners).
    static let cornerMargin: CGFloat = 80
    private static let hideDelay: TimeInterval = 0.4

    private let model: AppModel
    private var notches: [Notch] = []
    private let cardState = UsageCardState()
    private var cardPanel: NonKeyPanel?
    private var cardHost: HoverHostingView<AnyView>?
    /// Screen whose notch the card is attached to.
    private var cardScreenID: CGDirectDisplayID?
    private var pointerInCard = false
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var orderOutWork: DispatchWorkItem?
    private var shortcutToken: UInt32?
    private var escToken: UInt32?
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel) {
        self.model = model
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Full-screen transitions finish a moment after the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { self?.updateFullScreenVisibility() } }
            })
        }
    }

    // MARK: settings

    func apply() {
        rebuild()
        registerShortcut()
    }

    private var ui: UISettings { model.settings.ui }

    private func registerShortcut() {
        HotKeyCenter.shared.unregister(shortcutToken)
        shortcutToken = nil
        let spec = ui.shortcut
        guard spec.enabled else { return }
        shortcutToken = HotKeyCenter.shared.register(keyCode: spec.keyCode, modifiers: spec.modifiers) { [weak self] in
            self?.toggleFromShortcut()
        }
    }

    // MARK: notches

    private func targetScreens() -> [NSScreen] {
        guard ui.notchEnabled else { return [] }
        let screens = NSScreen.screens
        return ui.notchDisplays == .main ? Array(screens.prefix(1)) : screens
    }

    private func rebuild() {
        for n in notches { n.panel.orderOut(nil) }
        notches = targetScreens().compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let state = NotchPillState()
            let panel = NonKeyPanel(contentRect: notchFrame(on: screen))
            let host = HoverHostingView(rootView: NotchPill(state: state))
            host.onEnter = { [weak self] in self?.notchEntered(screenID: id) }
            host.onExit = { [weak self] in self?.notchExited(screenID: id) }
            host.onClick = { [weak self] in self?.notchClicked(screenID: id) }
            panel.contentView = host
            panel.orderFrontRegardless()
            return Notch(screenID: id, panel: panel, state: state)
        }
        updateFullScreenVisibility()
        if cardState.shown { positionCard() }
    }

    /// Flush with the visible frame's right edge (so a Dock on the right keeps the notch just inside it),
    /// at the configured height, clamped away from the corners.
    private func notchFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let size = Self.panelSize
        let half = size.height / 2
        let lo = vf.minY + Self.cornerMargin + half
        let hi = vf.maxY - Self.cornerMargin - half
        let center = lo <= hi ? min(hi, max(lo, vf.minY + vf.height * ui.notchPosition)) : vf.midY
        return NSRect(x: vf.maxX - size.width, y: (center - half).rounded(), width: size.width, height: size.height)
    }

    private func notch(_ id: CGDirectDisplayID) -> Notch? { notches.first { $0.screenID == id } }

    private func updateFullScreenVisibility() {
        for n in notches {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == n.screenID }) else { continue }
            let hide = ui.hideInFullScreen && Self.fullScreenWindowCovers(screen)
            if hide {
                n.panel.orderOut(nil)
                if cardScreenID == n.screenID, cardState.shown, !cardState.pinned { hideCard() }
            } else if !n.panel.isVisible {
                n.panel.orderFrontRegardless()
            }
        }
    }

    /// A normal-layer window of another app covering the whole screen (menu bar included) means full screen.
    /// Window bounds are readable without Screen Recording permission.
    static func fullScreenWindowCovers(_ screen: NSScreen) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height) // CG: top-left origin
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            if abs(bounds.minX - target.minX) < 1, abs(bounds.minY - target.minY) < 1,
               abs(bounds.width - target.width) < 1, abs(bounds.height - target.height) < 1 { return true }
        }
        return false
    }

    // MARK: hover

    private func notchEntered(screenID: CGDirectDisplayID) {
        guard let n = notch(screenID) else { return }
        n.state.hovering = true
        hideTimer?.invalidate()
        // Someone dragging a window (or a selection) to the edge: never open.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        showTimer?.invalidate()
        showTimer = Timer.scheduledTimer(withTimeInterval: ui.hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.notch(screenID)?.state.hovering == true, NSEvent.pressedMouseButtons == 0 else { return }
                self.showCard(on: screenID)
            }
        }
    }

    private func notchExited(screenID: CGDirectDisplayID) {
        notch(screenID)?.state.hovering = false
        showTimer?.invalidate()
        scheduleHide()
    }

    private func notchClicked(screenID: CGDirectDisplayID) {
        showTimer?.invalidate()
        if cardState.shown {
            hideCard()
        } else {
            showCard(on: screenID)
            pin()
        }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        guard cardState.shown, !cardState.pinned else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.hideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.cardState.pinned, !self.pointerInCard,
                      !self.notches.contains(where: { $0.state.hovering }) else { return }
                self.hideCard()
            }
        }
    }

    // MARK: card

    private func ensureCard() -> (NonKeyPanel, HoverHostingView<AnyView>) {
        if let cardPanel, let cardHost { return (cardPanel, cardHost) }
        let panel = NonKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400))
        let root = AnyView(UsageCardContainer(model: model, state: cardState) { [weak self] in self?.pin() })
        let host = HoverHostingView(rootView: root)
        host.onEnter = { [weak self] in
            self?.pointerInCard = true
            self?.hideTimer?.invalidate()
        }
        host.onExit = { [weak self] in
            self?.pointerInCard = false
            self?.scheduleHide()
        }
        panel.contentView = host
        cardPanel = panel
        cardHost = host
        return (panel, host)
    }

    /// Card panel: left of the notch column, vertically centered on the notch, inside the visible frame.
    private func positionCard() {
        guard let panel = cardPanel, let host = cardHost else { return }
        let screen = NSScreen.screens.first { $0.displayID == cardScreenID } ?? NSScreen.screens.first
        guard let screen else { return }
        let vf = screen.visibleFrame
        let size = host.fittingSize
        let notchMid = notch(cardScreenID ?? 0)?.panel.frame.midY ?? notchFrame(on: screen).midY
        var y = notchMid - size.height / 2
        y = min(vf.maxY - size.height, max(vf.minY, y))
        let frame = NSRect(x: vf.maxX - Self.panelSize.width - size.width, y: y.rounded(), width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func showCard(on screenID: CGDirectDisplayID?) {
        orderOutWork?.cancel()
        let (panel, _) = ensureCard()
        cardScreenID = screenID ?? NSScreen.screens.first?.displayID
        positionCard()
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { cardState.shown = true }
    }

    func hideCard() {
        showTimer?.invalidate()
        hideTimer?.invalidate()
        unpin()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { cardState.shown = false }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.cardState.shown else { return }
                self.cardPanel?.orderOut(nil)
            }
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Keeps the panel sized to its content (sessions come and go) while it is visible.
    func refresh() {
        if cardState.shown { positionCard() }
    }

    private func pin() {
        guard !cardState.pinned else { return }
        cardState.pinned = true
        hideTimer?.invalidate()
        // Esc is only claimed while the card is pinned, and released as soon as it closes.
        escToken = HotKeyCenter.shared.register(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in self?.hideCard() }
    }

    private func unpin() {
        cardState.pinned = false
        HotKeyCenter.shared.unregister(escToken)
        escToken = nil
    }

    private func toggleFromShortcut() {
        if cardState.shown {
            hideCard()
        } else {
            let main = NSScreen.screens.first?.displayID
            showCard(on: notch(main ?? 0) != nil ? main : notches.first?.screenID ?? main)
            pin()
        }
    }
}

/// Clips the sliding card to its panel and slides it in from the right edge.
private struct UsageCardContainer: View {
    let model: AppModel
    let state: UsageCardState
    let onPin: () -> Void

    var body: some View {
        UsageCardView(model: model, state: state, onPin: onPin)
            .padding(.vertical, 24).padding(.leading, 24).padding(.trailing, 10) // room for the glass shadow
            .offset(x: state.shown ? 0 : UsageCardView.width + 40)
            .opacity(state.shown ? 1 : 0)
            .fixedSize()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
