import Foundation

/// Strict RFC 8259 syntax check. Foundation's parsers silently accept trailing commas on recent macOS,
/// but a settings.json we are asked to edit must be *valid* JSON or we refuse to touch it.
enum StrictJSON {
    struct Failure: Error, CustomStringConvertible {
        let offset: Int
        let message: String
        var description: String { "\(message) at byte \(offset)" }
    }

    static func validate(_ data: Data) throws {
        var p = Parser(bytes: [UInt8](data))
        p.skipWhitespace()
        try p.parseValue(depth: 0)
        p.skipWhitespace()
        guard p.index == p.bytes.count else { throw Failure(offset: p.index, message: "unexpected trailing content") }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipWhitespace() {
            while let c = current, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { index += 1 }
        }

        func fail(_ message: String) -> Failure { Failure(offset: index, message: message) }

        mutating func expect(_ byte: UInt8, _ what: String) throws {
            guard current == byte else { throw fail("expected \(what)") }
            index += 1
        }

        mutating func parseValue(depth: Int) throws {
            guard depth < 512 else { throw fail("nesting too deep") }
            guard let c = current else { throw fail("unexpected end of input") }
            switch c {
            case UInt8(ascii: "{"): try parseObject(depth: depth)
            case UInt8(ascii: "["): try parseArray(depth: depth)
            case UInt8(ascii: "\""): try parseString()
            case UInt8(ascii: "t"): try parseLiteral("true")
            case UInt8(ascii: "f"): try parseLiteral("false")
            case UInt8(ascii: "n"): try parseLiteral("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try parseNumber()
            default: throw fail("unexpected character")
            }
        }

        mutating func parseLiteral(_ text: String) throws {
            for b in text.utf8 {
                guard current == b else { throw fail("invalid literal") }
                index += 1
            }
        }

        mutating func parseObject(depth: Int) throws {
            index += 1 // {
            skipWhitespace()
            if current == UInt8(ascii: "}") { index += 1; return }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\"") else { throw fail("expected a string key") }
                try parseString()
                skipWhitespace()
                try expect(UInt8(ascii: ":"), "':'")
                skipWhitespace()
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if current == UInt8(ascii: ",") { index += 1; continue } // a key must follow: no trailing comma
                try expect(UInt8(ascii: "}"), "',' or '}'")
                return
            }
        }

        mutating func parseArray(depth: Int) throws {
            index += 1 // [
            skipWhitespace()
            if current == UInt8(ascii: "]") { index += 1; return }
            while true {
                skipWhitespace()
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if current == UInt8(ascii: ",") { index += 1; continue } // a value must follow: no trailing comma
                try expect(UInt8(ascii: "]"), "',' or ']'")
                return
            }
        }

        mutating func parseString() throws {
            index += 1 // opening quote
            while let c = current {
                index += 1
                switch c {
                case UInt8(ascii: "\""): return
                case 0x00..<0x20: throw fail("control character in string")
                case UInt8(ascii: "\\"):
                    guard let e = current else { throw fail("unterminated escape") }
                    index += 1
                    switch e {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                         UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"): break
                    case UInt8(ascii: "u"):
                        for _ in 0..<4 {
                            guard let h = current, (0x30...0x39).contains(h) || (0x41...0x46).contains(h) || (0x61...0x66).contains(h)
                            else { throw fail("invalid \\u escape") }
                            index += 1
                        }
                    default: throw fail("invalid escape")
                    }
                default: break
                }
            }
            throw fail("unterminated string")
        }

        mutating func parseNumber() throws {
            if current == UInt8(ascii: "-") { index += 1 }
            guard let first = current else { throw fail("invalid number") }
            if first == UInt8(ascii: "0") { index += 1 }
            else if (0x31...0x39).contains(first) { while let d = current, (0x30...0x39).contains(d) { index += 1 } }
            else { throw fail("invalid number") }
            if current == UInt8(ascii: ".") {
                index += 1
                guard let d = current, (0x30...0x39).contains(d) else { throw fail("invalid fraction") }
                while let d = current, (0x30...0x39).contains(d) { index += 1 }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                index += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
                guard let d = current, (0x30...0x39).contains(d) else { throw fail("invalid exponent") }
                while let d = current, (0x30...0x39).contains(d) { index += 1 }
            }
        }
    }
}
