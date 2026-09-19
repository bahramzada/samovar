import Foundation

/// One downloadable piece of an engine (e.g. the runtime libraries, or the Wine build itself).
public struct EngineComponent: Codable, Sendable, Hashable {
    public let url: URL
    public let sha256: String
    /// Directory inside the extracted archive to take.
    public let archiveSubpath: String
    /// Where that directory goes, relative to the engine root.
    public let destination: String
}

/// A Wine engine Samovar knows how to install.
///
/// Engines follow the Sikarugir/CrossOver layout: shared dylibs in `Frameworks/`, Wine in
/// `Frameworks/wswine.bundle` (its binaries use `@loader_path/../../` as rpath), and optional
/// graphics overlays in `Frameworks/renderer/<name>/`.
public struct EngineDescriptor: Codable, Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let wineVersion: String
    public let components: [EngineComponent]
    /// Wine root (containing `bin/`, `lib/`), relative to the engine root.
    public let winePath: String
    /// Directory added to `DYLD_FALLBACK_LIBRARY_PATH`, relative to the engine root.
    public let libraryPath: String
    /// Directory with bundled renderer overlays, relative to the engine root.
    public let rendererPath: String
}

public enum EngineCatalog {
    /// CrossOver 24.0.7 Wine (wine-9.0 based) built by the Sikarugir project, with the Sikarugir
    /// runtime (FreeType, GnuTLS, GStreamer, MoltenVK) and renderers (D3DMetal 3.0, DXMT, DXVK).
    public static let cx24 = EngineDescriptor(
        id: "cx24.0.7-7",
        displayName: "CrossOver 24.0.7",
        wineVersion: "9.0",
        components: [
            EngineComponent(
                url: URL(string: "https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.18.tar.xz")!,
                sha256: "00d1fcb66aebdef51981b26476a2fe8cd600c39552166f0e733f57272d9e97b3",
                archiveSubpath: "Template-1.0.18.app/Contents/Frameworks",
                destination: "Frameworks"
            ),
            EngineComponent(
                url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz")!,
                sha256: "203f9e9fd6c2cc77e6525d798a434ced326145db34a356355e05659d3445fd1c",
                archiveSubpath: "wswine.bundle",
                destination: "Frameworks/wswine.bundle"
            ),
        ],
        winePath: "Frameworks/wswine.bundle",
        libraryPath: "Frameworks",
        rendererPath: "Frameworks/renderer"
    )

    public static let all = [cx24]
    public static let `default` = cx24

    public static func descriptor(id: String) -> EngineDescriptor? { all.first { $0.id == id } }
}

/// Metadata written next to an installed engine.
public struct EngineManifest: Codable, Sendable {
    public var descriptor: EngineDescriptor
    public var installedAt: Date

    public init(descriptor: EngineDescriptor, installedAt: Date) {
        self.descriptor = descriptor
        self.installedAt = installedAt
    }
}

/// An installed, runnable Wine engine.
public struct WineEngine: Sendable, Hashable {
    public let directory: URL
    public let manifest: EngineManifest

    public init(directory: URL, manifest: EngineManifest) {
        self.directory = directory
        self.manifest = manifest
    }

    public var id: String { manifest.descriptor.id }
    public var displayName: String { manifest.descriptor.displayName }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var wineRoot: URL { directory.appending(path: manifest.descriptor.winePath, directoryHint: .isDirectory) }
    public var libraryDirectory: URL { directory.appending(path: manifest.descriptor.libraryPath, directoryHint: .isDirectory) }
    public var rendererDirectory: URL { directory.appending(path: manifest.descriptor.rendererPath, directoryHint: .isDirectory) }
    public var wine: URL { wineRoot.appending(path: "bin/wine") }
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
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [libraryDirectory.path, "/usr/lib"].joined(separator: ":")
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all"
        env["WINEMSYNC"] = "1"
        env.merge(extra) { _, new in new }
        return env
    }
}
