import CryptoKit
import Foundation

public enum DownloadError: Error, CustomStringConvertible {
    case badStatus(URL, Int)
    case checksumMismatch(file: URL, expected: String, actual: String)

    public var description: String {
        switch self {
        case let .badStatus(url, code): "Download of \(url) failed with HTTP \(code)"
        case let .checksumMismatch(file, expected, actual):
            "Checksum mismatch for \(file.lastPathComponent): expected \(expected), got \(actual)"
        }
    }
}

public enum Downloader {
    /// Downloads `url` to `destination`, replacing it. Verifies SHA-256 when `sha256` is given.
    /// Skips the download when `destination` already exists with the expected checksum.
    public static func fetch(
        _ url: URL,
        to destination: URL,
        sha256: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        if let sha256, fm.fileExists(atPath: destination.path),
           (try? SHA256Hasher.hash(of: destination)) == sha256 {
            progress?(1)
            return
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let delegate = ProgressDelegate(progress)
        let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? fm.removeItem(at: tempURL)
            throw DownloadError.badStatus(url, http.statusCode)
        }
        if let sha256 {
            let actual = try SHA256Hasher.hash(of: tempURL)
            guard actual == sha256 else {
                try? fm.removeItem(at: tempURL)
                throw DownloadError.checksumMismatch(file: destination, expected: sha256, actual: actual)
            }
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tempURL, to: destination)
        progress?(1)
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
        let onProgress: (@Sendable (Double) -> Void)?
        init(_ onProgress: (@Sendable (Double) -> Void)?) { self.onProgress = onProgress }

        func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
            guard expected > 0 else { return }
            onProgress?(Double(written) / Double(expected))
        }

        // Required by the protocol; the async `download(from:)` API handles the file itself.
        func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
    }
}

public enum SHA256Hasher {
    public static func hash(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
