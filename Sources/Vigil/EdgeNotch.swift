import AppKit
import os
import Carbon.HIToolbox
import SwiftUI
import VigilCore

/// Borderless non-activating panel. It never becomes main, and never key unless `becomesKeyOnClick` is set
/// (only the usage card, and only after the user clicks into it), so hovering never steals focus.
final class EdgePanel: NSPanel {
    /// The usage card sets this: a click into it may make it key (so it can see Esc). Hover never does.
    var becomesKeyOnClick = false
    /// Esc while this panel is key. Vigil never claims Esc system-wide.
    var onEscape: (() -> Void)?

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

    override var canBecomeKey: Bool { becomesKeyOnClick }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape), let onEscape {
            onEscape()
            return
        }
        super.sendEvent(event)
    }
}

/// Hosting view that reports hover through its own NSTrackingArea (no global event monitors).
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onClick: (() -> Void)?
    /// With `becomesKeyOnlyIfNeeded`, a panel becomes key on a click only if the clicked view asks for it.
    var needsKeyOnClick = false
    private var area: NSTrackingArea?

    override var needsPanelToBecomeKey: Bool { needsKeyOnClick }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    /// Throws away the tracking area and makes a new one. Called after every show: a panel ordered out while the
    /// pointer was inside it never got its "exited", and a fresh area starts clean.
    func reinstallTracking() {
        if let area { removeTrackingArea(area) }
        area = nil
        updateTrackingAreas()
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
/// All behaviour lives in `NotchMachine` (hidden / idle / hovering / open / pinned); this controller only feeds it
/// events and carries out its effects. Every transition is logged (os.Logger, subsystem cz.krystof.vigil,
/// category "notch", and Vigil's own log). Visibility is re-evaluated only on a Space change, a screen-parameter
/// change and wake, debounced by 300 ms, never because one of Vigil's own windows appeared.
@MainActor
final class EdgeNotchController {
    private struct Notch {
        let screenID: CGDirectDisplayID
        let panel: EdgePanel
        let host: HoverHostingView<NotchPill>
        let state: NotchPillState
    }

    static let panelSize = NSSize(width: 24, height: 96)
    /// Keeps the notch (and so the hover zone) away from the screen corners (Hot Corners).
    static let cornerMargin: CGFloat = 80
    nonisolated private static let debounce: TimeInterval = 0.3

    private let model: AppModel
    private let logger = Logger(subsystem: "cz.krystof.vigil", category: "notch")
    private var machine = NotchMachine()
    private var notches: [Notch] = []
    private let cardState = UsageCardState()
    private var cardPanel: EdgePanel?
    private var cardHost: HoverHostingView<AnyView>?
    /// Screen whose notch the card is attached to.
    private var cardScreenID: CGDirectDisplayID?
    private var timers: [NotchMachine.TimerKind: Timer] = [:]
    private var orderOutWork: DispatchWorkItem?
    private var visibilityWork: DispatchWorkItem?
    private var watchdogTimer: Timer?
    private var shortcutToken: UInt32?
    /// Outside-click monitors (global + local), installed only while the card is pinned.
    private var outsideClickMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// Last visibility decision per display, for the self-test and the log.
    private(set) var visibility: [CGDirectDisplayID: NotchVisibility] = [:]

    init(model: AppModel) {
        self.model = model
        machine.hoverDelay = model.settings.ui.hoverDelay
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleVisibilityCheck("Space changed") }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleVisibilityCheck("wake") }
        })
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runWatchdog() }
        }
    }

    // MARK: settings

    func apply() {
        machine.hoverDelay = ui.hoverDelay
        rebuild()
        registerShortcut()
        scheduleVisibilityCheck("settings", delay: 0)
    }

    private var ui: UISettings { model.settings.ui }

    private func registerShortcut() {
        HotKeyCenter.shared.unregister(shortcutToken)
        shortcutToken = nil
        let spec = ui.shortcut
        guard spec.enabled else { return }
        shortcutToken = HotKeyCenter.shared.register(keyCode: spec.keyCode, modifiers: spec.modifiers) { [weak self] in
            guard let self else { return }
            if !self.machine.cardShown { self.cardScreenID = self.defaultScreenID() }
            self.send(.shortcut)
        }
    }

    /// The popover's usage row: opens the card pinned, like the shortcut (nothing to do when it is already shown).
    func showCardPinned() {
        guard !machine.cardShown else { return }
        cardScreenID = defaultScreenID()
        send(.shortcut)
    }

    // MARK: the machine

    private func send(_ input: NotchMachine.Input) {
        for effect in machine.handle(input) { perform(effect) }
        cardState.pinned = machine.phase == .pinned
    }

    private func perform(_ effect: NotchMachine.Effect) {
        switch effect {
        case .showNotch:
            for n in notches where !n.panel.isVisible { n.panel.orderFrontRegardless() }
        case .hideNotch:
            for n in notches {
                n.state.hovering = false
                n.panel.orderOut(nil)
            }
        case .reinstallTracking:
            for n in notches { n.host.reinstallTracking() }
            cardHost?.reinstallTracking()
        case .showCard:
            showCard()
        case .hideCard:
            hideCard()
        case .makeCardKey:
            cardPanel?.makeKey()
        case .startTimer(let kind, let token, let delay):
            timers[kind]?.invalidate()
            timers[kind] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(.timer(kind, token: token)) }
            }
        case .cancelTimers:
            timers.values.forEach { $0.invalidate() }
            timers = [:]
        case .watchOutsideClicks(let on):
            setOutsideClickMonitor(on)
        case .log(let line):
            logger.notice("\(line, privacy: .public)")
            Log.shared.info("notch: \(line)")
        }
    }

    // MARK: visibility

    private func screensChanged() {
        rebuild()
        scheduleVisibilityCheck("screens changed")
    }

    /// Debounced: Space-switch animations and wake post several notifications in a row.
    private func scheduleVisibilityCheck(_ reason: String, delay: TimeInterval = EdgeNotchController.debounce) {
        visibilityWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluateVisibility(reason) } }
        visibilityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func evaluateVisibility(_ reason: String) {
        let windows = Self.windowEntries()
        for n in notches {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == n.screenID }) else { continue }
            let snapshot = Self.spaceSnapshot(for: screen, windows: windows)
            let fullScreen = FullScreenDetector.isNativeFullScreen(snapshot)
            let app = FullScreenDetector.appRevealStrip(snapshot)?.owner ?? NSWorkspace.shared.frontmostApplication?.localizedName
            visibility[n.screenID] = NotchVisibility.decide(enabled: ui.notchEnabled, onThisDisplay: true,
                                                            hideInFullScreen: ui.hideInFullScreen, fullScreen: fullScreen,
                                                            fullScreenApp: fullScreen ? app : nil)
        }
        // One machine drives all notches: the main (or card) display decides.
        let id = cardScreenID ?? defaultScreenID()
        let allowed = ui.notchEnabled && !notches.isEmpty && (id.flatMap { visibility[$0] }?.isVisible ?? true)
        if allowed != machine.visibilityAllowed || machine.notchShown != allowed {
            perform(.log("visibility check (\(reason)): \(allowed ? "show" : "hide") – \(id.flatMap { visibility[$0] }?.logText ?? "no notch")"))
        }
        send(.visibility(allowed: allowed))
    }

    /// Twice a second: does what is on screen match the machine? (It resets after a second of disagreement.)
    private func runWatchdog() {
        let cardOnScreen = cardPanel?.isVisible ?? false
        let notchOnScreen = notches.contains { $0.panel.isVisible }
        // A card that is still sliding out (orderOut pending) counts as the state it is heading to.
        let effectiveCard = orderOutWork != nil && !machine.cardShown ? false : cardOnScreen
        send(.watchdog(cardOnScreen: effectiveCard, notchOnScreen: notches.isEmpty ? machine.notchShown : notchOnScreen, now: Date()))
    }

    /// On-screen windows of the current Space(s), front to back, without Vigil's own: its notch and card must never
    /// change what the check sees. Owner, pid, layer, alpha and bounds need no Screen Recording permission.
    static func windowEntries() -> [WindowEntry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            return WindowEntry(owner: w[kCGWindowOwnerName as String] as? String ?? "", pid: pid,
                               layer: w[kCGWindowLayer as String] as? Int ?? 0, alpha: w[kCGWindowAlpha as String] as? Double ?? 1,
                               bounds: bounds)
        }
    }

    static func spaceSnapshot(for screen: NSScreen, windows: [WindowEntry]) -> SpaceSnapshot {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame
        let display = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height) // CG: top-left origin
        return SpaceSnapshot(display: display, windows: windows, ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// One line per display for the self-test: visible or why not, the frontmost app, the full-screen state.
    func statusReport() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let windows = Self.windowEntries()
        if notches.isEmpty { return L("Notch is off") + " · " + L("frontmost app: %@", front) }
        return notches.map { n -> String in
            let screen = NSScreen.screens.first { $0.displayID == n.screenID }
            let fullScreen = screen.map { FullScreenDetector.isNativeFullScreen(Self.spaceSnapshot(for: $0, windows: windows)) } ?? false
            let state: String
            switch visibility[n.screenID] ?? .visible {
            case .visible: state = n.panel.isVisible ? L("Notch visible") : L("Notch should be visible but is not on screen")
            case .hiddenFullScreen(let app): state = L("Notch hidden: %@ is in full screen (⌥⌘U still opens the card)", app ?? "?")
            case .disabled: state = L("Notch is off")
            case .notOnThisDisplay: state = L("No notch on this display")
            }
            return state + " · " + L("frontmost app: %@", front) + " · " + (fullScreen ? L("full-screen Space") : L("not full screen"))
                + " · " + L("state: %@", machine.phase.rawValue)
        }.joined(separator: "\n")
    }

    /// For the self-test: what is on screen matches the state machine.
    var notchHealthy: Bool {
        (notches.contains { $0.panel.isVisible }) == machine.notchShown || notches.isEmpty
    }

    // MARK: notches

    private func targetScreens() -> [NSScreen] {
        guard ui.notchEnabled else { return [] }
        let screens = NSScreen.screens
        return ui.notchDisplays == .main ? Array(screens.prefix(1)) : screens
    }

    private func defaultScreenID() -> CGDirectDisplayID? {
        let main = NSScreen.screens.first?.displayID
        return notch(main ?? 0) != nil ? main : notches.first?.screenID ?? main
    }

    /// Keeps one notch per target display. Existing panels are only moved, never replaced: a panel created while a
    /// full-screen Space is active stayed visible there but never received another mouse event.
    private func rebuild() {
        let screens = targetScreens()
        let wanted = Set(screens.compactMap(\.displayID))
        for n in notches where !wanted.contains(n.screenID) { n.panel.orderOut(nil) }
        notches.removeAll { !wanted.contains($0.screenID) }
        for screen in screens {
            guard let id = screen.displayID else { continue }
            let frame = notchFrame(on: screen)
            if let existing = notch(id) {
                if existing.panel.frame != frame { existing.panel.setFrame(frame, display: true) }
                continue
            }
            let state = NotchPillState()
            let panel = EdgePanel(contentRect: frame)
            let host = HoverHostingView(rootView: NotchPill(state: state))
            host.onEnter = { [weak self] in self?.pointerEnteredNotch(id) }
            host.onExit = { [weak self] in self?.pointerExitedNotch(id) }
            host.onClick = { [weak self] in
                guard let self else { return }
                if !self.machine.cardShown { self.cardScreenID = id }
                self.send(.notchClick)
            }
            panel.contentView = host
            if machine.notchShown { panel.orderFrontRegardless() }
            notches.append(Notch(screenID: id, panel: panel, host: host, state: state))
        }
        if machine.cardShown { positionCard() }
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

    private func pointerEnteredNotch(_ id: CGDirectDisplayID) {
        notch(id)?.state.hovering = true
        if !machine.cardShown { cardScreenID = id }
        send(.enterNotch(mouseButtonsDown: NSEvent.pressedMouseButtons != 0))
    }

    private func pointerExitedNotch(_ id: CGDirectDisplayID) {
        notch(id)?.state.hovering = false
        send(.exitNotch)
    }

    // MARK: card

    private func ensureCard() -> (EdgePanel, HoverHostingView<AnyView>) {
        if let cardPanel, let cardHost { return (cardPanel, cardHost) }
        let panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400))
        panel.becomesKeyOnClick = true
        panel.onEscape = { [weak self, weak panel] in self?.send(.escape(cardIsKey: panel?.isKeyWindow ?? false)) }
        let root = AnyView(UsageCardContainer(model: model, state: cardState,
                                              onClick: { [weak self] in self?.send(.cardClick) },
                                              onClose: { [weak self] in self?.send(.closeButton) }))
        let host = HoverHostingView(rootView: root)
        host.needsKeyOnClick = true
        host.onEnter = { [weak self] in self?.send(.enterCard) }
        host.onExit = { [weak self] in self?.send(.exitCard) }
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

    private func showCard() {
        orderOutWork?.cancel()
        orderOutWork = nil
        let (panel, _) = ensureCard()
        if cardScreenID == nil { cardScreenID = defaultScreenID() }
        positionCard()
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { cardState.shown = true }
    }

    private func hideCard() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { cardState.shown = false }
        orderOutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.orderOutWork = nil
                if !self.machine.cardShown { self.cardPanel?.orderOut(nil) }
            }
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Keeps the panel sized to its content (sessions come and go) while it is visible.
    func refresh() {
        if machine.cardShown { positionCard() }
    }

    /// Left mouse-downs only. The global monitor sees clicks in other apps; the local one sees clicks in Vigil's
    /// own windows (menu bar icon, popover) except the card and the notches, which handle their own clicks.
    private func setOutsideClickMonitor(_ on: Bool) {
        if on, outsideClickMonitors.isEmpty {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.send(.mouseDownOutside) }
            }) {
                outsideClickMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, !self.isEdgeWindow(event.window) { self.send(.mouseDownOutside) }
                }
                return event
            }) {
                outsideClickMonitors.append(local)
            }
        } else if !on, !outsideClickMonitors.isEmpty {
            outsideClickMonitors.forEach(NSEvent.removeMonitor)
            outsideClickMonitors = []
        }
    }

    private func isEdgeWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === cardPanel || notches.contains { $0.panel === window }
    }
}

/// Clips the sliding card to its panel and slides it in from the right edge.
private struct UsageCardContainer: View {
    let model: AppModel
    let state: UsageCardState
    let onClick: () -> Void
    let onClose: () -> Void

    var body: some View {
        UsageCardView(model: model, state: state, onClick: onClick, onClose: onClose)
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
