import CoreGraphics
import Foundation

/// One on-screen window as `CGWindowListCopyWindowInfo` reports it without Screen Recording permission
/// (no titles): owner, pid, layer, alpha and bounds in global top-left coordinates.
public struct WindowEntry: Codable, Equatable, Sendable {
    public var owner: String
    public var pid: Int32
    public var layer: Int
    public var alpha: Double
    public var bounds: CGRect

    public init(owner: String, pid: Int32, layer: Int, alpha: Double = 1, bounds: CGRect) {
        self.owner = owner
        self.pid = pid
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }
}

/// The windows on the current Space(s), front to back, plus the display in question.
public struct SpaceSnapshot: Equatable, Sendable {
    /// The display's frame in global top-left coordinates (CG).
    public var display: CGRect
    public var windows: [WindowEntry]
    /// Vigil's own pid (its windows never count).
    public var ownPID: Int32

    public init(display: CGRect, windows: [WindowEntry], ownPID: Int32 = 0) {
        self.display = display
        self.windows = windows
        self.ownPID = ownPID
    }
}

/// Is a real native full-screen Space showing on a display? Never true for a maximized (zoomed, "Fill") window.
///
/// Two independent signals, both seen on every native full-screen Space on macOS 26 and on no regular Space
/// (recorded on a real machine, see `Tests/VigilTests/Fixtures/windows.jsonl`):
/// 1. The full-screen app owns a transparent strip across the top of the display above the normal window
///    layer (the menu bar / title bar reveal area of the full-screen Space).
/// 2. The Dock draws a full-screen backdrop covering the display one layer above its wallpaper.
/// Window size alone is not a signal: with the menu bar shown in full screen the window is as tall as a
/// maximized one, and with the menu bar hidden on the desktop a maximized window covers the whole display.
public enum FullScreenDetector {
    private static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1.5 }

    public static func isNativeFullScreen(_ s: SpaceSnapshot) -> Bool {
        appRevealStrip(s) != nil || dockBackdrop(s)
    }

    /// The app whose full-screen Space is showing, if signal 1 is present.
    public static func appRevealStrip(_ s: SpaceSnapshot) -> WindowEntry? {
        let d = s.display
        return s.windows.first { w in
            w.pid != s.ownPID && w.owner != "Window Server" && w.owner != "Dock"
                && w.layer > 0 && w.layer < 1000
                && near(w.bounds.minX, d.minX) && near(w.bounds.minY, d.minY) && near(w.bounds.width, d.width)
                && w.bounds.height > 0 && w.bounds.height <= 60
                // ...and the same app has a normal window filling the rest of the display.
                && s.windows.contains { o in
                    o.pid == w.pid && o.layer == 0 && near(o.bounds.width, d.width) && near(o.bounds.maxY, d.maxY)
                        && o.bounds.minY <= d.minY + 120 // below the menu bar and a toolbar strip (Terminal)
                }
        }
    }

    /// Signal 2: two Dock windows cover the display below the normal layer; the upper one is the backdrop.
    public static func dockBackdrop(_ s: SpaceSnapshot) -> Bool {
        let covering = s.windows.filter { w in
            w.owner == "Dock" && w.layer < 0 && near(w.bounds.minX, s.display.minX) && near(w.bounds.minY, s.display.minY)
                && near(w.bounds.width, s.display.width) && near(w.bounds.height, s.display.height)
        }
        return Set(covering.map(\.layer)).count >= 2
    }
}

/// Why the notch is (not) on screen, for the self-test and the log.
public enum NotchVisibility: Equatable, Sendable {
    case visible
    case hiddenFullScreen(app: String?)
    case disabled
    case notOnThisDisplay

    public var isVisible: Bool { self == .visible }

    /// For the log: "visible", "hidden: Claude is in full screen".
    public var logText: String {
        switch self {
        case .visible: return "visible"
        case .hiddenFullScreen(let app): return "hidden: \(app ?? "an app") is in full screen"
        case .disabled: return "hidden: turned off"
        case .notOnThisDisplay: return "hidden: not on this display"
        }
    }

    public static func decide(enabled: Bool, onThisDisplay: Bool, hideInFullScreen: Bool, fullScreen: Bool,
                              fullScreenApp: String?) -> NotchVisibility {
        guard enabled else { return .disabled }
        guard onThisDisplay else { return .notOnThisDisplay }
        if hideInFullScreen && fullScreen { return .hiddenFullScreen(app: fullScreenApp) }
        return .visible
    }
}
