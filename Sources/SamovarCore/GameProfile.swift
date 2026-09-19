import Foundation

/// Per-game settings, stored as `Profiles/<appid>.json`.
public struct GameProfile: Codable, Sendable, Equatable {
    public var renderer: Renderer = .default
    /// Key of the appinfo launch option to use; nil = Steam's default.
    public var launchOption: String?
    /// Manual executable, relative to the install directory; overrides appinfo.
    public var executable: String?
    /// Extra arguments appended after the launch option's own.
    public var arguments: String = ""
    public var metalHUD = false
    public var environment: [String: String] = [:]
    /// Wine DLL overrides, e.g. `["dinput8": "n,b"]`.
    public var dllOverrides: [String: String] = [:]

    public init() {}

    // Decode leniently so older/hand-edited files keep working when fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        renderer = try c.decodeIfPresent(Renderer.self, forKey: .renderer) ?? .default
        launchOption = try c.decodeIfPresent(String.self, forKey: .launchOption)
        executable = try c.decodeIfPresent(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        dllOverrides = try c.decodeIfPresent([String: String].self, forKey: .dllOverrides) ?? [:]
    }
}

public struct ProfileStore: Sendable {
    public let paths: SamovarPaths

    public init(paths: SamovarPaths) { self.paths = paths }

    private func url(_ appID: Int) -> URL { paths.profiles.appending(path: "\(appID).json") }

    public func load(_ appID: Int) -> GameProfile {
        guard let data = try? Data(contentsOf: url(appID)),
              let profile = try? JSONDecoder.samovar.decode(GameProfile.self, from: data) else { return GameProfile() }
        return profile
    }

    public func save(_ profile: GameProfile, for appID: Int) throws {
        try FileManager.default.createDirectory(at: paths.profiles, withIntermediateDirectories: true)
        try JSONEncoder.samovar.encode(profile).write(to: url(appID), options: .atomic)
    }
}
