import Foundation

/// Czech plural categories for counts: 1 subagent, 2–4 subagenti, 0 and 5+ subagentů.
/// Only the whole number decides (unlike Polish or Russian): 22 takes the "many" form, "22 subagentů".
public enum PluralCategory: Equatable, Sendable {
    case one, few, many

    public static func czech(_ n: Int) -> PluralCategory {
        switch abs(n) {
        case 1: return .one
        case 2...4: return .few
        default: return .many
        }
    }
}
