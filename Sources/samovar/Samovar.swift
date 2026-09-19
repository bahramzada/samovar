import ArgumentParser
import Foundation
import SamovarCore

@main
struct Samovar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "samovar",
        abstract: "Play Windows Steam games on macOS.",
        subcommands: [Setup.self, SteamCommand.self, Games.self, Play.self, ProfileCommand.self,
                      EngineCommand.self, D3DMetalCommand.self]
    )
}

extension Renderer: ExpressibleByArgument {}

struct Play: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Launch a game and wait for it to exit.")

    @Argument(help: "Steam app id (see `samovar games`).")
    var appID: Int

    @Option(help: "Renderer for this run only: wined3d, d3dmetal, d3dmetal-<version>, dxmt.")
    var renderer: Renderer?

    @Flag(help: "Show the Metal performance HUD for this run.")
    var hud = false

    @Flag(help: "Print the launch plan without starting anything.")
    var dryRun = false

    func run() async throws {
        let launcher = GameLauncher(env: try SamovarEnvironment())
        var profile = launcher.profiles.load(appID)
        if let renderer { profile.renderer = renderer }
        if hud { profile.metalHUD = true }

        let plan = try launcher.plan(appID: appID, profile: profile)
        print("Game:      \(plan.app.name)")
        print("Exe:       \(plan.executable.path)")
        print("Args:      \(plan.arguments)")
        print("Renderer:  \(plan.variant.renderer)")
        print("Log:       \(plan.log.path)")
        if dryRun { return }

        print("Waiting for Steam…")
        let process = try await launcher.launch(plan)
        print("Running (pid \(process.processIdentifier)). Ctrl-C to stop waiting.")
        let status: Int32 = await withCheckedContinuation { continuation in
            if !process.isRunning { continuation.resume(returning: process.terminationStatus); return }
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        }
        print("Exited with \(status)")
    }
}

struct ProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Show or change a game's saved settings.",
        subcommands: [Show.self, Set.self, Options.self]
    )

    struct Show: AsyncParsableCommand {
        @Argument var appID: Int

        func run() async throws {
            let profile = ProfileStore(paths: SamovarPaths()).load(appID)
            let data = try JSONEncoder().encode(profile)
            let pretty = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data),
                                                    options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: pretty, as: UTF8.self))
        }
    }

    struct Set: AsyncParsableCommand {
        @Argument var appID: Int
        @Option var renderer: Renderer?
        @Option(help: "Launch option key from `profile options`.") var launchOption: String?
        @Option(help: "Executable relative to the install dir (empty string clears).") var executable: String?
        @Option(help: "Extra arguments.") var arguments: String?
        @Option(help: "Metal HUD on/off.") var hud: Bool?

        func run() async throws {
            let store = ProfileStore(paths: SamovarPaths())
            var profile = store.load(appID)
            if let renderer { profile.renderer = renderer }
            if let launchOption { profile.launchOption = launchOption.isEmpty ? nil : launchOption }
            if let executable { profile.executable = executable.isEmpty ? nil : executable }
            if let arguments { profile.arguments = arguments }
            if let hud { profile.metalHUD = hud }
            try store.save(profile, for: appID)
            print("Saved profile for \(appID)")
        }
    }

    struct Options: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the game's launch options from appinfo.")

        @Argument var appID: Int

        func run() async throws {
            let options = GameLauncher(env: try SamovarEnvironment()).launchOptions(for: appID)
            if options.isEmpty { print("No launch options (is Steam logged in and the game owned?)") }
            let preferred = LaunchOption.preferred(options)
            for option in options {
                let mark = option == preferred ? "*" : (option.isPlayable ? " " : "-")
                let os = option.osList.isEmpty ? "any" : option.osList.joined(separator: ",")
                print("\(mark) [\(option.key)] \(option.executable) \(option.arguments)  (\(option.type ?? "default"), \(os))")
            }
        }
    }
}

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Install the engine, create the prefix and install Steam.")

    func run() async throws {
        let env = try await SamovarEnvironment.setup(progress: ProgressReporter().report)
        print("Prefix: \(env.prefix.url.path)")
        print("Next: `samovar steam start --show` and log in once.")
    }
}

struct SteamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "steam",
        abstract: "Control the Windows Steam client.",
        subcommands: [Start.self, Stop.self, Status.self, Open.self]
    )

    struct Start: AsyncParsableCommand {
        @Flag(help: "Show the Steam window instead of starting silently in the tray.")
        var show = false

        func run() async throws {
            let env = try SamovarEnvironment()
            if env.steam.isRunning { print("Steam is already running"); return }
            try env.steam.start(silent: !show)
            print("Starting Steam (log: \(env.steam.log.path))")
        }
    }

    struct Stop: AsyncParsableCommand {
        func run() async throws {
            let env = try SamovarEnvironment()
            await env.steam.shutdown()
            print(env.prefix.isServerRunning ? "Prefix still running" : "Stopped")
        }
    }

    struct Status: AsyncParsableCommand {
        func run() async throws {
            let env = try SamovarEnvironment()
            print("installed: \(env.steam.isInstalled)")
            print("wineserver: \(env.prefix.isServerRunning ? "running" : "stopped")")
            print("steam: \(env.steam.isRunning ? "running" : "stopped")")
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a steam:// URL, e.g. steam://install/<appid>.")

        @Argument var url: String

        func run() async throws {
            try SamovarEnvironment().steam.open(url)
        }
    }
}

struct Games: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List Steam games in the prefix.")

    func run() async throws {
        let apps = try SamovarEnvironment().steam.library.apps()
        if apps.isEmpty { print("No games installed yet.") }
        for app in apps {
            let size = ByteCountFormatter.string(fromByteCount: app.sizeOnDisk, countStyle: .file)
            print("\(app.id)\t\(app.isInstalled ? "installed" : "pending  ")\t\(size)\t\(app.name)")
        }
    }
}

struct D3DMetalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "d3dmetal",
        abstract: "Import D3DMetal from Apple's 'Evaluation environment for Windows games' DMG.",
        subcommands: [Import.self, List.self]
    )

    struct Import: AsyncParsableCommand {
        @Argument(help: "Path to the .dmg file.")
        var dmg: String

        func run() async throws {
            let backend = try await D3DMetalImporter(paths: SamovarPaths()).importDMG(URL(filePath: dmg))
            print("Imported \(backend.id) (use renderer `\(backend.id)`)")
        }
    }

    struct List: AsyncParsableCommand {
        func run() async throws {
            let installed = D3DMetalImporter(paths: SamovarPaths()).installed()
            if installed.isEmpty { print("(none imported)") }
            for backend in installed { print("  \(backend.id)") }
        }
    }
}

struct EngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engine",
        abstract: "Manage Wine engines.",
        subcommands: [List.self, Install.self, Remove.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List installed and available engines.")

        func run() async throws {
            let installed = EngineManager(paths: SamovarPaths()).installed()
            print("Installed:")
            if installed.isEmpty { print("  (none)") }
            let imported = D3DMetalImporter(paths: SamovarPaths()).installed()
            for engine in installed {
                let renderers = engine.availableRenderers(importedD3DMetal: imported).map(\.description)
                print("  \(engine.id)  \(engine.displayName)  [\(renderers.joined(separator: ", "))]")
            }
            print("Available:")
            for descriptor in EngineCatalog.all {
                print("  \(descriptor.id)  \(descriptor.displayName) (wine-\(descriptor.wineVersion))")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download and install an engine.")

        @Argument(help: "Engine id (see `engine list`).")
        var id: String = EngineCatalog.default.id

        @Option(name: .customLong("archive"), help: "Use an already-downloaded component archive (repeatable).")
        var archives: [String] = []

        func run() async throws {
            guard let descriptor = EngineCatalog.descriptor(id: id) else {
                throw ValidationError("Unknown engine '\(id)'")
            }
            let local = Dictionary(archives.map { (URL(filePath: $0).lastPathComponent, URL(filePath: $0)) },
                                   uniquingKeysWith: { _, new in new })
            let reporter = ProgressReporter()
            let engine = try await EngineManager(paths: SamovarPaths()).install(
                descriptor,
                localArchives: local,
                progress: reporter.report
            )
            print("Installed \(engine.id) at \(engine.directory.path)")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an installed engine.")

        @Argument var id: String

        func run() async throws {
            try EngineManager(paths: SamovarPaths()).remove(id)
            print("Removed \(id)")
        }
    }
}

/// Prints step changes and whole-percent progress, without flooding the terminal.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStep = ""
    private var lastPercent = -1

    func report(_ step: String, _ fraction: Double?) {
        lock.withLock {
            if step != lastStep {
                lastStep = step
                lastPercent = -1
                print("→ \(step)")
            }
            guard let fraction else { return }
            let percent = Int(fraction * 100)
            if percent / 10 != lastPercent / 10 {
                lastPercent = percent
                print("  \(percent)%")
            }
        }
    }
}
