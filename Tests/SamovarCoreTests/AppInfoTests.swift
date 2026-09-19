import Foundation
import Testing
@testable import SamovarCore

/// Builds appinfo.vdf files in memory so the parser can be tested without a Steam login.
private struct AppInfoWriter {
    enum Node { case object([(String, Node)]), string(String), int(Int32) }

    var version: AppInfoFile.Version
    var strings: [String] = []

    private mutating func key(_ k: String, into out: inout Data) {
        if version == .v41 {
            let index = strings.firstIndex(of: k) ?? { strings.append(k); return strings.count - 1 }()
            out.append(le: UInt32(index))
        } else {
            out.append(contentsOf: Array(k.utf8) + [0])
        }
    }

    mutating func encode(_ children: [(String, Node)], into out: inout Data) {
        for (k, node) in children {
            switch node {
            case let .object(inner):
                out.append(0x00); key(k, into: &out); encode(inner, into: &out)
            case let .string(s):
                out.append(0x01); key(k, into: &out); out.append(contentsOf: Array(s.utf8) + [0])
            case let .int(i):
                out.append(0x02); key(k, into: &out); out.append(le: UInt32(bitPattern: i))
            }
        }
        out.append(0x08)
    }

    mutating func file(apps: [(UInt32, [(String, Node)])]) -> Data {
        var body = Data()
        for (id, tree) in apps {
            var blob = Data()
            encode(tree, into: &blob)
            var entry = Data()
            entry.append(le: UInt32(2))                   // info state
            entry.append(le: UInt32(1_700_000_000))       // last updated
            entry.append(le: UInt64(0))                   // PICS token
            entry.append(Data(count: 20))                 // SHA-1
            entry.append(le: UInt32(1))                   // change number
            if version != .v39 { entry.append(Data(count: 20)) } // binary SHA-1
            entry.append(blob)
            body.append(le: id)
            body.append(le: UInt32(entry.count))
            body.append(entry)
        }
        body.append(le: UInt32(0))

        var out = Data()
        out.append(le: version.rawValue)
        out.append(le: UInt32(1))
        if version == .v41 {
            let tableOffset = out.count + 8 + body.count
            out.append(le: UInt64(tableOffset))
            out.append(body)
            out.append(le: UInt32(strings.count))
            for s in strings { out.append(contentsOf: Array(s.utf8) + [0]) }
        } else {
            out.append(body)
        }
        return out
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private func sampleTree() -> [(String, AppInfoWriter.Node)] {
    [("appinfo", .object([
        ("appid", .int(292030)),
        ("common", .object([("name", .string("The Witcher 3"))])),
        ("config", .object([
            ("installdir", .string("The Witcher 3")),
            ("launch", .object([
                ("0", .object([
                    ("executable", .string(#"bin\x64\witcher3.exe"#)),
                    ("type", .string("default")),
                    ("config", .object([("oslist", .string("windows")), ("osarch", .string("64"))])),
                ])),
                ("1", .object([
                    ("executable", .string(#"bin\x64_dx12\witcher3.exe"#)),
                    ("arguments", .string("-dx12")),
                    ("type", .string("option1")),
                    ("config", .object([("oslist", .string("windows"))])),
                ])),
                ("2", .object([
                    ("executable", .string("witcher3.sh")),
                    ("config", .object([("oslist", .string("linux"))])),
                ])),
                ("3", .object([
                    ("executable", .string(#"bin\x64\witcher3_beta.exe"#)),
                    ("config", .object([("oslist", .string("windows")), ("betakey", .string("beta"))])),
                ])),
            ])),
        ])),
    ]))]
}

@Suite struct AppInfoTests {
    @Test(arguments: [AppInfoFile.Version.v39, .v40, .v41])
    func parsesAllSupportedVersions(version: AppInfoFile.Version) throws {
        var writer = AppInfoWriter(version: version)
        let data = writer.file(apps: [(10, [("appinfo", .object([("appid", .int(10))]))]), (292030, sampleTree())])
        let file = try AppInfoFile(data: data)

        #expect(file.version == version)
        #expect(Set(file.appIDs) == [10, 292030])
        let root = try #require(try file.app(292030))
        #expect(root[path: "appinfo", "common", "name"]?.string == "The Witcher 3")
        #expect(root[path: "appinfo", "appid"]?.int == 292030)
    }

    @Test func picksDefaultWindowsLaunchOption() throws {
        var writer = AppInfoWriter(version: .v41)
        let file = try AppInfoFile(data: writer.file(apps: [(292030, sampleTree())]))
        let options = try file.launchOptions(for: 292030)

        #expect(options.count == 4)
        #expect(options.filter(\.isPlayable).map(\.key) == ["0", "1"], "linux and beta options are excluded")
        let preferred = try #require(LaunchOption.preferred(options))
        #expect(preferred.executable == #"bin\x64\witcher3.exe"#)
    }

    @Test func rejectsUnknownMagic() {
        var data = Data()
        data.append(le: UInt32(0x0756_4499))
        data.append(le: UInt32(1))
        #expect(throws: VDFError.self) { try AppInfoFile(data: data) }
    }

    @Test func missingAppReturnsNil() throws {
        var writer = AppInfoWriter(version: .v40)
        let file = try AppInfoFile(data: writer.file(apps: [(292030, sampleTree())]))
        #expect(try file.app(1) == nil)
        #expect(try file.launchOptions(for: 1).isEmpty)
    }
}
