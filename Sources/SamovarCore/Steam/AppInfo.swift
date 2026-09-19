import Foundation

/// Reader for Steam's binary `appcache/appinfo.vdf` (formats v39–v41).
///
/// Format reference: https://github.com/SteamDatabase/SteamAppInfo
public struct AppInfoFile: Sendable {
    public enum Version: UInt32, Sendable {
        case v39 = 0x0756_4427
        case v40 = 0x0756_4428 // + binary VDF SHA-1
        case v41 = 0x0756_4429 // + string table
    }

    public let version: Version
    private let data: Data
    private let stringTable: [String]?
    /// Byte offset of each app's binary VDF blob.
    private let entries: [Int: Range<Int>]

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        var reader = ByteReader(data: data)
        let magic = try reader.u32()
        guard let version = Version(rawValue: magic) else {
            throw VDFError.badBinary(String(format: "unsupported appinfo magic 0x%08x", magic))
        }
        _ = try reader.u32() // universe

        var stringTable: [String]?
        if version == .v41 {
            let offset = Int(try reader.i64())
            guard offset > 0, offset < data.count else { throw VDFError.badBinary("string table offset out of range") }
            var tableReader = ByteReader(data: data, offset: offset)
            let count = Int(try tableReader.u32())
            var strings: [String] = []
            strings.reserveCapacity(count)
            for _ in 0..<count { strings.append(try tableReader.cString()) }
            stringTable = strings
        }

        let headerSize = 4 + 4 + 8 + 20 + 4 + (version == .v39 ? 0 : 20) // state, updated, token, sha, change, [binary sha]
        var entries: [Int: Range<Int>] = [:]
        while true {
            let appID = try reader.u32()
            if appID == 0 { break }
            let size = Int(try reader.u32())
            let entryStart = reader.offset
            guard size >= headerSize, entryStart + size <= data.count else {
                throw VDFError.badBinary("entry for app \(appID) overruns file")
            }
            entries[Int(appID)] = (entryStart + headerSize)..<(entryStart + size)
            reader.offset = entryStart + size
        }

        self.version = version
        self.data = data
        self.stringTable = stringTable
        self.entries = entries
    }

    public var appIDs: [Int] { Array(entries.keys) }

    /// The app's KeyValues root (usually a single `appinfo` object).
    public func app(_ id: Int) throws -> VDFValue? {
        guard let range = entries[id] else { return nil }
        var reader = ByteReader(data: data, offset: range.lowerBound)
        let value = try BinaryVDF.parseObject(&reader, strings: stringTable)
        guard reader.offset <= range.upperBound else { throw VDFError.badBinary("app \(id) blob overruns its entry") }
        return value
    }

    /// Launch options for an app, filtered to what can run on Windows.
    public func launchOptions(for id: Int) throws -> [LaunchOption] {
        guard let root = try app(id) else { return [] }
        let info = root["appinfo"] ?? root
        return LaunchOption.parse(info[path: "config", "launch"])
    }
}

/// One entry of `appinfo.config.launch`.
public struct LaunchOption: Sendable, Hashable, Codable {
    public let key: String
    public let executable: String
    public let arguments: String
    public let workingDirectory: String?
    public let type: String?
    public let description: String?
    public let osList: [String]
    public let osArch: String?
    public let betaKey: String?

    /// Types that aren't a way to play the game.
    static let nonPlayableTypes: Set<String> = ["none", "server", "editor", "manual", "vr", "config", "othervr"]

    static func parse(_ launch: VDFValue?) -> [LaunchOption] {
        guard let launch else { return [] }
        return launch.children.compactMap { key, value -> LaunchOption? in
            guard let exe = value["executable"]?.string, !exe.isEmpty else { return nil }
            let osList = (value[path: "config", "oslist"]?.string ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return LaunchOption(
                key: key,
                executable: exe,
                arguments: value["arguments"]?.string ?? "",
                workingDirectory: value["workingdir"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                type: value["type"]?.string?.lowercased(),
                description: value["description"]?.string,
                osList: osList,
                osArch: value[path: "config", "osarch"]?.string,
                betaKey: value[path: "config", "betakey"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    public var runsOnWindows: Bool {
        osList.isEmpty || osList.contains("windows")
    }

    public var isPlayable: Bool {
        runsOnWindows && betaKey == nil && !Self.nonPlayableTypes.contains(type ?? "")
    }

    /// Picks the option Steam's "Play" button would use: default type first, then 64-bit.
    public static func preferred(_ options: [LaunchOption]) -> LaunchOption? {
        options.filter(\.isPlayable).min { rank($0) < rank($1) }
    }

    private static func rank(_ option: LaunchOption) -> (Int, Int, Int, Int) {
        let typeRank = (option.type == nil || option.type == "default") ? 0 : 1
        let windowsRank = option.osList.contains("windows") ? 0 : 1
        let archRank = option.osArch == "64" ? 0 : (option.osArch == nil ? 1 : 2)
        return (typeRank, windowsRank, archRank, Int(option.key) ?? .max)
    }
}

/// Binary KeyValues as stored in appinfo.vdf.
enum BinaryVDF {
    private enum Tag: UInt8 {
        case object = 0x00, string = 0x01, int32 = 0x02, float32 = 0x03, pointer = 0x04
        case wideString = 0x05, color = 0x06, uint64 = 0x07, end = 0x08, int64 = 0x0A
        case alternateEnd = 0x0B
    }

    static func parseObject(_ reader: inout ByteReader, strings: [String]?) throws -> VDFValue {
        var children: [(key: String, value: VDFValue)] = []
        while true {
            let raw = try reader.u8()
            guard let tag = Tag(rawValue: raw) else { throw VDFError.badBinary(String(format: "unknown tag 0x%02x", raw)) }
            if tag == .end || tag == .alternateEnd { return .object(children) }
            let key: String
            if let strings {
                let index = Int(try reader.u32())
                guard index < strings.count else { throw VDFError.badBinary("string index \(index) out of range") }
                key = strings[index]
            } else {
                key = try reader.cString()
            }
            let value: VDFValue
            switch tag {
            case .object: value = try parseObject(&reader, strings: strings)
            case .string: value = .string(try reader.cString())
            case .int32, .pointer, .color: value = .int(Int64(Int32(bitPattern: try reader.u32())))
            case .float32: value = .float(Float(bitPattern: try reader.u32()))
            case .uint64: value = .int(Int64(bitPattern: try reader.u64()))
            case .int64: value = .int(try reader.i64())
            case .wideString: value = .string(try reader.wideString())
            case .end, .alternateEnd: preconditionFailure()
            }
            children.append((key, value))
        }
    }
}

/// Little-endian cursor over `Data`.
struct ByteReader {
    let data: Data
    var offset: Int

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    private mutating func take(_ count: Int) throws -> Data.SubSequence {
        let start = data.startIndex + offset
        guard count >= 0, start + count <= data.endIndex else { throw VDFError.unexpectedEnd }
        offset += count
        return data[start..<(start + count)]
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let bytes = try take(MemoryLayout<T>.size)
        return bytes.reversed().reduce(T.zero) { $0 << 8 | T($1) }
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
    mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try integer(UInt64.self)) }

    mutating func cString() throws -> String {
        let start = data.startIndex + offset
        guard let end = data[start...].firstIndex(of: 0) else { throw VDFError.unexpectedEnd }
        let string = String(decoding: data[start..<end], as: UTF8.self)
        offset += end - start + 1
        return string
    }

    mutating func wideString() throws -> String {
        var units: [UInt16] = []
        while true {
            let unit = UInt16(try u8()) | UInt16(try u8()) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }
}
