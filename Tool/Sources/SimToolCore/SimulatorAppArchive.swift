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
    /// What says a build at a URL is still the one fetched before.
    public struct Validators: Codable, Equatable, Sendable {
        public var etag: String?
        public var lastModified: String?
        public var length: Int64?

        public init(etag: String? = nil, lastModified: String? = nil, length: Int64? = nil) {
            self.etag = etag
            self.lastModified = lastModified
            self.length = length
        }

        /// Read from an answer's headers; a range answer's total from `Content-Range`.
        init(_ response: HTTPURLResponse) {
            etag = response.value(forHTTPHeaderField: "ETag")
            lastModified = response.value(forHTTPHeaderField: "Last-Modified")
            if let range = response.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                length = total
            } else if response.statusCode == 200, response.expectedContentLength >= 0 {
                length = response.expectedContentLength
            }
        }

        /// The same build: the same tag — or, without tags, the same date —
        /// and no different length. Nothing to compare is no match.
        public func matches(_ other: Validators) -> Bool {
            if let length, let otherLength = other.length, length != otherLength { return false }
            if let etag, let otherTag = other.etag { return etag == otherTag }
            if let lastModified, let otherDate = other.lastModified { return lastModified == otherDate }
            return false
        }
    }

    /// The most a download may bring.
    public static let downloadLimit: Int64 = 8 * 1_073_741_824

    /// Downloads `url` into `file` and answers what identifies what came.
    /// `headers` go to that URL's origin alone — a redirect elsewhere gets
    /// none of them, one from https to http is refused — and are never
    /// logged; `progress` hears the bytes received and, when the server
    /// says, the total. A download larger than `limit`, or than the disk
    /// has room for, stops.
    @discardableResult
    public static func download(
        _ url: URL,
        headers: [String: String] = [:],
        to file: URL,
        limit: Int64 = downloadLimit,
        progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> Validators {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw SimToolError("A build is downloaded over http(s), not \(url.scheme ?? "a bare path")")
        }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let fetch = DownloadFetch(origin: url, headerNames: Array(headers.keys), destination: file, limit: limit, progress: progress)
        let session = URLSession(configuration: sessionConfiguration(), delegate: fetch, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                fetch.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        return fetch.validators ?? Validators()
    }

    /// What identifies the build at `url` now, read from the head of an
    /// answer to a one-byte range request (a signed URL signs GET, not HEAD);
    /// nil when the server does not say.
    public static func validators(of url: URL, headers: [String: String] = [:]) async -> Validators? {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let probe = HeadProbe(origin: url, headerNames: Array(headers.keys))
        let session = URLSession(configuration: sessionConfiguration(), delegate: probe, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Validators?, Never>) in
            probe.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // Silence for a minute is a dead link; a slow build of gigabytes is not.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 2 * 60 * 60
        return configuration
    }

    /// A redirect as the caller's headers allow it: to the same origin with
    /// them, to another without them, from https to http not at all.
    static func redirect(_ request: URLRequest, from origin: URL, headerNames: [String]) -> URLRequest? {
        guard let target = request.url else { return nil }
        if origin.scheme?.lowercased() == "https", target.scheme?.lowercased() != "https" { return nil }
        guard !sameOrigin(origin, target) else { return request }
        var stripped = request
        for name in headerNames { stripped.setValue(nil, forHTTPHeaderField: name) }
        return stripped
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
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
        if let outside = entries.first(where: escapes) {
            throw SimToolError("\(archive.lastPathComponent) holds a path outside itself: \(outside)")
        }
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
        guard within(bundle, directory) else {
            throw SimToolError("\(archive.lastPathComponent) unpacked \(prefix) outside where it was unpacked")
        }
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Info.plist").path) else {
            throw SimToolError("\(archive.lastPathComponent) unpacked without \(prefix)Info.plist")
        }
        if let link = linkLeaving(bundle) {
            throw SimToolError("\(prefix.dropLast()) holds a link out of itself: \(link)")
        }
        return bundle
    }

    /// An archive entry that names a place outside the archive: an absolute
    /// path, or one that climbs (`..`).
    static func escapes(_ entry: String) -> Bool {
        entry.hasPrefix("/") || entry.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    /// Whether `path`, links resolved, is inside `directory`.
    static func within(_ path: URL, _ directory: URL) -> Bool {
        let inner = path.standardizedFileURL.resolvingSymlinksInPath().path
        let outer = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return inner.hasPrefix(outer.hasSuffix("/") ? outer : outer + "/")
    }

    /// The first symbolic link in `bundle` that points out of it, if any, as
    /// `path inside → target`.
    static func linkLeaving(_ bundle: URL) -> String? {
        let root = bundle.standardizedFileURL
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return nil }
        for case let relative as String in walk {
            let item = root.appendingPathComponent(relative)
            guard (try? FileManager.default.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType) == .typeSymbolicLink,
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) else { continue }
            let resolved = target.hasPrefix("/") ? URL(fileURLWithPath: target) : item.deletingLastPathComponent().appendingPathComponent(target)
            if !within(resolved, root) { return relative + " → " + target }
        }
        return nil
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
/// again installs it without downloading gigabytes again — as long as the
/// server says it is the same (its ETag or date). The newest few are kept, the
/// rest removed; each server keeps its own (`~/Library/Caches/SimTool/builds/<simulator>/`),
/// so servers on one Mac do not remove or replace each other's builds.
public struct SimulatorAppDownloadCache: Sendable {
    public let directory: URL
    public let keep: Int

    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("SimTool/builds", isDirectory: true)
    }

    public init(directory: URL? = nil, keep: Int = 2) {
        self.directory = directory ?? Self.defaultDirectory
        self.keep = max(1, keep)
    }

    /// The key of a build: its source without query, and the app chosen in it.
    public static func key(source: String, app: String?) -> String {
        let digest = SHA256.hash(data: Data("\(source)\n\(app ?? "")".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The bundle kept under `key` when it is still the build `current`
    /// describes — marked as just used.
    public func bundle(for key: String, matching current: SimulatorAppArchive.Validators) -> URL? {
        let folder = directory.appendingPathComponent(key, isDirectory: true)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.sourceFile)),
              let kept = try? JSONDecoder().decode(SimulatorAppArchive.Validators.self, from: data),
              kept.matches(current) else { return nil }
        let apps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" }),
              FileManager.default.fileExists(atPath: app.appendingPathComponent("Info.plist").path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        return app
    }

    /// Moves an unpacked bundle into the cache under `key`, with what
    /// identifies it, drops the oldest builds beyond `keep`, and answers where
    /// the bundle now is.
    public func store(_ bundle: URL, for key: String, validators: SimulatorAppArchive.Validators) throws -> URL {
        let folder = directory.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: bundle, to: kept)
        try JSONEncoder().encode(validators).write(to: folder.appendingPathComponent(Self.sourceFile))
        prune()
        return kept
    }

    private static let sourceFile = "source.json"

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
/// its own copy right after), an HTTP failure said with the start of its body,
/// redirects as `SimulatorAppArchive.redirect` allows them, and a stop at the
/// size limit or the disk's room.
private final class DownloadFetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let origin: URL
    let headerNames: [String]
    let destination: URL
    let limit: Int64
    let progress: @Sendable (Int64, Int64?) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private(set) var validators: SimulatorAppArchive.Validators?
    private var failure: Error?
    private var lastReport = Date.distantPast
    private var roomChecked = false

    init(origin: URL, headerNames: [String], destination: URL, limit: Int64, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.origin = origin
        self.headerNames = headerNames
        self.destination = destination
        self.limit = limit
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = SimulatorAppArchive.redirect(request, from: origin, headerNames: headerNames)
        if allowed == nil {
            failure = SimToolError("The download was redirected from https to \(request.url?.scheme ?? "another scheme") — refused")
        }
        completionHandler(allowed)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        if totalBytesWritten > limit || (expected ?? 0) > limit {
            failure = SimToolError("The build is larger than \(limit / 1_073_741_824) GB — not downloaded")
            return downloadTask.cancel()
        }
        if !roomChecked, let expected {
            roomChecked = true
            // The archive and the app unpacked from it, with room to spare.
            let free = (try? destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? nil
            if let free, free < expected * 2 + 2 * 1_073_741_824 {
                failure = SimToolError("Not enough disk for a build of \(expected / 1_000_000) MB: \(free / 1_000_000) MB free")
                return downloadTask.cancel()
            }
        }
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.5 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastReport = now
        progress(totalBytesWritten, expected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if failure != nil { return }
            let head = (try? FileHandle(forReadingFrom: location)).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 300)
            } ?? Data()
            let said = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            failure = SimToolError("The download answered HTTP \(status)" + (said.isEmpty ? "" : ": \(said)"))
            return
        }
        if let response { validators = SimulatorAppArchive.Validators(response) }
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
        if let error = failure ?? error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

/// The head of an answer, and nothing more: the task stops once it came.
private final class HeadProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let origin: URL
    let headerNames: [String]
    var continuation: CheckedContinuation<SimulatorAppArchive.Validators?, Never>?

    init(origin: URL, headerNames: [String]) {
        self.origin = origin
        self.headerNames = headerNames
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(SimulatorAppArchive.redirect(request, from: origin, headerNames: headerNames))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 {
            let validators = SimulatorAppArchive.Validators(http)
            resume(validators.etag == nil && validators.lastModified == nil ? nil : validators)
        } else {
            resume(nil)
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        resume(nil)
    }

    private func resume(_ value: SimulatorAppArchive.Validators?) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}
