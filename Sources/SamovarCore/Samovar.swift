import Foundation

/// Entry point tying the pieces together: one engine, one Steam prefix.
public struct SamovarEnvironment: Sendable {
    public let paths: SamovarPaths
    public let engine: WineEngine
    public let prefix: WinePrefix
    public let steam: SteamClient

    public static let steamPrefixName = "steam"

    /// Uses the default engine (must already be installed).
    public init(paths: SamovarPaths = SamovarPaths()) throws {
        self.paths = paths
        engine = try EngineManager(paths: paths).engine(EngineCatalog.default.id)
        prefix = WinePrefix(url: paths.prefix(Self.steamPrefixName), engine: engine)
        steam = SteamClient(prefix: prefix, paths: paths)
    }

    /// First-run setup: engine, prefix, Steam. Each step is skipped when already done.
    public static func setup(
        paths: SamovarPaths = SamovarPaths(),
        progress: (@Sendable (String, Double?) -> Void)? = nil
    ) async throws -> SamovarEnvironment {
        try paths.ensureDirectories()
        let engines = EngineManager(paths: paths)
        if (try? engines.engine(EngineCatalog.default.id)) == nil {
            try await engines.install(EngineCatalog.default, progress: progress)
        }
        let env = try SamovarEnvironment(paths: paths)
        if !env.prefix.exists {
            progress?("Creating Windows prefix", nil)
            try await env.prefix.create(log: paths.logs.appending(path: "prefix.log"))
        }
        if !env.steam.isInstalled {
            try await env.steam.install(progress: progress)
        }
        progress?("Ready", 1)
        return env
    }
}
