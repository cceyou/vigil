import Foundation

/// Rules for the usage card that slides out of the edge notch. Pure, so they are testable without AppKit.
///
/// A pinned card never claims a key system-wide: Esc belongs to the frontmost app (Claude Code uses it to
/// interrupt). The card only sees Esc once the user has clicked into it and it has become the key window.
public enum PinnedCard {
    public enum Trigger: Equatable, Sendable {
        /// Pointer rests on the notch or the card.
        case hover
        /// Click inside the card (not on one of its buttons).
        case clickInCard
        case notchClick
        /// The global toggle shortcut (⌥⌘U by default).
        case shortcut
        /// The × in the card header.
        case closeButton
        /// A left mouse-down anywhere outside the card and the notches (another app, the desktop, the menu bar).
        case mouseDownOutside
        /// Esc pressed; only delivered to Vigil while the card is the key window.
        case escape(cardIsKey: Bool)
    }

    public enum Reaction: Equatable, Sendable {
        case none
        case show
        case pin
        case close
    }

    public static func reaction(to trigger: Trigger, shown: Bool, pinned: Bool) -> Reaction {
        switch trigger {
        case .hover: return shown ? .none : .show
        case .clickInCard: return pinned ? .none : .pin
        case .notchClick, .shortcut: return shown ? .close : .pin
        case .closeButton: return shown ? .close : .none
        case .mouseDownOutside: return pinned ? .close : .none
        case .escape(let cardIsKey): return shown && cardIsKey ? .close : .none
        }
    }

    /// The card panel may become key only because the user clicked into it, never from hover or the shortcut,
    /// so it never takes focus (or Esc) away from the app the user is typing in.
    public static func becomesKey(on trigger: Trigger) -> Bool {
        trigger == .clickInCard
    }

    /// Whether the outside-click monitor should be running. It watches left mouse-downs only (no key events,
    /// so no Accessibility permission) and only while the card is pinned.
    public static func watchesOutsideClicks(shown: Bool, pinned: Bool) -> Bool {
        shown && pinned
    }
}
