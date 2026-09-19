import Darwin
import Foundation

public enum PrefixError: Error, CustomStringConvertible {
    case notCreated(URL)
    case timedOut(String)

    public var description: String {
        switch self {
        case let .notCreated(url): "Prefix at \(url.path) has not been created yet"
        case let .timedOut(what): "\(what) timed out"
        }
    }
}

/// Metadata stored in `<prefix>/samovar.json`.
public struct PrefixManifest: Codable, Sendable {
    public var engineID: String
    public var createdAt: Date
}

/// A Wine prefix bound to the engine that created it.
public struct WinePrefix: Sendable {
    public let url: URL
    public let engine: WineEngine

    public init(url: URL, engine: WineEngine) {
        self.url = url
        self.engine = engine
    }

    public var driveC: URL { url.appending(path: "drive_c", directoryHint: .isDirectory) }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.appending(path: "system.reg").path) }
    private var manifestURL: URL { url.appending(path: "samovar.json") }

    /// Creates the prefix (`wineboot --init`) and applies Samovar's defaults. Idempotent.
    public func create(log: URL? = nil) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if !exists {
            try await run(["wineboot", "--init"], log: log, timeout: 180)
            try await waitForServer(timeout: 120)
        }
        try await applyDefaults(log: log)
        let manifest = PrefixManifest(engineID: engine.id, createdAt: .now)
        try JSONEncoder.samovar.encode(manifest).write(to: manifestURL)
    }

    /// Registry defaults that keep crashes from turning into dialogs or debugger respawns.
    private func applyDefaults(log: URL?) async throws {
        let reg: [[String]] = [
            // No crash dialog / auto-attached winedbg when a Windows process faults.
            ["reg", "add", #"HKCU\Software\Wine\WineDbg"#, "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f"],
            ["reg", "add", #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug"#, "/v", "Auto", "/t", "REG_SZ", "/d", "0", "/f"],
        ]
        for command in reg { try await run(command, log: log, timeout: 60) }
        try await waitForServer(timeout: 60)
    }

    // MARK: Running commands

    /// Runs `wine <arguments>` to completion with a hard timeout; on timeout the whole prefix is killed.
    @discardableResult
    public func run(
        _ arguments: [String],
        variant: RendererVariant? = nil,
        environment extra: [String: String] = [:],
        workingDirectory: URL? = nil,
        log: URL? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        Self.raiseFileLimit()
        let wine = variant?.wine ?? engine.wine
        let env = variant?.environment(prefix: url, extra: extra) ?? engine.environment(prefix: url, extra: extra)
        return try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
            group.addTask {
                try await ProcessRunner.run(wine, arguments, environment: env,
                                            workingDirectory: workingDirectory, log: log, check: false)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return nil
            }
            guard let first = try await group.next() else { throw PrefixError.timedOut("wine") }
            if let result = first {
                group.cancelAll()
                return result
            }
            // Timeout won the race: kill everything in the prefix so the runner returns.
            await kill()
            group.cancelAll()
            throw PrefixError.timedOut("wine \(arguments.joined(separator: " "))")
        }
    }

    /// Starts `wine <arguments>` without waiting.
    public func spawn(
        _ arguments: [String],
        variant: RendererVariant? = nil,
        environment extra: [String: String] = [:],
        workingDirectory: URL? = nil,
        log: URL
    ) throws -> Process {
        Self.raiseFileLimit()
        let wine = variant?.wine ?? engine.wine
        let env = variant?.environment(prefix: url, extra: extra) ?? engine.environment(prefix: url, extra: extra)
        return try ProcessRunner.spawn(wine, arguments, environment: env, workingDirectory: workingDirectory, log: log)
    }

    // MARK: wineserver

    /// Kills every process in the prefix. This is the only reliable way to stop CX Wine,
    /// whose binaries run from `$TMPDIR/winetemp-*`.
    public func kill() async {
        _ = try? await ProcessRunner.run(engine.wineserver, ["-k"], environment: engine.environment(prefix: url), check: false)
    }

    /// Waits for the prefix's wineserver to exit (all Windows processes gone).
    public func waitForServer(timeout: TimeInterval) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while isServerRunning {
            if Date.now > deadline { throw PrefixError.timedOut("waiting for wineserver") }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Whether a wineserver is accepting connections for this prefix.
    ///
    /// Wine keys its server by the prefix directory's device and inode:
    /// `/tmp/.wine-<uid>/server-<dev>-<ino>/socket`.
    public var isServerRunning: Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        let socketPath = String(format: "/tmp/.wine-%u/server-%llx-%llx/socket",
                                getuid(), UInt64(info.st_dev), UInt64(info.st_ino))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    /// GUI apps inherit a 256 file-descriptor limit, far too low for games; raise it once.
    static func raiseFileLimit() {
        _ = fileLimitRaised
    }

    private static let fileLimitRaised: Bool = {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return false }
        let target = min(limit.rlim_max, rlim_t(65536))
        guard limit.rlim_cur < target else { return true }
        limit.rlim_cur = target
        return setrlimit(RLIMIT_NOFILE, &limit) == 0
    }()
}
