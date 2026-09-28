import Foundation

/// Looks up `key` (the English text) in the app's String Catalog tables. Falls back to the key itself,
/// so unit tests and unlocalized runs read in English.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}
