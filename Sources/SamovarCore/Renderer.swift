import Foundation

/// How DirectX is translated for a launch.
public enum Renderer: Codable, Sendable, Hashable, CustomStringConvertible {
    /// Wine's own OpenGL-based wined3d (the unmodified engine).
    case wined3d
    /// Apple D3DMetal (DX11/DX12). `nil` = the build bundled with the engine; otherwise an imported backend id.
    case d3dmetal(String?)
    /// DXMT (DX10/DX11 → Metal), bundled with the engine.
    case dxmt

    public static let `default` = Renderer.d3dmetal(nil)

    public var description: String {
        switch self {
        case .wined3d: "WineD3D"
        case .d3dmetal(nil): "D3DMetal"
        case let .d3dmetal(id?): "D3DMetal (\(id))"
        case .dxmt: "DXMT"
        }
    }

    /// Stable key used in bundle names, e.g. `d3dmetal`, `d3dmetal-4.0-beta-2`, `dxmt`.
    var variantKey: String? {
        switch self {
        case .wined3d: nil
        case .d3dmetal(nil): "d3dmetal"
        case let .d3dmetal(id?): id
        case .dxmt: "dxmt"
        }
    }

    /// Parses CLI/profile spellings: `wined3d`, `d3dmetal`, `d3dmetal-4.0-beta-2`, `dxmt`.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "wined3d", "opengl": self = .wined3d
        case "d3dmetal": self = .d3dmetal(nil)
        case "dxmt": self = .dxmt
        case let s where s.hasPrefix("d3dmetal-"): self = .d3dmetal(s)
        default: return nil
        }
    }
}

public enum RendererError: Error, CustomStringConvertible {
    case unavailable(Renderer, String)

    public var description: String {
        switch self {
        case let .unavailable(renderer, reason): "\(renderer) is not available: \(reason)"
        }
    }
}

extension WineEngine {
    /// Renderers this engine can provide right now.
    public func availableRenderers(importedD3DMetal: [D3DMetalBackend]) -> [Renderer] {
        let fm = FileManager.default
        var result: [Renderer] = [.wined3d]
        if fm.fileExists(atPath: rendererDirectory.appending(path: "d3dmetal/external").path) { result.append(.d3dmetal(nil)) }
        result += importedD3DMetal.map { .d3dmetal($0.id) }
        if fm.fileExists(atPath: rendererDirectory.appending(path: "dxmt/wine").path) { result.append(.dxmt) }
        return result
    }

    /// Returns an engine whose Wine tree has `renderer` baked in.
    ///
    /// CrossOver's Wine searches its own `lib/wine` before `WINEDLLPATH`, so overlays can't be
    /// selected by environment alone. Instead each renderer gets a sibling bundle,
    /// `Frameworks/wswine-<renderer>.bundle`, made as an APFS clone of `wswine.bundle` (near-zero
    /// disk cost) with the renderer's DLLs copied over it. The prefix is never touched.
    public func variant(for renderer: Renderer, paths: SamovarPaths) throws -> RendererVariant {
        guard let key = renderer.variantKey else {
            return RendererVariant(engine: self, wineRoot: wineRoot, renderer: renderer, libd3dshared: nil)
        }
        let (source, external) = try overlaySource(for: renderer, paths: paths)
        let bundle = wineRoot.deletingLastPathComponent().appending(path: "wswine-\(key).bundle", directoryHint: .isDirectory)
        let stamp = bundle.appending(path: ".samovar-variant")
        let expectedStamp = "\(id)|\(key)|\(manifest.installedAt.timeIntervalSince1970)"

        let fm = FileManager.default
        if (try? String(contentsOf: stamp, encoding: .utf8)) != expectedStamp {
            let staging = bundle.deletingLastPathComponent().appending(path: ".wswine-\(key)-\(UUID().uuidString).bundle")
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: wineRoot, to: staging) // clonefile(2) on APFS
            try Self.overlay(source, onto: staging.appending(path: "lib/wine"))
            if let external {
                try Self.overlay(external, onto: staging.appending(path: "lib/external"))
            }
            try expectedStamp.write(to: staging.appending(path: ".samovar-variant"), atomically: true, encoding: .utf8)
            if fm.fileExists(atPath: bundle.path) { try fm.removeItem(at: bundle) }
            try fm.moveItem(at: staging, to: bundle)
        }
        let libd3dshared = external == nil ? nil : bundle.appending(path: "lib/external/libd3dshared.dylib")
        return RendererVariant(engine: self, wineRoot: bundle, renderer: renderer, libd3dshared: libd3dshared)
    }

    private func overlaySource(for renderer: Renderer, paths: SamovarPaths) throws -> (wine: URL, external: URL?) {
        let fm = FileManager.default
        switch renderer {
        case .wined3d:
            preconditionFailure("wined3d has no overlay")
        case .d3dmetal(nil):
            let dir = rendererDirectory.appending(path: "d3dmetal", directoryHint: .isDirectory)
            guard fm.fileExists(atPath: dir.appending(path: "external/libd3dshared.dylib").path) else {
                throw RendererError.unavailable(renderer, "engine has no bundled D3DMetal")
            }
            return (dir.appending(path: "wine"), dir.appending(path: "external"))
        case let .d3dmetal(id?):
            guard let backend = D3DMetalImporter(paths: paths).installed().first(where: { $0.id == id }) else {
                throw RendererError.unavailable(renderer, "import it first with `samovar d3dmetal import <dmg>`")
            }
            return (backend.wineDLLs, backend.external)
        case .dxmt:
            let dir = rendererDirectory.appending(path: "dxmt/wine", directoryHint: .isDirectory)
            guard fm.fileExists(atPath: dir.path) else { throw RendererError.unavailable(renderer, "engine has no DXMT") }
            return (dir, nil)
        }
    }

    /// Copies every entry of `source` into `destination`, replacing existing files and keeping symlinks.
    private static func overlay(_ source: URL, onto destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let from = source.appending(path: name)
            let to = destination.appending(path: name)
            var isDir: ObjCBool = false
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: from.path)) != nil
            if !isLink, fm.fileExists(atPath: from.path, isDirectory: &isDir), isDir.boolValue,
               name.hasSuffix("-unix") || name.hasSuffix("-windows") {
                try overlay(from, onto: to) // merge arch directories file by file
                continue
            }
            if (try? fm.attributesOfItem(atPath: to.path)) != nil { try fm.removeItem(at: to) }
            try fm.copyItem(at: from, to: to)
        }
    }
}

/// A concrete Wine tree to launch with, plus the renderer it carries.
public struct RendererVariant: Sendable {
    public let engine: WineEngine
    public let wineRoot: URL
    public let renderer: Renderer
    public let libd3dshared: URL?

    public var wine: URL { wineRoot.appending(path: "bin/wine") }
    public var wineserver: URL { wineRoot.appending(path: "bin/wineserver") }

    public func environment(prefix: URL, extra: [String: String] = [:]) -> [String: String] {
        var env = engine.environment(prefix: prefix)
        env["PATH"] = [wineRoot.appending(path: "bin").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        if let libd3dshared { env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = libd3dshared.path }
        env.merge(extra) { _, new in new }
        return env
    }
}
