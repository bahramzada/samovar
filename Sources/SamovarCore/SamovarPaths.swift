import Foundation

/// On-disk layout of everything Samovar owns.
///
/// Defaults to `~/Library/Application Support/Samovar`. Set `SAMOVAR_HOME` to relocate it
/// (useful for tests and experiments).
public struct SamovarPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let override = ProcessInfo.processInfo.environment["SAMOVAR_HOME"], !override.isEmpty {
            self.root = URL(filePath: override, directoryHint: .isDirectory)
        } else {
            self.root = URL.applicationSupportDirectory.appending(path: "Samovar", directoryHint: .isDirectory)
        }
    }

    public var engines: URL { root.appending(path: "Engines", directoryHint: .isDirectory) }
    public var backends: URL { root.appending(path: "Backends", directoryHint: .isDirectory) }
    public var prefixes: URL { root.appending(path: "Prefixes", directoryHint: .isDirectory) }
    public var profiles: URL { root.appending(path: "Profiles", directoryHint: .isDirectory) }
    public var cache: URL { root.appending(path: "Cache", directoryHint: .isDirectory) }
    public var downloads: URL { cache.appending(path: "Downloads", directoryHint: .isDirectory) }
    public var artwork: URL { cache.appending(path: "Artwork", directoryHint: .isDirectory) }
    public var logs: URL { root.appending(path: "Logs", directoryHint: .isDirectory) }
    public var settingsFile: URL { root.appending(path: "settings.json") }

    public func engine(_ id: String) -> URL { engines.appending(path: id, directoryHint: .isDirectory) }
    public func backend(_ id: String) -> URL { backends.appending(path: id, directoryHint: .isDirectory) }
    public func prefix(_ name: String) -> URL { prefixes.appending(path: name, directoryHint: .isDirectory) }

    public func ensureDirectories() throws {
        for dir in [root, engines, backends, prefixes, profiles, cache, downloads, artwork, logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
