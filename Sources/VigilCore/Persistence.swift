import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    public var config = Config()
    public var dryRun = false
    public var hasSeenOnboarding = false
    public init() {}
}

public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "vigil.settings.v1"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
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
