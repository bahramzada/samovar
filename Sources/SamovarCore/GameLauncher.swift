import Foundation

public enum LaunchError: Error, CustomStringConvertible {
    case unknownApp(Int)
    case notInstalled(String)
    case noLaunchOption(String)
    case executableMissing(URL)
    case steamNotReady

    public var description: String {
        switch self {
        case let .unknownApp(id): "No installed Steam app with id \(id)"
        case let .notInstalled(name): "\(name) is not fully installed yet"
        case let .noLaunchOption(name): "\(name) has no Windows launch option in appinfo; set an executable in its profile"
        case let .executableMissing(url): "Executable not found: \(url.path)"
        case .steamNotReady: "Steam did not come up in time"
        }
    }
}

/// Everything needed to start one game, resolved but not yet run.
public struct LaunchPlan: Sendable {
    public let app: SteamApp
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let variant: RendererVariant
    public let environment: [String: String]
    public let log: URL
}

/// Starts games directly (not via `steam -applaunch`) so each one gets its own renderer and environment.
public struct GameLauncher: Sendable {
    public let env: SamovarEnvironment

    public init(env: SamovarEnvironment) { self.env = env }

    public var profiles: ProfileStore { ProfileStore(paths: env.paths) }

    public var appInfoURL: URL { env.steam.steamRoot.appending(path: "appcache/appinfo.vdf") }

    public func launchOptions(for appID: Int) -> [LaunchOption] {
        (try? AppInfoFile(contentsOf: appInfoURL).launchOptions(for: appID)) ?? []
    }

    public func plan(appID: Int, profile: GameProfile? = nil) throws -> LaunchPlan {
        guard let app = env.steam.library.app(id: appID) else { throw LaunchError.unknownApp(appID) }
        guard app.isInstalled else { throw LaunchError.notInstalled(app.name) }
        let profile = profile ?? profiles.load(appID)

        // Executable: profile override, else the chosen/preferred appinfo launch option.
        let relativeExe: String
        var arguments: [String] = []
        var workingDir: String?
        if let manual = profile.executable, !manual.isEmpty {
            relativeExe = manual
        } else {
            let options = launchOptions(for: appID)
            let option = profile.launchOption.flatMap { key in options.first { $0.key == key } }
                ?? LaunchOption.preferred(options)
            guard let option else { throw LaunchError.noLaunchOption(app.name) }
            relativeExe = option.executable
            arguments = CommandLine.split(option.arguments)
            workingDir = option.workingDirectory
        }
        arguments += CommandLine.split(profile.arguments)

        let executable = app.installPath.appending(path: Self.unixRelative(relativeExe))
        guard FileManager.default.fileExists(atPath: executable.path) else { throw LaunchError.executableMissing(executable) }
        let workingDirectory = workingDir.map { app.installPath.appending(path: Self.unixRelative($0), directoryHint: .isDirectory) }
            ?? executable.deletingLastPathComponent()

        let variant = try env.engine.variant(for: profile.renderer, paths: env.paths)

        var extra: [String: String] = [
            // Makes SteamAPI believe Steam launched the game, so it doesn't relaunch itself through Steam.
            "SteamAppId": String(appID),
            "SteamGameId": String(appID),
            "SteamOverlayGameId": String(appID),
        ]
        if profile.metalHUD { extra["MTL_HUD_ENABLED"] = "1" }
        if !profile.dllOverrides.isEmpty {
            extra["WINEDLLOVERRIDES"] = profile.dllOverrides.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        }
        extra.merge(profile.environment) { _, new in new }

        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted).dateTimeSeparator(.standard))
        let log = env.paths.logs.appending(path: "\(appID)-\(stamp).log")

        return LaunchPlan(app: app, executable: executable, arguments: arguments, workingDirectory: workingDirectory,
                          variant: variant, environment: extra, log: log)
    }

    /// Makes sure Steam is running, then starts the game. The returned process lives as long as the game.
    public func launch(_ plan: LaunchPlan, steamTimeout: TimeInterval = 120) async throws -> Process {
        try await ensureSteam(timeout: steamTimeout)
        return try env.prefix.spawn([plan.executable.path] + plan.arguments, variant: plan.variant,
                                    environment: plan.environment, workingDirectory: plan.workingDirectory, log: plan.log)
    }

    /// Starts Steam silently if needed and waits until it has logged on.
    public func ensureSteam(timeout: TimeInterval) async throws {
        let steam = env.steam
        if steam.isRunning, steam.isLoggedOn() { return }
        let startedAt = Date.now
        if !steam.isRunning { try steam.start(silent: true) }
        while Date.now.timeIntervalSince(startedAt) < timeout {
            if steam.isRunning, steam.isLoggedOn(since: startedAt.addingTimeInterval(-5)) { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw LaunchError.steamNotReady
    }

    static func unixRelative(_ windowsPath: String) -> String {
        var path = windowsPath.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") { path.removeFirst(2) }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Windows-style command-line splitting: whitespace separates, double quotes group.
enum CommandLine {
    static func split(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for char in line {
            switch char {
            case "\"":
                inQuotes.toggle()
                hasToken = true
            case " ", "\t":
                if inQuotes {
                    current.append(char)
                } else {
                    if hasToken { result.append(current) }
                    current = ""
                    hasToken = false
                }
            default:
                current.append(char)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }
}
