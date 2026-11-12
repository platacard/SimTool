import CryptoKit
import Foundation

/// A simulator build that lives at a URL — a CI's archive in a bucket — brought
/// to the Mac SimTool runs on: downloaded there (the archive never passes
/// through whoever asked for it), only the wanted `.app` unpacked, and kept for
/// the next time someone asks for the same build.
///
/// A CI archive often holds more than one bundle (the app and its UI-test
/// runner), and nests them (`Debug-iphonesimulator/<name>.app`), so the bundle
/// is found by name anywhere in it, not only at the top or under `Payload/`.
public enum SimulatorAppArchive {
    /// Downloads `url` into `file`. `headers` go to that URL alone and are
    /// never logged; `progress` hears the bytes received and, when the server
    /// says, the total.
    public static func download(
        _ url: URL,
        headers: [String: String] = [:],
        to file: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw SimToolError("A build is downloaded over http(s), not \(url.scheme ?? "a bare path")")
        }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let fetch = DownloadFetch(destination: file, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        // Silence for a minute is a dead link; a slow build of gigabytes is not.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 2 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: fetch, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                fetch.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// Unpacks the `.app` named `app` (with or without `.app`) — or the only
    /// one there is — from a zip (an `.ipa` too) or a tar into `directory`,
    /// and answers where it landed. Nothing else in the archive is unpacked.
    public static func unpackApp(from archive: URL, named app: String?, into directory: URL) async throws -> URL {
        let kind = try SimulatorAppInstaller.kind(of: archive)
        let listing = kind == "zip"
            ? try await run("/usr/bin/zipinfo", ["-1", archive.path], what: "Reading \(archive.lastPathComponent)")
            : try await run("/usr/bin/tar", ["-tf", archive.path], what: "Reading \(archive.lastPathComponent)")
        let entries = listing.stdoutString.split(separator: "\n").map(String.init)
        let prefix = try chooseApp(among: appBundles(in: entries), named: app, in: archive.lastPathComponent)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if kind == "zip" {
            if prefix.contains(where: { "*?[]\\".contains($0) }) {
                // A name unzip would read as a pattern: unpack it all instead.
                _ = try await run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path], what: "Unpacking \(archive.lastPathComponent)")
            } else {
                _ = try await run("/usr/bin/unzip", ["-q", "-o", archive.path, prefix + "*", "-d", directory.path], what: "Unpacking \(archive.lastPathComponent)")
            }
        } else {
            _ = try await run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path, String(prefix.dropLast())], what: "Unpacking \(archive.lastPathComponent)")
        }
        let bundle = directory.appendingPathComponent(String(prefix.dropLast()), isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Info.plist").path) else {
            throw SimToolError("\(archive.lastPathComponent) unpacked without \(prefix)Info.plist")
        }
        return bundle
    }

    /// Every `.app` bundle an archive's entries hold, as the path of its folder
    /// with a trailing slash, shallowest first; bundles inside a bundle
    /// (an app's extensions, watch app, plug-ins) and macOS metadata
    /// (`__MACOSX/`) are not candidates.
    static func appBundles(in entries: [String]) -> [String] {
        var found = Set<String>()
        for entry in entries where !entry.hasPrefix("__MACOSX/") {
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") && !$0.isEmpty }),
                  index < parts.count - 1 || entry.hasSuffix("/") else { continue }
            found.insert(parts[...index].joined(separator: "/") + "/")
        }
        return found.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
    }

    /// The bundle asked for by name — `MyApp Debug.app` or `MyApp Debug` —
    /// or, when none is named, the only one there is.
    static func chooseApp(among bundles: [String], named app: String?, in archive: String) throws -> String {
        let names = bundles.map { String($0.dropLast().split(separator: "/").last ?? "") }
        guard let app = app?.trimmingCharacters(in: .whitespaces), !app.isEmpty else {
            guard let only = bundles.first else { throw SimToolError("\(archive) holds no .app bundle") }
            guard bundles.count == 1 else {
                throw SimToolError("\(archive) holds \(bundles.count) apps — name one: \(names.joined(separator: ", "))")
            }
            return only
        }
        let wanted = app.hasSuffix(".app") ? app : app + ".app"
        guard let index = names.firstIndex(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else {
            throw SimToolError("\(archive) holds no \(wanted)" + (names.isEmpty ? "" : " — it holds \(names.joined(separator: ", "))"))
        }
        return bundles[index]
    }

    /// `url` as it may be shown and kept: without its query (a signed URL's
    /// signature) or fragment, and without credentials.
    public static func displaySource(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.lastPathComponent }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? url.lastPathComponent
    }

    private static func run(_ executable: String, _ arguments: [String], what: String) async throws -> ProcessOutput {
        let output = try await ProcessRunner.run(executable: URL(fileURLWithPath: executable), arguments: arguments, timeoutSeconds: 900)
        _ = try SimulatorDeviceControl.check(output, what: what)
        return output
    }
}

/// Builds already unpacked, by where they came from: asking for the same build
/// again installs it without downloading gigabytes again. The newest few are
/// kept (`~/Library/Caches/SimTool/builds/`), the rest removed.
public struct SimulatorAppDownloadCache: Sendable {
    public let directory: URL
    public let keep: Int

    public init(directory: URL? = nil, keep: Int = 2) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = directory ?? caches.appendingPathComponent("SimTool/builds", isDirectory: true)
        self.keep = max(1, keep)
    }

    /// The key of a build: its source without query, and the app chosen in it.
    public static func key(source: String, app: String?) -> String {
        let digest = SHA256.hash(data: Data("\(source)\n\(app ?? "")".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The bundle kept under `key`, if any — marked as just used.
    public func bundle(for key: String) -> URL? {
        let folder = directory.appendingPathComponent(key, isDirectory: true)
        let apps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" }),
              FileManager.default.fileExists(atPath: app.appendingPathComponent("Info.plist").path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        return app
    }

    /// Moves an unpacked bundle into the cache under `key`, drops the oldest
    /// builds beyond `keep`, and answers where the bundle now is.
    public func store(_ bundle: URL, for key: String) throws -> URL {
        let folder = directory.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: bundle, to: kept)
        prune()
        return kept
    }

    private func prune() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let byAge = folders.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for folder in byAge.dropFirst(keep) { try? FileManager.default.removeItem(at: folder) }
    }
}

/// One download, told through URLSession's delegate: progress as it comes,
/// the file moved into place as soon as it is complete (URLSession removes
/// its own copy right after), an HTTP failure said with the start of its body.
private final class DownloadFetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64, Int64?) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var lastReport = Date.distantPast

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.5 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastReport = now
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let head = (try? FileHandle(forReadingFrom: location)).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 300)
            } ?? Data()
            let said = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            failure = SimToolError("The download answered HTTP \(status)" + (said.isEmpty ? "" : ": \(said)"))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            progress(size, size)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = continuation
        self.continuation = nil
        if let error = error ?? failure {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
