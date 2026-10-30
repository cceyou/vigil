import Foundation

/// The edge notch and its usage card as one explicit state machine. Pure: the controller feeds it pointer,
/// click, timer, visibility and watchdog inputs and carries out the effects it returns.
///
/// Phases: hidden (no notch shown, card closed) · idle · hovering (pointer on the notch, hover delay running)
/// · open (card shown on hover) · pinned (card stays until closed).
///
/// Rules that make the stuck states of earlier builds impossible:
/// - Visibility changes never take effect while the pointer is inside the notch or the card, or while the card is
///   pinned; they are applied once the pointer leaves (or the card is closed).
/// - Every hide invalidates all pending timers (a new token) and forgets where the pointer was.
/// - Every show starts from idle and asks for the tracking areas to be re-installed.
/// - Timers carry the token they were started with; a late timer with an old token does nothing.
/// - A watchdog resets to a consistent state when the card window and the phase disagree for over a second.
public struct NotchMachine: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case hidden, idle, hovering, open, pinned
    }

    public enum TimerKind: String, Sendable {
        /// Pointer rests on the notch this long before the card opens.
        case hoverDelay
        /// After leaving notch and card, the (unpinned) card closes after this long.
        case hideDelay
    }

    public enum Input: Equatable, Sendable {
        /// The debounced result of the full-screen check (and the notch on/off setting).
        case visibility(allowed: Bool)
        case enterNotch(mouseButtonsDown: Bool)
        case exitNotch
        case enterCard
        case exitCard
        case timer(TimerKind, token: Int)
        case notchClick
        /// A click inside the card (not on one of its buttons): pins it.
        case cardClick
        case shortcut
        case closeButton
        case mouseDownOutside
        case escape(cardIsKey: Bool)
        /// Called about twice a second with what is really on screen.
        case watchdog(cardOnScreen: Bool, notchOnScreen: Bool, now: Date)
        /// The controller threw every panel away (wake, screen change, repair, "Obnovit notch"): start over from
        /// hidden; the next visibility check shows the new notch.
        case rebuilt
    }

    public enum Effect: Equatable, Sendable {
        case showNotch
        case hideNotch
        /// Re-create the tracking areas of the notch and card views (after every show).
        case reinstallTracking
        case showCard
        case hideCard
        case makeCardKey
        case startTimer(TimerKind, token: Int, after: TimeInterval)
        /// Invalidate every pending timer (their tokens are stale from now on anyway).
        case cancelTimers
        /// The mouse-only outside-click monitor runs only while pinned.
        case watchOutsideClicks(Bool)
        /// One line for the log: "idle → hovering (pointer on the notch)".
        case log(String)
    }

    public private(set) var phase: Phase = .hidden
    /// What visibility the last check allowed.
    public private(set) var visibilityAllowed = false
    /// A hide that waits for the pointer to leave (or the card to be unpinned).
    public private(set) var pendingHide = false
    public private(set) var pointerInNotch = false
    public private(set) var pointerInCard = false
    /// Current timer generation; timers started with an older token are ignored.
    public private(set) var token = 0
    public private(set) var mismatchSince: Date?

    public var hoverDelay: TimeInterval
    public var hideDelay: TimeInterval
    public static let watchdogGrace: TimeInterval = 1

    public init(hoverDelay: TimeInterval = 0.18, hideDelay: TimeInterval = 0.4) {
        self.hoverDelay = hoverDelay
        self.hideDelay = hideDelay
    }

    /// The card is (supposed to be) on screen.
    public var cardShown: Bool { phase == .open || phase == .pinned }
    /// The notch is (supposed to be) on screen.
    public private(set) var notchShown = false

    public mutating func handle(_ input: Input) -> [Effect] {
        var fx: [Effect] = []
        let before = phase
        switch input {
        case .visibility(let allowed):
            visibilityAllowed = allowed
            if allowed {
                pendingHide = false
                if !notchShown { show(&fx, why: "visibility allowed") }
            } else if notchShown || cardShown {
                if pointerInNotch || pointerInCard || phase == .pinned {
                    if !pendingHide { fx.append(.log("hide deferred: \(pointerInNotch ? "pointer on the notch" : pointerInCard ? "pointer on the card" : "card pinned")")) }
                    pendingHide = true
                } else {
                    hideAll(&fx, why: "visibility not allowed")
                }
            }

        case .enterNotch(let buttons):
            pointerInNotch = true
            switch phase {
            case .idle where !buttons:
                // Someone dragging a window to the edge (a button held) never opens the card.
                token += 1
                phase = .hovering
                fx.append(.startTimer(.hoverDelay, token: token, after: hoverDelay))
            case .open:
                token += 1 // cancels a pending hideDelay
            default:
                break
            }

        case .exitNotch:
            pointerInNotch = false
            switch phase {
            case .hovering:
                token += 1
                phase = .idle
                fx.append(.cancelTimers)
            case .open where !pointerInCard:
                scheduleClose(&fx)
            default:
                break
            }
            applyPendingHide(&fx)

        case .enterCard:
            pointerInCard = true
            if phase == .open { token += 1 }

        case .exitCard:
            pointerInCard = false
            if phase == .open, !pointerInNotch { scheduleClose(&fx) }
            applyPendingHide(&fx)

        case .timer(let kind, let t):
            guard t == token else { break } // stale: started before a later hide, show or pointer change
            switch (kind, phase) {
            case (.hoverDelay, .hovering) where pointerInNotch:
                phase = .open
                fx.append(.showCard)
            case (.hideDelay, .open) where !pointerInNotch && !pointerInCard:
                close(&fx)
            default:
                break
            }

        case .notchClick:
            switch PinnedCard.reaction(to: .notchClick, shown: cardShown, pinned: phase == .pinned) {
            case .close: close(&fx)
            case .pin: pin(&fx)
            case .show, .none: break
            }

        case .cardClick:
            if phase == .open { pin(&fx) }
            if cardShown { fx.append(.makeCardKey) }

        case .shortcut:
            if cardShown { close(&fx) } else { pin(&fx) }

        case .closeButton:
            if cardShown { close(&fx) }

        case .mouseDownOutside:
            if phase == .pinned { close(&fx) }

        case .escape(let cardIsKey):
            if cardShown && cardIsKey { close(&fx) }

        case .rebuilt:
            token += 1
            pointerInNotch = false
            pointerInCard = false
            pendingHide = false
            mismatchSince = nil
            fx.append(.cancelTimers)
            if phase == .pinned { fx.append(.watchOutsideClicks(false)) }
            notchShown = false
            phase = .hidden
        case .watchdog(let cardOnScreen, let notchOnScreen, let now):
            let consistent = cardOnScreen == cardShown && notchOnScreen == notchShown
            if consistent {
                mismatchSince = nil
            } else if let since = mismatchSince {
                if now.timeIntervalSince(since) > Self.watchdogGrace {
                    fx.append(.log("watchdog: card \(cardOnScreen ? "on" : "off") screen and notch \(notchOnScreen ? "on" : "off") screen, "
                                   + "but state is \(phase.rawValue); resetting"))
                    reset(&fx, cardOnScreen: cardOnScreen)
                    mismatchSince = nil
                }
            } else {
                mismatchSince = now
            }
        }
        if phase != before {
            fx.insert(.log("\(before.rawValue) → \(phase.rawValue) (\(Self.describe(input)))"), at: 0)
        }
        return fx
    }

    // MARK: transitions

    private mutating func show(_ fx: inout [Effect], why: String) {
        token += 1
        pointerInNotch = false
        pointerInCard = false
        notchShown = true
        fx.append(.cancelTimers)
        fx.append(.showNotch)
        fx.append(.reinstallTracking)
        if !cardShown { phase = .idle }
    }

    private mutating func hideAll(_ fx: inout [Effect], why: String) {
        token += 1
        pendingHide = false
        pointerInNotch = false
        pointerInCard = false
        fx.append(.cancelTimers)
        if cardShown {
            fx.append(.hideCard)
            fx.append(.watchOutsideClicks(false))
        }
        if notchShown { fx.append(.hideNotch) }
        notchShown = false
        phase = .hidden
    }

    private mutating func scheduleClose(_ fx: inout [Effect]) {
        token += 1
        fx.append(.startTimer(.hideDelay, token: token, after: hideDelay))
    }

    private mutating func pin(_ fx: inout [Effect]) {
        let wasShown = cardShown
        token += 1
        phase = .pinned
        fx.append(.cancelTimers)
        if !wasShown { fx.append(.showCard) }
        fx.append(.watchOutsideClicks(true))
    }

    private mutating func close(_ fx: inout [Effect]) {
        token += 1
        let wasPinned = phase == .pinned
        fx.append(.cancelTimers)
        fx.append(.hideCard)
        if wasPinned { fx.append(.watchOutsideClicks(false)) }
        phase = notchShown ? (pointerInNotch ? .hovering : .idle) : .hidden
        // Back on the notch after closing: no instant reopen; it needs a fresh hover.
        if phase == .hovering { phase = .idle }
        applyPendingHide(&fx)
    }

    private mutating func applyPendingHide(_ fx: inout [Effect]) {
        guard pendingHide, !pointerInNotch, !pointerInCard, phase != .pinned else { return }
        hideAll(&fx, why: "deferred hide")
    }

    /// Watchdog: make the state match a consistent picture again, from idle (or hidden).
    private mutating func reset(_ fx: inout [Effect], cardOnScreen: Bool) {
        token += 1
        pointerInNotch = false
        pointerInCard = false
        fx.append(.cancelTimers)
        if cardOnScreen || cardShown { fx.append(.hideCard) }
        if phase == .pinned { fx.append(.watchOutsideClicks(false)) }
        if visibilityAllowed {
            notchShown = true
            fx.append(.showNotch)
            fx.append(.reinstallTracking)
            phase = .idle
        } else {
            if notchShown { fx.append(.hideNotch) }
            notchShown = false
            phase = .hidden
        }
        pendingHide = false
    }

    static func describe(_ input: Input) -> String {
        switch input {
        case .visibility(let allowed): return allowed ? "visibility allowed" : "visibility not allowed"
        case .enterNotch: return "pointer on the notch"
        case .exitNotch: return "pointer left the notch"
        case .enterCard: return "pointer on the card"
        case .exitCard: return "pointer left the card"
        case .timer(let k, _): return k == .hoverDelay ? "hover delay elapsed" : "hide delay elapsed"
        case .notchClick: return "click on the notch"
        case .cardClick: return "click in the card"
        case .shortcut: return "shortcut"
        case .closeButton: return "close button"
        case .mouseDownOutside: return "click outside"
        case .escape: return "Esc"
        case .watchdog: return "watchdog"
        case .rebuilt: return "panels rebuilt"
        }
    }
}

/// The 30-second health check of the notch and card panels: what the state machine believes against what the
/// window server shows. Pure; the controller gathers the snapshot and rebuilds every panel when anything is wrong.
public enum NotchHealth {
    public struct Panel: Equatable, Sendable {
        /// `kCGWindowIsOnscreen`, not `NSWindow.isVisible`.
        public var onScreen: Bool
        public var trackingInstalled: Bool

        public init(onScreen: Bool, trackingInstalled: Bool) {
            self.onScreen = onScreen
            self.trackingInstalled = trackingInstalled
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public var notchShown: Bool
        public var cardShown: Bool
        /// The card is sliding out (its orderOut is pending): neither state is wrong yet.
        public var cardClosing: Bool
        public var notches: [UInt32: Panel]
        public var card: Panel?
        public var wantedDisplays: Set<UInt32>

        public init(notchShown: Bool, cardShown: Bool, cardClosing: Bool = false, notches: [UInt32: Panel], card: Panel?,
                    wantedDisplays: Set<UInt32>) {
            self.notchShown = notchShown
            self.cardShown = cardShown
            self.cardClosing = cardClosing
            self.notches = notches
            self.card = card
            self.wantedDisplays = wantedDisplays
        }
    }

    /// What is wrong, one log phrase each; empty when everything matches.
    public static func problems(_ s: Snapshot) -> [String] {
        var out: [String] = []
        if s.notchShown {
            for (id, p) in s.notches.sorted(by: { $0.key < $1.key }) {
                if !p.onScreen { out.append("notch on display \(id) not on screen") }
                if !p.trackingInstalled { out.append("notch on display \(id) lost its tracking area") }
            }
        }
        if !s.cardClosing {
            let cardOnScreen = s.card?.onScreen ?? false
            if s.cardShown, !cardOnScreen { out.append("card open but not on screen") }
            if !s.cardShown, cardOnScreen { out.append("card on screen but closed") }
            if s.cardShown, cardOnScreen, s.card?.trackingInstalled == false { out.append("card lost its tracking area") }
        }
        if Set(s.notches.keys) != s.wantedDisplays {
            out.append("notches for displays \(s.notches.keys.sorted()) but displays \(s.wantedDisplays.sorted())")
        }
        return out
    }
}
