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
        let engine = WineEngine(directory: URL(filePath: "/e/x"),
                                manifest: EngineManifest(descriptor: EngineCatalog.cx24, installedAt: .now))
        let env = engine.environment(prefix: URL(filePath: "/p/steam"), extra: ["WINEDEBUG": "+seh"])
        #expect(env["WINEPREFIX"] == "/p/steam")
        #expect(env["WINEDEBUG"] == "+seh")
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["PATH"]?.hasPrefix("/e/x/Frameworks/wswine.bundle/bin:") == true)
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"] == "/e/x/Frameworks:/usr/lib")
    }

    @Test func rendererArgumentsRoundTrip() {
        #expect(Renderer(argument: "d3dmetal") == .d3dmetal(nil))
        #expect(Renderer(argument: "d3dmetal-4.0-beta-2") == .d3dmetal("d3dmetal-4.0-beta-2"))
        #expect(Renderer(argument: "DXMT") == .dxmt)
        #expect(Renderer(argument: "vulkan") == nil)
        #expect(D3DMetalImporter.version(fromVolumeName: "Evaluation environment for Windows games 4.0 beta 2") == "4.0-beta-2")
    }
}
