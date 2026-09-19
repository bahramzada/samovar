import Foundation

/// An installed (or installing) Steam app, from `appmanifest_<id>.acf`.
public struct SteamApp: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let installDir: String
    /// Unix path of the game's install directory.
    public let installPath: URL
    public let sizeOnDisk: Int64
    public let stateFlags: Int
    public let lastPlayed: Date?

    /// StateFlags bit 4 (`FullyInstalled`) set and no update pending (bit 2 `UpdateRequired`).
    public var isInstalled: Bool { stateFlags & 4 != 0 && stateFlags & 2 == 0 }
}

/// Reads the Steam library folders and app manifests inside a Wine prefix.
public struct SteamLibrary: Sendable {
    public let prefix: URL

    public init(prefix: URL) { self.prefix = prefix }

    /// Steam install directory (unix path).
    public var steamRoot: URL {
        prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
    }

    /// Converts a Windows path (e.g. `C:\\Games\\Steam`) to a unix path via `dosdevices`.
    public func unixPath(forWindowsPath windowsPath: String) -> URL? {
        let normalized = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 2, normalized.dropFirst().first == ":" else { return nil }
        let drive = normalized.prefix(2).lowercased()
        let rest = normalized.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let device = prefix.appending(path: "dosdevices/\(drive)", directoryHint: .isDirectory)
        // Resolve the drive symlink so paths stay stable and readable.
        let base = (try? FileManager.default.destinationOfSymbolicLink(atPath: device.path))
            .map { $0.hasPrefix("/") ? URL(filePath: $0, directoryHint: .isDirectory)
                                     : prefix.appending(path: "dosdevices").appending(path: $0, directoryHint: .isDirectory) }
            ?? device
        return rest.isEmpty ? base.standardizedFileURL : base.appending(path: rest).standardizedFileURL
    }

    /// All `steamapps` directories Steam knows about (always includes the default one).
    public func libraryFolders() -> [URL] {
        var folders = [steamRoot.appending(path: "steamapps", directoryHint: .isDirectory)]
        let vdf = steamRoot.appending(path: "steamapps/libraryfolders.vdf")
        if let root = try? TextVDF.parse(contentsOf: vdf), let lib = root["libraryfolders"] {
            for (_, entry) in lib.children {
                guard let path = entry["path"]?.string, let unix = unixPath(forWindowsPath: path) else { continue }
                let steamapps = unix.appending(path: "steamapps", directoryHint: .isDirectory)
                if !folders.contains(where: { $0.standardizedFileURL == steamapps.standardizedFileURL }) {
                    folders.append(steamapps)
                }
            }
        }
        return folders
    }

    /// Every app with a manifest, excluding Steam's own runtime/redistributable packages.
    public func apps() -> [SteamApp] {
        var result: [Int: SteamApp] = [:]
        let fm = FileManager.default
        for folder in libraryFolders() {
            guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let app = Self.app(fromManifest: folder.appending(path: file), library: folder),
                      !Self.ignoredAppIDs.contains(app.id) else { continue }
                result[app.id] = app
            }
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func app(id: Int) -> SteamApp? { apps().first { $0.id == id } }

    static func app(fromManifest url: URL, library: URL) -> SteamApp? {
        guard let root = try? TextVDF.parse(contentsOf: url), let state = root["AppState"],
              let id = state["appid"]?.int, let installDir = state["installdir"]?.string else { return nil }
        let lastPlayed = state["LastPlayed"]?.int.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return SteamApp(
            id: Int(id),
            name: state["name"]?.string ?? installDir,
            installDir: installDir,
            installPath: library.appending(path: "common/\(installDir)", directoryHint: .isDirectory),
            sizeOnDisk: state["SizeOnDisk"]?.int ?? 0,
            stateFlags: Int(state["StateFlags"]?.int ?? 0),
            lastPlayed: lastPlayed
        )
    }

    /// Steamworks Common Redistributables and similar non-game packages.
    static let ignoredAppIDs: Set<Int> = [228980]
}
