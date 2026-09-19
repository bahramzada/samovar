import ArgumentParser
import Foundation
import SamovarCore

@main
struct Samovar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "samovar",
        abstract: "Play Windows Steam games on macOS.",
        subcommands: [EngineCommand.self, D3DMetalCommand.self]
    )
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
