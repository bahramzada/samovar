import Foundation
import Testing
@testable import SamovarCore

@Suite struct TextVDFTests {
    @Test func parsesNestedObjectsAndEscapes() throws {
        let text = #"""
        "libraryfolders"
        {
            "0"
            {
                "path"      "C:\\Program Files (x86)\\Steam"
                "label"     ""
                "apps"
                {
                    "228980"    "123"
                }
            }
            // comment
            "1" { "path" "D:\\Games" }
        }
        """#
        let root = try TextVDF.parse(text)
        #expect(root[path: "libraryfolders", "0", "path"]?.string == #"C:\Program Files (x86)\Steam"#)
        #expect(root[path: "libraryfolders", "0", "apps", "228980"]?.int == 123)
        #expect(root[path: "libraryfolders", "1", "path"]?.string == #"D:\Games"#)
        #expect(root["LIBRARYFOLDERS"] != nil, "lookup is case-insensitive")
    }

    @Test func rejectsUnbalancedBraces() {
        #expect(throws: VDFError.self) { try TextVDF.parse(#""a" { "b" "c" "#) }
        #expect(throws: VDFError.self) { try TextVDF.parse(#""a" "b" }"#) }
    }
}

@Suite struct SteamLibraryTests {
    /// Builds a fake prefix with a Steam install, a second library on D: and two manifests.
    private func makePrefix() throws -> URL {
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appending(path: "samovar-lib-\(UUID().uuidString)", directoryHint: .isDirectory)
        let steamapps = prefix.appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
        let games = prefix.appending(path: "games")
        try fm.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try fm.createDirectory(at: games.appending(path: "steamapps"), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appending(path: "dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/d:").path, withDestinationPath: games.path)

        try #"""
        "libraryfolders" {
            "0" { "path" "C:\\Program Files (x86)\\Steam" }
            "1" { "path" "D:\\" }
        }
        """#.write(to: steamapps.appending(path: "libraryfolders.vdf"), atomically: true, encoding: .utf8)
        try #"""
        "AppState" { "appid" "292030" "name" "The Witcher 3" "installdir" "The Witcher 3"
                     "StateFlags" "4" "SizeOnDisk" "1000" "LastPlayed" "1700000000" }
        """#.write(to: steamapps.appending(path: "appmanifest_292030.acf"), atomically: true, encoding: .utf8)
        try #"""
        "AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "installdir" "Steamworks Shared" "StateFlags" "4" }
        """#.write(to: steamapps.appending(path: "appmanifest_228980.acf"), atomically: true, encoding: .utf8)
        try #"""
        "AppState" { "appid" "1145360" "name" "Hades" "installdir" "Hades" "StateFlags" "1026" }
        """#.write(to: games.appending(path: "steamapps/appmanifest_1145360.acf"), atomically: true, encoding: .utf8)
        return prefix
    }

    @Test func findsAppsAcrossLibrariesAndSkipsRedistributables() throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let library = SteamLibrary(prefix: prefix)

        #expect(library.libraryFolders().count == 2)
        let apps = library.apps()
        #expect(apps.map(\.id) == [1145360, 292030], "sorted by name, redistributables removed")

        let witcher = try #require(apps.first { $0.id == 292030 })
        #expect(witcher.isInstalled)
        #expect(witcher.installPath.path.hasSuffix("drive_c/Program Files (x86)/Steam/steamapps/common/The Witcher 3"))
        #expect(witcher.lastPlayed == Date(timeIntervalSince1970: 1_700_000_000))

        let hades = try #require(apps.first { $0.id == 1145360 })
        #expect(!hades.isInstalled, "StateFlags 1026 = update required")
        #expect(hades.installPath.path.hasSuffix("games/steamapps/common/Hades"))
    }

    @Test func mapsWindowsPathsThroughDosDevices() throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let library = SteamLibrary(prefix: prefix)
        let url = try #require(library.unixPath(forWindowsPath: #"C:\users\steamuser"#))
        #expect(url.path.hasSuffix("drive_c/users/steamuser"))
        #expect(library.unixPath(forWindowsPath: "relative\\path") == nil)
    }
}
