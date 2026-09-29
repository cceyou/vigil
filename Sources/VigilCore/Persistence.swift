import Foundation

public enum AccentChoice: String, Codable, CaseIterable, Sendable { case green, blue, orange, purple }

public enum NotchDisplays: String, Codable, CaseIterable, Sendable {
    /// One notch on every display.
    case all
    /// Only on the display with the menu bar.
    case main
}

/// A global shortcut in Carbon terms (virtual key code + Carbon modifier mask).
public struct HotKeySpec: Codable, Equatable, Sendable {
    public var enabled = true
    /// kVK_ANSI_U.
    public var keyCode: UInt32 = 32
    /// cmdKey | optionKey.
    public var modifiers: UInt32 = 0x0100 | 0x0800

    public init(enabled: Bool = true, keyCode: UInt32 = 32, modifiers: UInt32 = 0x0100 | 0x0800) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Look and edge-notch preferences.
public struct UISettings: Codable, Equatable, Sendable {
    public var notchEnabled = true
    /// Vertical position of the notch, 0.2...0.8 of the screen height (from the bottom).
    public var notchPosition = 0.5
    public var notchDisplays = NotchDisplays.all
    /// How long the pointer rests on the notch before the card opens.
    public var hoverDelay: TimeInterval = 0.18
    public var hideInFullScreen = true
    public var shortcut = HotKeySpec()
    public var accent = AccentChoice.green
    public var usageNotifications = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UISettings()
        notchEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchEnabled) ?? d.notchEnabled
        notchPosition = min(0.8, max(0.2, try c.decodeIfPresent(Double.self, forKey: .notchPosition) ?? d.notchPosition))
        notchDisplays = (try? c.decodeIfPresent(NotchDisplays.self, forKey: .notchDisplays)) ?? d.notchDisplays
        hoverDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .hoverDelay) ?? d.hoverDelay
        hideInFullScreen = try c.decodeIfPresent(Bool.self, forKey: .hideInFullScreen) ?? d.hideInFullScreen
        shortcut = try c.decodeIfPresent(HotKeySpec.self, forKey: .shortcut) ?? d.shortcut
        accent = (try? c.decodeIfPresent(AccentChoice.self, forKey: .accent)) ?? d.accent
        usageNotifications = try c.decodeIfPresent(Bool.self, forKey: .usageNotifications) ?? d.usageNotifications
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    public var config = Config()
    public var dryRun = false
    public var hasSeenOnboarding = false
    public var ui = UISettings()
    /// Settings migrations applied so far (nil = saved before migrations existed).
    public var revision: Int?
    public static let currentRevision = 2
    public init() { revision = Self.currentRevision }

    // Every key is optional: settings saved by an older build (without `ui`, say) must load, not reset to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        config = try c.decodeIfPresent(Config.self, forKey: .config) ?? d.config
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? d.dryRun
        hasSeenOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasSeenOnboarding) ?? d.hasSeenOnboarding
        ui = try c.decodeIfPresent(UISettings.self, forKey: .ui) ?? d.ui
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
    }

    /// Revision 2: the low-battery default dropped from 15 % to 5 %. At 15 % the guard kept tripping in normal
    /// use and the Mac slept as soon as the lid closed; a value still at the old default moves to the new one.
    public mutating func migrate() {
        if (revision ?? 1) < 2, config.lowBatteryThreshold == 15 { config.lowBatteryThreshold = 5 }
        revision = Self.currentRevision
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "vigil.settings.v1"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        var migrated = s
        migrated.migrate()
        if migrated != s { save(migrated) }
        return migrated
    }

    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}

/// Last 50 sessions, persisted as JSON in Application Support.
public final class HistoryStore: @unchecked Sendable {
    public static let limit = 50
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    /// Newest first.
    public func load() -> [SessionRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url), let list = try? Self.decoder.decode([SessionRecord].self, from: data) else { return [] }
        return list
    }

    @discardableResult
    public func append(_ record: SessionRecord) -> [SessionRecord] {
        var list = load()
        list.insert(record, at: 0)
        if list.count > Self.limit { list = Array(list.prefix(Self.limit)) }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(list) { try? data.write(to: url, options: .atomic) }
        return list
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
