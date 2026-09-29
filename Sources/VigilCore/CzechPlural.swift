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

/// "z" or "ze" before a number, by how the number's genitive starts when read aloud: "ze" before s/š/z/ž and
/// the clusters tř/čt ("ze tří", "ze čtyř", "ze sedmi", "ze sta"), "z" otherwise ("z pěti", "z osmi", "z 20").
public enum CzechPreposition {
    public static func usesZe(_ n: Int) -> Bool {
        let n = abs(n)
        if n >= 1000 { return false } // "z tisíce", "z 1 500": rare in a task list, and "z" reads fine
        if n >= 100 { return n / 100 == 1 ? true : usesZe(n / 100) } // "ze sta", "ze tří set", "z pěti set"
        switch n {
        case 3, 4, 6, 7, 13, 14, 16, 17: return true            // tří, čtyř, šesti, sedmi, třinácti, čtrnácti, šestnácti, sedmnácti
        case 30...39, 40...49, 60...79: return true               // třiceti, čtyřiceti, šedesáti, sedmdesáti
        default: return false                                     // jednoho, dvou, pěti, osmi, devíti, deseti, 11, 12, 15, 18, 19, 20s, 50s, 80s, 90s
        }
    }
}
