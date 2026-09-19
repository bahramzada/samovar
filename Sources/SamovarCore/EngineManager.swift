import Foundation

public enum EngineError: Error, CustomStringConvertible {
    case notInstalled(String)
    case alreadyInstalled(String)
    case invalidArchive(String)

    public var description: String {
        switch self {
        case let .notInstalled(id): "Engine '\(id)' is not installed"
        case let .alreadyInstalled(id): "Engine '\(id)' is already installed"
        case let .invalidArchive(reason): "Invalid engine archive: \(reason)"
        }
    }
}

/// Installs, lists and removes Wine engines under `Engines/<id>/`.
public struct EngineManager: Sendable {
    public let paths: SamovarPaths

    public init(paths: SamovarPaths) { self.paths = paths }

    private static let manifestName = "manifest.json"

    public func installed() -> [WineEngine] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: paths.engines.path) else { return [] }
        return ids.filter { !$0.hasPrefix(".") }.sorted().compactMap { try? engine($0) }
    }

    public func engine(_ id: String) throws -> WineEngine {
        let dir = paths.engine(id)
        let manifestURL = dir.appending(path: Self.manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw EngineError.notInstalled(id) }
        let manifest = try JSONDecoder.samovar.decode(EngineManifest.self, from: Data(contentsOf: manifestURL))
        return WineEngine(id: id, directory: dir, manifest: manifest)
    }

    /// Downloads (or takes `localArchive`), verifies and unpacks an engine.
    @discardableResult
    public func install(
        _ descriptor: EngineDescriptor,
        localArchive: URL? = nil,
        progress: (@Sendable (String, Double?) -> Void)? = nil
    ) async throws -> WineEngine {
        let fm = FileManager.default
        try paths.ensureDirectories()
        if (try? engine(descriptor.id)) != nil { throw EngineError.alreadyInstalled(descriptor.id) }

        let archive: URL
        if let localArchive {
            progress?("Verifying \(localArchive.lastPathComponent)", nil)
            let actual = try SHA256Hasher.hash(of: localArchive)
            guard actual == descriptor.sha256 else {
                throw DownloadError.checksumMismatch(file: localArchive, expected: descriptor.sha256, actual: actual)
            }
            archive = localArchive
        } else {
            archive = paths.downloads.appending(path: descriptor.url.lastPathComponent)
            progress?("Downloading \(descriptor.displayName)", 0)
            try await Downloader.fetch(descriptor.url, to: archive, sha256: descriptor.sha256) {
                progress?("Downloading \(descriptor.displayName)", $0)
            }
        }

        let staging = paths.engines.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)

        progress?("Extracting", nil)
        try await ProcessRunner.run(URL(filePath: "/usr/bin/tar"), ["-xf", archive.path, "-C", unpacked.path])

        let wineRoot = unpacked.appending(path: descriptor.archiveSubpath, directoryHint: .isDirectory)
        guard fm.fileExists(atPath: wineRoot.appending(path: "bin/wine64").path) else {
            throw EngineError.invalidArchive("bin/wine64 not found under \(descriptor.archiveSubpath)")
        }

        let assembled = staging.appending(path: descriptor.id, directoryHint: .isDirectory)
        try fm.createDirectory(at: assembled, withIntermediateDirectories: true)
        try fm.moveItem(at: wineRoot, to: assembled.appending(path: "wine", directoryHint: .isDirectory))
        let manifest = EngineManifest(
            id: descriptor.id,
            displayName: descriptor.displayName,
            baseEngine: nil,
            d3dmetal: descriptor.bundledD3DMetal,
            source: descriptor.url,
            sha256: descriptor.sha256,
            installedAt: .now
        )
        try JSONEncoder.samovar.encode(manifest).write(to: assembled.appending(path: Self.manifestName))
        try fm.moveItem(at: assembled, to: paths.engine(descriptor.id))

        progress?("Installed \(descriptor.displayName)", 1)
        return try engine(descriptor.id)
    }

    public func remove(_ id: String) throws {
        let dir = paths.engine(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw EngineError.notInstalled(id) }
        try FileManager.default.removeItem(at: dir)
    }

    /// Writes a new manifest for an engine assembled elsewhere (used by variants).
    func writeManifest(_ manifest: EngineManifest, in directory: URL) throws {
        try JSONEncoder.samovar.encode(manifest).write(to: directory.appending(path: Self.manifestName))
    }
}

extension JSONEncoder {
    static var samovar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var samovar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
