import Foundation

public enum SteamError: Error, CustomStringConvertible {
    case notInstalled
    case installFailed(String)

    public var description: String {
        switch self {
        case .notInstalled: "Steam is not installed in the prefix"
        case let .installFailed(reason): "Steam installation failed: \(reason)"
        }
    }
}

/// The Windows Steam client running inside a prefix.
public struct SteamClient: Sendable {
    public let prefix: WinePrefix
    public let paths: SamovarPaths

    public init(prefix: WinePrefix, paths: SamovarPaths) {
        self.prefix = prefix
        self.paths = paths
    }

    public static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    public var library: SteamLibrary { SteamLibrary(prefix: prefix.url) }
    public var steamRoot: URL { library.steamRoot }
    public var steamExe: URL { steamRoot.appending(path: "steam.exe") }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: steamExe.path) }
    public var log: URL { paths.logs.appending(path: "steam.log") }

    /// Downloads SteamSetup.exe from Valve's CDN and installs it silently.
    public func install(progress: (@Sendable (String, Double?) -> Void)? = nil) async throws {
        let installer = paths.downloads.appending(path: "SteamSetup.exe")
        progress?("Downloading Steam installer", 0)
        // Valve updates the installer in place, so there's no fixed checksum; always refetch.
        try? FileManager.default.removeItem(at: installer)
        try await Downloader.fetch(Self.installerURL, to: installer) { progress?("Downloading Steam installer", $0) }

        progress?("Installing Steam", nil)
        let result = try await prefix.run([installer.path, "/S"], log: log, timeout: 300)
        try await prefix.waitForServer(timeout: 120)
        guard isInstalled else {
            throw SteamError.installFailed("steam.exe missing after installer exited with \(result.exitCode)")
        }
    }

    /// Starts Steam. With `silent`, it goes straight to the tray without showing its window.
    ///
    /// Steam self-updates on first launch and relaunches itself (exit code 42), so the returned
    /// process is only the bootstrapper; use `isRunning` to check on Steam itself.
    @discardableResult
    public func start(silent: Bool = true) throws -> Process {
        guard isInstalled else { throw SteamError.notInstalled }
        var arguments = [steamExe.path]
        if silent { arguments.append("-silent") }
        return try prefix.spawn(arguments, log: log)
    }

    /// Opens a Steam URL (e.g. `steam://install/<appid>`) in the running client, starting it if needed.
    public func open(_ steamURL: String) throws {
        guard isInstalled else { throw SteamError.notInstalled }
        try prefix.spawn([steamExe.path, steamURL], log: log)
    }

    /// Asks Steam to exit cleanly, then kills whatever is left in the prefix.
    public func shutdown(grace: TimeInterval = 30) async {
        if isRunning {
            _ = try? await prefix.run([steamExe.path, "-shutdown"], log: log, timeout: 30)
            let deadline = Date.now.addingTimeInterval(grace)
            while isRunning, Date.now < deadline {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        await prefix.kill()
    }

    /// Steam writes its pid into the registry while running, but Wine flushes the registry lazily,
    /// so we look at live processes instead. The prefix's wineserver must also be up.
    public var isRunning: Bool {
        guard prefix.isServerRunning else { return false }
        return Self.runningWindowsProcesses().contains { $0.lowercased().hasSuffix(#"\steam\steam.exe"#) }
    }

    /// Whether the most recent logon state in `logs/connection_log.txt` is "Logged On".
    ///
    /// Lines look like `[2026-09-19 15:17:39] [Logged On, 1, 0] [U:1:123] ...`. With `since`,
    /// only state changes logged at or after that time count (the log survives restarts).
    public func isLoggedOn(since: Date? = nil) -> Bool {
        let url = steamRoot.appending(path: "logs/connection_log.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return Self.lastLogonState(in: text, since: since) == true
    }

    static func lastLogonState(in log: String, since: Date?) -> Bool? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for line in log.split(separator: "\n").reversed() {
            guard let stateRange = line.range(of: "[Logged ") else { continue }
            if let since {
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                      let date = formatter.date(from: String(line[line.index(after: line.startIndex)..<close])),
                      date >= since else { return nil }
            }
            return line[stateRange.upperBound...].hasPrefix("On")
        }
        return nil
    }

    /// Command lines of running Wine processes (their argv[0] is the Windows path).
    static func runningWindowsProcesses() -> [String] {
        let output = (try? Self.ps()) ?? ""
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: #"[A-Za-z]:\\.*?\.exe"#, options: .regularExpression) else { return nil }
            return String(trimmed[range])
        }
    }

    private static func ps() throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axo", "command"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
