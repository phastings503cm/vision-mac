import Foundation

// MARK: - JSON5, as OpenClaw writes its config
//
// openclaw.json is JSON5: comments, trailing commas, unquoted keys, single-quoted strings, hex numbers,
// Infinity/NaN. Strict JSON is JSON5 too. The result is Foundation values (dictionaries, arrays, strings,
// NSNumber, NSNull), as JSONSerialization gives them. Bad input says where, instead of throwing deep inside.

public enum JSON5 {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var message: String
        public var line: Int
        public var column: Int
        public var description: String { "\(message) at line \(line), column \(column)" }
    }

    /// Nesting deeper than this is refused (a hostile file must not overflow the stack).
    static let maxDepth = 256

    public static func parse(_ text: String) -> Result<Any, ParseError> {
        var parser = Parser(Array(text.unicodeScalars))
        do {
            parser.skipBOM()
            try parser.skipSpace()
            let value = try parser.value(depth: 0)
            try parser.skipSpace()
            guard parser.atEnd else { throw parser.error("unexpected text after the value") }
            return .success(value)
        } catch let error as ParseError {
            return .failure(error)
        } catch {
            return .failure(ParseError(message: "\(error)", line: 0, column: 0))
        }
    }

    /// The parsed value, or nil (with the reason in `error`).
    public static func object(_ text: String) -> [String: Any]? {
        if case .success(let value) = parse(text) { return value as? [String: Any] }
        return nil
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0

        init(_ scalars: [Unicode.Scalar]) { s = scalars }

        var atEnd: Bool { i >= s.count }
        func peek(_ offset: Int = 0) -> Unicode.Scalar? { i + offset < s.count ? s[i + offset] : nil }

        func error(_ message: String) -> ParseError {
            var line = 1, column = 1
            for k in 0..<min(i, s.count) {
                if s[k] == "\n" { line += 1; column = 1 } else { column += 1 }
            }
            return ParseError(message: message, line: line, column: column)
        }

        mutating func skipBOM() { if peek() == "\u{FEFF}" { i += 1 } }

        mutating func skipSpace() throws {
            while let c = peek() {
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{FEFF}" || c == "\u{00A0}"
                    || c == "\u{2028}" || c == "\u{2029}" || c == "\u{000B}" || c == "\u{000C}" {
                    i += 1
                } else if c == "/", peek(1) == "/" {
                    while let d = peek(), d != "\n" { _ = d; i += 1 }
                } else if c == "/", peek(1) == "*" {
                    i += 2
                    while true {
                        guard let d = peek() else { throw error("a /* comment is never closed") }
                        if d == "*", peek(1) == "/" { i += 2; break }
                        i += 1
                    }
                } else {
                    return
                }
            }
        }

        mutating func value(depth: Int) throws -> Any {
            guard depth < JSON5.maxDepth else { throw error("nested too deeply") }
            guard let c = peek() else { throw error("unexpected end of text") }
            switch c {
            case "{": return try object(depth: depth)
            case "[": return try array(depth: depth)
            case "\"", "'": return try string()
            case "t", "f", "n", "I", "N":
                if match("true") { return true }
                if match("false") { return false }
                if match("null") { return NSNull() }
                if match("Infinity") { return Double.infinity }
                if match("NaN") { return Double.nan }
                throw error("unexpected word")
            default:
                if c == "-" || c == "+" || c == "." || ("0"..."9").contains(c) { return try number() }
                throw error("unexpected character '\(c)'")
            }
        }

        mutating func match(_ word: String) -> Bool {
            let scalars = Array(word.unicodeScalars)
            guard i + scalars.count <= s.count, Array(s[i..<(i + scalars.count)]) == scalars else { return false }
            if let after = peek(scalars.count), Self.isIdentifierPart(after) { return false }
            i += scalars.count
            return true
        }

        mutating func object(depth: Int) throws -> [String: Any] {
            i += 1
            var result: [String: Any] = [:]
            try skipSpace()
            if peek() == "}" { i += 1; return result }
            while true {
                try skipSpace()
                if peek() == "}" { i += 1; return result }   // trailing comma
                let key: String
                if peek() == "\"" || peek() == "'" {
                    key = try string()
                } else {
                    key = try identifier()
                }
                try skipSpace()
                guard peek() == ":" else { throw error("expected ':' after \"\(key)\"") }
                i += 1
                try skipSpace()
                result[key] = try value(depth: depth + 1)
                try skipSpace()
                if peek() == "," { i += 1; continue }
                if peek() == "}" { i += 1; return result }
                throw error("expected ',' or '}'")
            }
        }

        mutating func array(depth: Int) throws -> [Any] {
            i += 1
            var result: [Any] = []
            while true {
                try skipSpace()
                if peek() == "]" { i += 1; return result }
                result.append(try value(depth: depth + 1))
                try skipSpace()
                if peek() == "," { i += 1; continue }
                if peek() == "]" { i += 1; return result }
                throw error("expected ',' or ']'")
            }
        }

        static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
            c == "$" || c == "_" || c.properties.isAlphabetic
        }

        static func isIdentifierPart(_ c: Unicode.Scalar) -> Bool {
            isIdentifierStart(c) || ("0"..."9").contains(c) || c == "\u{200C}" || c == "\u{200D}"
                || c.properties.generalCategory == .decimalNumber || c.properties.generalCategory == .nonspacingMark
        }

        mutating func identifier() throws -> String {
            guard let first = peek(), Self.isIdentifierStart(first) else { throw error("expected a key") }
            var out = String.UnicodeScalarView()
            while let c = peek(), Self.isIdentifierPart(c) { out.append(c); i += 1 }
            return String(out)
        }

        mutating func string() throws -> String {
            guard let quote = peek() else { throw error("expected a string") }
            i += 1
            var out = String.UnicodeScalarView()
            while true {
                guard let c = peek() else { throw error("a string is never closed") }
                i += 1
                if c == quote { return String(out) }
                if c == "\n" || c == "\r" { throw error("a string runs past the end of its line") }
                guard c == "\\" else { out.append(c); continue }
                guard let e = peek() else { throw error("a string ends in a backslash") }
                i += 1
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "v": out.append("\u{0B}")
                case "0" where !(peek().map { ("0"..."9").contains($0) } ?? false): out.append("\u{0}")
                case "\n", "\u{2028}", "\u{2029}": break               // line continuation
                case "\r": if peek() == "\n" { i += 1 }
                case "x":
                    let code = try hex(2)
                    out.append(Unicode.Scalar(code) ?? "?")
                case "u":
                    var code = try hex(4)
                    // A surrogate pair spells one scalar.
                    if (0xD800...0xDBFF).contains(code), peek() == "\\", peek(1) == "u" {
                        i += 2
                        let low = try hex(4)
                        if (0xDC00...0xDFFF).contains(low) { code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00) }
                    }
                    out.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: out.append(e)
                }
            }
        }

        mutating func hex(_ count: Int) throws -> UInt32 {
            var code: UInt32 = 0
            for _ in 0..<count {
                guard let c = peek(), let digit = Self.hexValue(c) else { throw error("bad escape in a string") }
                code = code * 16 + digit
                i += 1
            }
            return code
        }

        static func hexValue(_ c: Unicode.Scalar) -> UInt32? {
            switch c {
            case "0"..."9": c.value - 48
            case "a"..."f": c.value - 87
            case "A"..."F": c.value - 55
            default: nil
            }
        }

        mutating func number() throws -> Any {
            var sign = 1.0
            if peek() == "-" { sign = -1; i += 1 } else if peek() == "+" { i += 1 }
            if match("Infinity") { return sign * Double.infinity }
            if match("NaN") { return Double.nan }
            if peek() == "0", peek(1) == "x" || peek(1) == "X" {
                i += 2
                var value: Int64 = 0
                var digits = 0
                while let c = peek(), let digit = Self.hexValue(c) {
                    value = value &* 16 &+ Int64(digit)
                    i += 1
                    digits += 1
                }
                guard digits > 0 else { throw error("a hex number has no digits") }
                return NSNumber(value: Int64(sign) * value)
            }
            var text = ""
            while let c = peek(), ("0"..."9").contains(c) || c == "." || c == "e" || c == "E" || c == "+" || c == "-" {
                text.unicodeScalars.append(c)
                i += 1
            }
            if text.hasPrefix(".") { text = "0" + text }
            if text.hasSuffix(".") { text += "0" }
            if !text.contains("."), !text.lowercased().contains("e"), let whole = Int64(text) {
                return NSNumber(value: sign < 0 ? -whole : whole)
            }
            guard let double = Double(text) else { throw error("a number can't be read") }
            return NSNumber(value: sign * double)
        }
    }
}
