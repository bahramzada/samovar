import Foundation
import Testing
@testable import SamovarCore

@Suite struct SamovarPathsTests {
    @Test func layoutIsRootedAtGivenDirectory() {
        let root = URL(filePath: "/tmp/samovar-test", directoryHint: .isDirectory)
        let paths = SamovarPaths(root: root)
        #expect(paths.engine("gptk").path == "/tmp/samovar-test/Engines/gptk")
        #expect(paths.prefix("steam").path == "/tmp/samovar-test/Prefixes/steam")
        #expect(paths.downloads.path == "/tmp/samovar-test/Cache/Downloads")
    }

    @Test func engineEnvironmentPointsAtPrefix() throws {
        let manifest = EngineManifest(id: "x", displayName: "X", installedAt: .now)
        let engine = WineEngine(id: "x", directory: URL(filePath: "/e/x"), manifest: manifest)
        let env = engine.environment(prefix: URL(filePath: "/p/steam"), extra: ["WINEDEBUG": "+seh"])
        #expect(env["WINEPREFIX"] == "/p/steam")
        #expect(env["WINEDEBUG"] == "+seh")
        #expect(env["PATH"]?.hasPrefix("/e/x/wine/bin:") == true)
    }
}
