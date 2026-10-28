import Foundation

public protocol NetworkLoggerSink: Sendable {
    func record(_ events: [NetworkLoggerEvent]) async
}

public final class NetworkLoggerFileSink: NetworkLoggerSink, @unchecked Sendable {
    public static let directoryName = "SimToolNetworkLogger"
    public static let eventsFileName = "events.jsonl"
    public static let appContainerRelativePath = "Library/Caches/SimToolNetworkLogger/events.jsonl"

    public let directoryURL: URL
    public let maxFileBytes: Int

    private let queue = DispatchQueue(label: "simtool.network-logger.file-sink")
    private let fileManager: FileManager

    public init(
        directoryURL: URL? = nil,
        maxFileBytes: Int = 1_000_000,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let defaultDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            ?? fileManager.temporaryDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
        self.directoryURL = directoryURL ?? defaultDirectory
        self.maxFileBytes = maxFileBytes
    }

    public var fileURL: URL {
        directoryURL.appendingPathComponent(Self.eventsFileName, isDirectory: false)
    }

    public func record(_ events: [NetworkLoggerEvent]) async {
        guard !events.isEmpty else { return }
        queue.sync {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    fileManager.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                for event in events {
                    let data = try NetworkLoggerJSON.data(event)
                    try handle.write(contentsOf: data)
                    try handle.write(contentsOf: Data("\n".utf8))
                }
                try enforceMaximumSize()
            } catch {
                // Logging must never affect the host app's original network operation.
            }
        }
    }

    private func enforceMaximumSize() throws {
        guard maxFileBytes > 0,
              let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > maxFileBytes else { return }

        let data = try Data(contentsOf: fileURL)
        var suffix = Data(data.suffix(maxFileBytes))
        if let newline = suffix.firstIndex(of: UInt8(ascii: "\n")), newline < suffix.endIndex - 1 {
            suffix.removeSubrange(suffix.startIndex...newline)
        }
        try suffix.write(to: fileURL, options: .atomic)
    }
}

public final class NetworkLoggerServerSink: NetworkLoggerSink, @unchecked Sendable {
    public let serverURL: URL
    public let timeout: TimeInterval

    private let session: URLSession

    public init(serverURL: URL, session: URLSession = .shared, timeout: TimeInterval = 2) {
        self.serverURL = serverURL
        self.session = session
        self.timeout = timeout
    }

    public func record(_ events: [NetworkLoggerEvent]) async {
        guard !events.isEmpty else { return }
        do {
            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try NetworkLoggerJSON.data(NetworkLoggerBatchPayload(
                events: events,
                source: "ios-app",
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                loggerVersion: SimToolNetworkLogger.version
            ))
            _ = try await session.data(for: request)
        } catch {
            // Live export is best-effort and must not affect app networking.
        }
    }

    private var endpointURL: URL {
        let path = serverURL.path
        if path.hasSuffix("/api/v1/network/events") { return serverURL }
        if path.hasSuffix("/api/v1") { return serverURL.appendingPathComponent("network/events") }
        return serverURL.appendingPathComponent("api/v1/network/events")
    }
}

public enum NetworkLoggerJSONL {
    public static func readEvents(from fileURL: URL, filter: NetworkLoggerEventFilter = NetworkLoggerEventFilter()) throws -> NetworkLoggerEventsPayload {
        let data = try Data(contentsOf: fileURL)
        let text = String(decoding: data, as: UTF8.self)
        let events = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> NetworkLoggerEvent? in
            try? NetworkLoggerJSON.decoder.decode(NetworkLoggerEvent.self, from: Data(line.utf8))
        }
        return NetworkLoggerEventsPayload(events: filter.apply(to: events))
    }
}

/// The events a server keeps: the newest `capacity` calls and, apart from them,
/// the newest `streamCapacity` stream events — so a chatty socket never pushes
/// the calls out.
public final class NetworkLoggerEventStore: @unchecked Sendable {
    public let capacity: Int
    public let streamCapacity: Int

    private let lock = NSLock()
    private var calls: [NetworkLoggerEvent] = []
    private var streamEvents: [NetworkLoggerEvent] = []

    public init(capacity: Int = 1_000, streamCapacity: Int = 3_000) {
        self.capacity = max(0, capacity)
        self.streamCapacity = max(0, streamCapacity)
    }

    @discardableResult
    public func ingest(_ incomingEvents: [NetworkLoggerEvent]) -> NetworkLoggerIngestionResponse {
        lock.lock()
        defer { lock.unlock() }
        var accepted = 0
        for event in incomingEvents {
            if event.stream == nil {
                guard capacity > 0 else { continue }
                calls.append(event)
            } else {
                guard streamCapacity > 0 else { continue }
                streamEvents.append(event)
            }
            accepted += 1
        }
        if calls.count > capacity { calls.removeFirst(calls.count - capacity) }
        if streamEvents.count > streamCapacity { streamEvents.removeFirst(streamEvents.count - streamCapacity) }
        return NetworkLoggerIngestionResponse(acceptedCount: accepted)
    }

    /// Calls and stream events in the order they happened, each kind in the
    /// order it arrived.
    public func query(filter: NetworkLoggerEventFilter = NetworkLoggerEventFilter()) -> NetworkLoggerEventsPayload {
        lock.lock()
        let calls = self.calls, streamEvents = self.streamEvents
        lock.unlock()
        return NetworkLoggerEventsPayload(events: filter.apply(to: Self.merged(calls, streamEvents)))
    }

    /// Removes every stored event attributed to `launchId`, returning how many were dropped.
    @discardableResult
    public func deleteEvents(launchId: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let before = calls.count + streamEvents.count
        calls.removeAll { $0.launchId == launchId }
        streamEvents.removeAll { $0.launchId == launchId }
        return before - calls.count - streamEvents.count
    }

    /// Loggers stamp events in UTC with fractional seconds, so their timestamps
    /// sort as text.
    private static func merged(_ left: [NetworkLoggerEvent], _ right: [NetworkLoggerEvent]) -> [NetworkLoggerEvent] {
        guard !left.isEmpty, !right.isEmpty else { return left.isEmpty ? right : left }
        var merged: [NetworkLoggerEvent] = []
        merged.reserveCapacity(left.count + right.count)
        var l = left.startIndex, r = right.startIndex
        while l < left.endIndex, r < right.endIndex {
            if right[r].timestamp < left[l].timestamp {
                merged.append(right[r]); r += 1
            } else {
                merged.append(left[l]); l += 1
            }
        }
        merged.append(contentsOf: left[l...])
        merged.append(contentsOf: right[r...])
        return merged
    }
}
