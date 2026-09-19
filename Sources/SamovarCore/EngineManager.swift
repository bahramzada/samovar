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
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: paths.engines.path) else { return [] }
        return ids.filter { !$0.hasPrefix(".") }.sorted().compactMap { try? engine($0) }
    }

    public func engine(_ id: String) throws -> WineEngine {
        let dir = paths.engine(id)
        let manifestURL = dir.appending(path: Self.manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw EngineError.notInstalled(id) }
        let manifest = try JSONDecoder.samovar.decode(EngineManifest.self, from: Data(contentsOf: manifestURL))
        return WineEngine(directory: dir, manifest: manifest)
    }

    /// Downloads, verifies and unpacks every component of an engine.
    ///
    /// `localArchives` maps a component's archive file name to an already-downloaded copy;
    /// those are still checksum-verified.
    @discardableResult
    public func install(
        _ descriptor: EngineDescriptor,
        localArchives: [String: URL] = [:],
        progress: (@Sendable (String, Double?) -> Void)? = nil
    ) async throws -> WineEngine {
        let fm = FileManager.default
        try paths.ensureDirectories()
        if (try? engine(descriptor.id)) != nil { throw EngineError.alreadyInstalled(descriptor.id) }

        let staging = paths.engines.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        let assembled = staging.appending(path: descriptor.id, directoryHint: .isDirectory)
        try fm.createDirectory(at: assembled, withIntermediateDirectories: true)

        for (index, component) in descriptor.components.enumerated() {
            let name = component.url.lastPathComponent
            let step = "[\(index + 1)/\(descriptor.components.count)] \(name)"
            let archive = try await fetch(component, local: localArchives[name], step: step, progress: progress)

            progress?("\(step): extracting", nil)
            let unpacked = staging.appending(path: "unpacked-\(index)", directoryHint: .isDirectory)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try await ProcessRunner.run(URL(filePath: "/usr/bin/tar"), ["-xf", archive.path, "-C", unpacked.path])

            let source = unpacked.appending(path: component.archiveSubpath, directoryHint: .isDirectory)
            guard fm.fileExists(atPath: source.path) else {
                throw EngineError.invalidArchive("\(component.archiveSubpath) not found in \(name)")
            }
            let destination = assembled.appending(path: component.destination, directoryHint: .isDirectory)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: source, to: destination)
            try? fm.removeItem(at: unpacked)
        }

        let manifest = EngineManifest(descriptor: descriptor, installedAt: .now)
        let probe = WineEngine(directory: assembled, manifest: manifest)
        guard fm.isExecutableFile(atPath: probe.wine.path), fm.isExecutableFile(atPath: probe.wineserver.path) else {
            throw EngineError.invalidArchive("wine binaries missing under \(descriptor.winePath)")
        }
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

    private func fetch(
        _ component: EngineComponent,
        local: URL?,
        step: String,
        progress: (@Sendable (String, Double?) -> Void)?
    ) async throws -> URL {
        if let local {
            progress?("\(step): verifying", nil)
            let actual = try SHA256Hasher.hash(of: local)
            guard actual == component.sha256 else {
                throw DownloadError.checksumMismatch(file: local, expected: component.sha256, actual: actual)
            }
            return local
        }
        let archive = paths.downloads.appending(path: component.url.lastPathComponent)
        progress?("\(step): downloading", 0)
        try await Downloader.fetch(component.url, to: archive, sha256: component.sha256) {
            progress?("\(step): downloading", $0)
        }
        return archive
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
