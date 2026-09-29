import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    public var config = Config()
    public var dryRun = false
    public var hasSeenOnboarding = false
    /// Settings migrations applied so far (nil = saved before migrations existed).
    public var revision: Int?
    public static let currentRevision = 2
    public init() { revision = Self.currentRevision }

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
