import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let output: String

    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessError: Error, CustomStringConvertible {
    case failed(command: String, exitCode: Int32, output: String)

    public var description: String {
        switch self {
        case let .failed(command, code, output):
            let tail = output.split(separator: "\n").suffix(15).joined(separator: "\n")
            return "\(command) exited with \(code)\n\(tail)"
        }
    }
}

/// Thin async wrapper over `Process`.
public enum ProcessRunner {
    /// Runs a process to completion, capturing stdout+stderr.
    /// When `log` is given, output is appended there instead of being captured.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        log: URL? = nil,
        check: Bool = true
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let pipe = Pipe()
        let logHandle = try log.map(openLog)
        defer { try? logHandle?.close() }
        process.standardOutput = logHandle ?? pipe
        process.standardError = logHandle ?? pipe
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        var output = ""
        if logHandle == nil {
            try? pipe.fileHandleForWriting.close()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            output = String(decoding: data, as: UTF8.self)
        }
        let result = ProcessResult(exitCode: status, output: output)
        if check, !result.succeeded {
            let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
            throw ProcessError.failed(command: command, exitCode: status, output: output)
        }
        return result
    }

    /// Starts a long-running process without waiting for it. Output goes to `log`.
    public static func spawn(
        _ executable: URL,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        log: URL
    ) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let handle = try openLog(log)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in try? handle.close() }
        try process.run()
        return process
    }

    private static func openLog(_ url: URL) throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
