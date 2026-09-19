import Foundation

/// A downloadable Wine build Samovar knows how to install.
public struct EngineDescriptor: Codable, Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let url: URL
    public let sha256: String
    /// Path of the Wine root (containing `bin/`, `lib/`) inside the extracted archive.
    public let archiveSubpath: String
    /// Version of D3DMetal shipped inside the build, if any.
    public let bundledD3DMetal: String?
}

public enum EngineCatalog {
    /// Gcenx's binary build of Apple's Game Porting Toolkit Wine (wine-7.7 based), D3DMetal 3.0 included.
    public static let gptk3 = EngineDescriptor(
        id: "gptk-3.0-3",
        displayName: "Game Porting Toolkit 3.0",
        url: URL(string: "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz")!,
        sha256: "d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e",
        archiveSubpath: "Game Porting Toolkit.app/Contents/Resources/wine",
        bundledD3DMetal: "3.0"
    )

    public static let all = [gptk3]
    public static let `default` = gptk3

    public static func descriptor(id: String) -> EngineDescriptor? { all.first { $0.id == id } }
}

/// Metadata written next to an installed engine.
public struct EngineManifest: Codable, Sendable {
    public var id: String
    public var displayName: String
    /// Engine this one was derived from (for D3DMetal variants).
    public var baseEngine: String?
    public var d3dmetal: String?
    public var source: URL?
    public var sha256: String?
    public var installedAt: Date

    public init(id: String, displayName: String, baseEngine: String? = nil, d3dmetal: String? = nil,
                source: URL? = nil, sha256: String? = nil, installedAt: Date) {
        self.id = id
        self.displayName = displayName
        self.baseEngine = baseEngine
        self.d3dmetal = d3dmetal
        self.source = source
        self.sha256 = sha256
        self.installedAt = installedAt
    }
}

/// An installed, runnable Wine engine.
public struct WineEngine: Sendable, Hashable {
    public let id: String
    public let directory: URL
    public let manifest: EngineManifest

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var wineRoot: URL { directory.appending(path: "wine", directoryHint: .isDirectory) }
    public var wine: URL { wineRoot.appending(path: "bin/wine64") }
    public var wineserver: URL { wineRoot.appending(path: "bin/wineserver") }

    /// Environment for running this engine against `prefix`. `extra` wins over defaults.
    public func environment(prefix: URL, extra: [String: String] = [:]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"] {
            env[key] = inherited[key]
        }
        env["PATH"] = [wineRoot.appending(path: "bin").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all"
        env["WINEESYNC"] = "1"
        env.merge(extra) { _, new in new }
        return env
    }
}
