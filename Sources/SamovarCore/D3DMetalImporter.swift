import Foundation

public enum D3DMetalImportError: Error, CustomStringConvertible {
    case mountFailed(String)
    case notAnEvaluationEnvironment(URL)

    public var description: String {
        switch self {
        case let .mountFailed(output): "Could not mount disk image: \(output)"
        case let .notAnEvaluationEnvironment(url):
            "\(url.lastPathComponent) is not an Apple 'Evaluation environment for Windows games' image (no redist/lib)"
        }
    }
}

/// A D3DMetal build extracted from Apple's DMG into `Backends/d3dmetal-<version>/`.
///
/// Layout matches what CrossOver-based Wine expects for a renderer overlay:
/// `external/` (D3DMetal.framework, libd3dshared.dylib) and `wine/{x86_64-unix,x86_64-windows}`.
public struct D3DMetalBackend: Sendable, Hashable, Codable {
    public let id: String
    public let version: String
    public let directory: URL

    public var external: URL { directory.appending(path: "external", directoryHint: .isDirectory) }
    public var wineDLLs: URL { directory.appending(path: "wine", directoryHint: .isDirectory) }
    public var libd3dshared: URL { external.appending(path: "libd3dshared.dylib") }
}

public struct D3DMetalImporter: Sendable {
    public let paths: SamovarPaths

    public init(paths: SamovarPaths) { self.paths = paths }

    public func installed() -> [D3DMetalBackend] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.backends.path) else { return [] }
        return names.filter { $0.hasPrefix("d3dmetal-") }.sorted().compactMap { name in
            let dir = paths.backend(name)
            guard FileManager.default.fileExists(atPath: dir.appending(path: "external/libd3dshared.dylib").path) else { return nil }
            return D3DMetalBackend(id: name, version: String(name.dropFirst("d3dmetal-".count)), directory: dir)
        }
    }

    /// Extracts D3DMetal from an Apple "Evaluation environment for Windows games" DMG.
    /// Re-importing the same version replaces it.
    @discardableResult
    public func importDMG(_ dmg: URL) async throws -> D3DMetalBackend {
        try paths.ensureDirectories()
        let mountPoint = try await attach(dmg)
        do {
            let backend = try extract(from: mountPoint, dmg: dmg)
            try await detach(mountPoint)
            return backend
        } catch {
            try? await detach(mountPoint)
            throw error
        }
    }

    private func extract(from mountPoint: URL, dmg: URL) throws -> D3DMetalBackend {
        let fm = FileManager.default
        let redistLib = mountPoint.appending(path: "redist/lib", directoryHint: .isDirectory)
        guard fm.fileExists(atPath: redistLib.appending(path: "external/libd3dshared.dylib").path) else {
            throw D3DMetalImportError.notAnEvaluationEnvironment(dmg)
        }

        let version = Self.version(fromVolumeName: mountPoint.lastPathComponent)
        let id = "d3dmetal-\(version)"
        let staging = paths.backends.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        // copyItem preserves the .so -> libd3dshared.dylib symlinks.
        try fm.copyItem(at: redistLib.appending(path: "external"), to: staging.appending(path: "external"))
        try fm.copyItem(at: redistLib.appending(path: "wine"), to: staging.appending(path: "wine"))
        for doc in ["License.rtf", "Read Me.rtf", "Acknowledgements.rtf"] {
            let src = mountPoint.appending(path: doc)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: staging.appending(path: doc)) }
        }

        let destination = paths.backend(id)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
        return D3DMetalBackend(id: id, version: version, directory: destination)
    }

    /// "Evaluation environment for Windows games 4.0 beta 2" -> "4.0-beta-2"
    static func version(fromVolumeName name: String) -> String {
        let prefix = "Evaluation environment for Windows games"
        let raw = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
        let cleaned = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    private func detach(_ mountPoint: URL) async throws {
        try await ProcessRunner.run(URL(filePath: "/usr/bin/hdiutil"), ["detach", mountPoint.path, "-quiet"])
    }

    private func attach(_ dmg: URL) async throws -> URL {
        let result = try await ProcessRunner.run(
            URL(filePath: "/usr/bin/hdiutil"),
            ["attach", dmg.path, "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-plist"],
            check: false
        )
        guard result.succeeded,
              let start = result.output.range(of: "<?xml"),
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(result.output[start.lowerBound...].utf8), format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw D3DMetalImportError.mountFailed(result.output) }
        return URL(filePath: mount, directoryHint: .isDirectory)
    }
}
