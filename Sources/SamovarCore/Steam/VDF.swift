import Foundation

/// A Valve KeyValues node, as found in text `.vdf`/`.acf` files and binary `appinfo.vdf`.
public enum VDFValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case float(Float)
    case object([(key: String, value: VDFValue)])

    public static func == (lhs: VDFValue, rhs: VDFValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.float(a), .float(b)): a == b
        case let (.object(a), .object(b)): a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    /// Case-insensitive child lookup (Valve keys are not consistently cased).
    public subscript(key: String) -> VDFValue? {
        guard case let .object(children) = self else { return nil }
        return children.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public subscript(path path: String...) -> VDFValue? {
        path.reduce(Optional(self)) { $0?[$1] }
    }

    public var children: [(key: String, value: VDFValue)] {
        if case let .object(children) = self { return children }
        return []
    }

    public var string: String? {
        switch self {
        case let .string(s): s
        case let .int(i): String(i)
        case let .float(f): String(f)
        case .object: nil
        }
    }

    public var int: Int64? {
        switch self {
        case let .int(i): i
        case let .string(s): Int64(s)
        default: nil
        }
    }
}

public enum VDFError: Error, CustomStringConvertible {
    case unexpectedEnd
    case unexpectedToken(String, line: Int)
    case badBinary(String)

    public var description: String {
        switch self {
        case .unexpectedEnd: "VDF: unexpected end of input"
        case let .unexpectedToken(token, line): "VDF: unexpected '\(token)' on line \(line)"
        case let .badBinary(reason): "Binary VDF: \(reason)"
        }
    }
}

/// Parser for the text KeyValues format (`libraryfolders.vdf`, `appmanifest_*.acf`, `config.vdf`).
public enum TextVDF {
    public static func parse(_ text: String) throws -> VDFValue {
        var lexer = Lexer(Array(text.unicodeScalars))
        return .object(try parseObject(&lexer, topLevel: true))
    }

    public static func parse(contentsOf url: URL) throws -> VDFValue {
        try parse(String(decoding: Data(contentsOf: url), as: UTF8.self))
    }

    private static func parseObject(_ lexer: inout Lexer, topLevel: Bool) throws -> [(key: String, value: VDFValue)] {
        var result: [(key: String, value: VDFValue)] = []
        while true {
            guard let token = try lexer.next() else {
                if topLevel { return result }
                throw VDFError.unexpectedEnd
            }
            switch token {
            case .close:
                if topLevel { throw VDFError.unexpectedToken("}", line: lexer.line) }
                return result
            case .open:
                throw VDFError.unexpectedToken("{", line: lexer.line)
            case let .string(key):
                guard let valueToken = try lexer.next() else { throw VDFError.unexpectedEnd }
                switch valueToken {
                case .open: result.append((key, .object(try parseObject(&lexer, topLevel: false))))
                case let .string(value): result.append((key, .string(value)))
                case .close: throw VDFError.unexpectedToken("}", line: lexer.line)
                }
            }
        }
    }

    private enum Token { case open, close, string(String) }

    private struct Lexer {
        let scalars: [Unicode.Scalar]
        var index = 0
        var line = 1

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func next() throws -> Token? {
            skipTrivia()
            guard index < scalars.count else { return nil }
            let c = scalars[index]
            switch c {
            case "{": index += 1; return .open
            case "}": index += 1; return .close
            case "\"": index += 1; return .string(try quoted())
            default: return .string(bare())
            }
        }

        private mutating func skipTrivia() {
            while index < scalars.count {
                let c = scalars[index]
                if c == "\n" { line += 1; index += 1 }
                else if c == " " || c == "\t" || c == "\r" || c == "\u{FEFF}" { index += 1 }
                else if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else if c == "[" {
                    // Conditional like [$WIN32] — ignored.
                    while index < scalars.count, scalars[index] != "]" { index += 1 }
                    index += 1
                } else { break }
            }
        }

        private mutating func quoted() throws -> String {
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                index += 1
                if c == "\"" { return String(out) }
                if c == "\n" { line += 1 }
                if c == "\\", index < scalars.count {
                    let e = scalars[index]
                    index += 1
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    default: out.append("\\"); out.append(e)
                    }
                } else {
                    out.append(c)
                }
            }
            throw VDFError.unexpectedEnd
        }

        private mutating func bare() -> String {
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "{" || c == "}" || c == "\"" { break }
                out.append(c)
                index += 1
            }
            return String(out)
        }
    }
}
