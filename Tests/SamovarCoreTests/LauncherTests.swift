import Foundation
import Testing
@testable import SamovarCore

@Suite struct LauncherTests {
    @Test func splitsWindowsCommandLines() {
        #expect(CommandLine.split("") == [])
        #expect(CommandLine.split("-dx12  -skipintro") == ["-dx12", "-skipintro"])
        #expect(CommandLine.split(#"-config "My Documents\cfg.ini" -w 1920"#) == ["-config", #"My Documents\cfg.ini"#, "-w", "1920"])
        #expect(CommandLine.split(#"-name """#) == ["-name", ""], "empty quotes are an empty argument")
    }

    @Test func convertsWindowsRelativePaths() {
        #expect(GameLauncher.unixRelative(#"bin\x64\game.exe"#) == "bin/x64/game.exe")
        #expect(GameLauncher.unixRelative(#".\game.exe"#) == "game.exe")
        #expect(GameLauncher.unixRelative(#"..\shared\game.exe"#) == "../shared/game.exe")
    }

    @Test func readsLogonStateFromConnectionLog() throws {
        let log = """
        [2026-09-19 15:17:39] [Logged Off, 0, 0] [U:1:0] CCMInterface::SetSteamID( [U:1:0] )
        [2026-09-19 15:20:01] [Logged On, 1, 0] [U:1:1234] CCMInterface::SetSteamID( [U:1:1234] )
        [2026-09-19 15:20:02] Connectivity test: result=Connected
        """
        #expect(SteamClient.lastLogonState(in: log, since: nil) == true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let before = try #require(formatter.date(from: "2026-09-19 15:19:00"))
        let after = try #require(formatter.date(from: "2026-09-19 15:30:00"))
        #expect(SteamClient.lastLogonState(in: log, since: before) == true)
        #expect(SteamClient.lastLogonState(in: log, since: after) == nil, "stale logon from an earlier session")
        #expect(SteamClient.lastLogonState(in: log + "\n[2026-09-19 15:21:00] [Logged Off, 0, 0] x", since: nil) == false)
    }

    @Test func profileDecodesPartialFiles() throws {
        let json = #"{ "renderer": { "dxmt": {} }, "metalHUD": true }"#
        let profile = try JSONDecoder().decode(GameProfile.self, from: Data(json.utf8))
        #expect(profile.renderer == .dxmt)
        #expect(profile.metalHUD)
        #expect(profile.arguments == "")

        let roundTrip = try JSONDecoder().decode(GameProfile.self, from: JSONEncoder().encode(profile))
        #expect(roundTrip == profile)
    }
}
