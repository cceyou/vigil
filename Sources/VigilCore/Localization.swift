import Foundation

/// Looks up `key` (the English text) in the app's String Catalog tables. Falls back to the key itself,
/// so unit tests and unlocalized runs read in English.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}

public enum Durations {
    /// 45 -> "45 s", 900 -> "15 min", 7200 -> "2 h".
    public static func short(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h"
    }
}
