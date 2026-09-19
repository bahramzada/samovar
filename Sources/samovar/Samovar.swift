import ArgumentParser
import Foundation
import SamovarCore

@main
struct Samovar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "samovar",
        abstract: "Play Windows Steam games on macOS.",
        subcommands: [EngineCommand.self]
    )
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
            for engine in installed {
                let d3d = engine.manifest.d3dmetal.map { "  D3DMetal \($0)" } ?? ""
                print("  \(engine.id)  \(engine.manifest.displayName)\(d3d)")
            }
            print("Available:")
            for descriptor in EngineCatalog.all {
                print("  \(descriptor.id)  \(descriptor.displayName)")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download and install an engine.")

        @Argument(help: "Engine id (see `engine list`).")
        var id: String = EngineCatalog.default.id

        @Option(help: "Use an already-downloaded archive instead of downloading.")
        var archive: String?

        func run() async throws {
            guard let descriptor = EngineCatalog.descriptor(id: id) else {
                throw ValidationError("Unknown engine '\(id)'")
            }
            let reporter = ProgressReporter()
            let engine = try await EngineManager(paths: SamovarPaths()).install(
                descriptor,
                localArchive: archive.map { URL(filePath: $0) },
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
