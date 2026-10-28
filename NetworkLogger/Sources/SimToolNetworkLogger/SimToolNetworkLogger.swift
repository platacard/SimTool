import Foundation

public final class SimToolNetworkLogger: @unchecked Sendable {
    public static let shared = SimToolNetworkLogger()

    /// Builds a logger from process environment, or `nil` when capture is not enabled.
    ///
    /// A host app calls this once and holds the returned instance; `nil` means the host should
    /// perform no capture. See `NetworkLoggerConfiguration.fromEnvironment`.
    public static func makeFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SimToolNetworkLogger? {
        guard let configuration = NetworkLoggerConfiguration.fromEnvironment(environment) else { return nil }
        return SimToolNetworkLogger(configuration: configuration)
    }

    /// Builds a logger from the environment and, **only in the simulator**, a persisted activation
    /// marker, so app-emitted network events keep flowing after a cold relaunch that drops the
    /// `SIMTOOL_*` environment (icon tap, Xcode run). Returns `nil` when capture should not run.
    ///
    /// Prefer this over `makeFromEnvironment(_:)` for simulator development. See
    /// `NetworkLoggerConfiguration.resolved(environment:isSimulator:activationStore:defaultServerURL:)`.
    public static func resolved(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SimToolNetworkLogger? {
        guard let configuration = NetworkLoggerConfiguration.resolved(environment: environment) else { return nil }
        return SimToolNetworkLogger(configuration: configuration)
    }

    public let configuration: NetworkLoggerConfiguration

    private let sinks: [any NetworkLoggerSink]

    // Events emitted and not yet handed to the sinks, and the one task that hands
    // them over in order.
    private let outboxLock = NSLock()
    private var outbox: [NetworkLoggerEvent] = []
    private var outboxDrain: Task<Void, Never>?

    public init(configuration: NetworkLoggerConfiguration = NetworkLoggerConfiguration(), sinks: [any NetworkLoggerSink]? = nil) {
        self.configuration = configuration
        if let sinks {
            self.sinks = sinks
        } else {
            var configuredSinks: [any NetworkLoggerSink] = []
            if configuration.fileSinkEnabled {
                configuredSinks.append(NetworkLoggerFileSink(maxFileBytes: configuration.maxFileBytes))
            }
            if let serverSinkURL = configuration.serverSinkURL {
                configuredSinks.append(NetworkLoggerServerSink(serverURL: serverSinkURL, timeout: configuration.serverDeliveryTimeout))
            }
            self.sinks = configuredSinks
        }
    }

    public func instrument(_ configuration: URLSessionConfiguration) {
        NetworkLoggerURLProtocol.logger = self
        var protocolClasses = configuration.protocolClasses ?? []
        if !protocolClasses.contains(where: { $0 == NetworkLoggerURLProtocol.self }) {
            protocolClasses.insert(NetworkLoggerURLProtocol.self, at: 0)
        }
        configuration.protocolClasses = protocolClasses
    }

    public func instrumentedConfiguration(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        instrument(configuration)
        return configuration
    }

    /// Reports an event without waiting for it to be delivered. Events emitted
    /// one after another reach the sinks in that order, batched while the sinks
    /// are busy; `flush()` waits for them.
    public func emit(_ event: NetworkLoggerEvent) {
        outboxLock.lock(); defer { outboxLock.unlock() }
        outbox.append(event)
        guard outboxDrain == nil else { return }
        outboxDrain = Task { await self.drainOutbox() }
    }

    /// Waits until every event emitted so far has reached the sinks.
    public func flush() async {
        while let drain = currentOutboxDrain() {
            await drain.value
        }
    }

    public func record(_ event: NetworkLoggerEvent) async {
        await record([event])
    }

    public func record(_ events: [NetworkLoggerEvent]) async {
        for batch in Self.batches(events, size: configuration.batchSize) {
            for sink in sinks {
                await sink.record(batch)
            }
        }
    }

    /// Events in batches of at most `size` that never put a call a server before
    /// 1.0 reads — HTTP or gRPC — beside a stream event or another protocol: such
    /// a server refuses a whole batch over one event it cannot read.
    static func batches(_ events: [NetworkLoggerEvent], size: Int) -> [[NetworkLoggerEvent]] {
        var batches: [[NetworkLoggerEvent]] = []
        var index = events.startIndex
        while index < events.endIndex {
            let count = leadingBatchCount(events[index...], size: size)
            batches.append(Array(events[index..<index + count]))
            index += count
        }
        return batches
    }

    private static func leadingBatchCount(_ events: ArraySlice<NetworkLoggerEvent>, size: Int) -> Int {
        guard let first = events.first else { return 0 }
        let readsBefore1 = readableBefore1(first)
        var count = 0
        for event in events.prefix(max(1, size)) {
            guard readableBefore1(event) == readsBefore1 else { break }
            count += 1
        }
        return count
    }

    private static func readableBefore1(_ event: NetworkLoggerEvent) -> Bool {
        event.stream == nil && (event.networkProtocol == .http || event.networkProtocol == .grpc)
    }

    private func drainOutbox() async {
        while let batch = nextOutboxBatch() {
            for sink in sinks {
                await sink.record(batch)
            }
        }
    }

    private func nextOutboxBatch() -> [NetworkLoggerEvent]? {
        outboxLock.lock(); defer { outboxLock.unlock() }
        guard !outbox.isEmpty else {
            outboxDrain = nil
            return nil
        }
        let count = Self.leadingBatchCount(outbox[...], size: configuration.batchSize)
        let batch = Array(outbox.prefix(count))
        outbox.removeFirst(count)
        return batch
    }

    private func currentOutboxDrain() -> Task<Void, Never>? {
        outboxLock.lock(); defer { outboxLock.unlock() }
        return outboxDrain
    }

    @discardableResult
    public func recordHTTP(
        request: URLRequest,
        response: HTTPURLResponse? = nil,
        requestBody: Data? = nil,
        responseBody: Data? = nil,
        durationMilliseconds: Double,
        error: Error? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:],
        mocked: Bool = false,
        mockRuleId: String? = nil
    ) async -> NetworkLoggerEvent {
        let event = makeHTTPEvent(
            request: request,
            response: response,
            requestBody: requestBody,
            responseBody: responseBody,
            durationMilliseconds: durationMilliseconds,
            error: error,
            rawMetadata: rawMetadata,
            mocked: mocked,
            mockRuleId: mockRuleId
        )
        await record(event)
        return event
    }

    public func makeHTTPEvent(
        request: URLRequest,
        response: HTTPURLResponse? = nil,
        requestBody: Data? = nil,
        responseBody: Data? = nil,
        durationMilliseconds: Double,
        error: Error? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:],
        mocked: Bool = false,
        mockRuleId: String? = nil
    ) -> NetworkLoggerEvent {
        NetworkLoggerEvent(
            appBundleID: configuration.appBundleID,
            appDisplayName: configuration.appDisplayName,
            networkProtocol: .http,
            durationMilliseconds: durationMilliseconds,
            request: httpRequestRecord(request, body: requestBody ?? request.httpBody),
            response: response.map { httpResponseRecord($0, body: responseBody) },
            error: error.map(NetworkLoggerError.init),
            rawMetadata: rawMetadata,
            mocked: mocked,
            mockRuleId: mockRuleId
        )
    }

    func httpRequestRecord(_ request: URLRequest, body: Data?) -> NetworkLoggerRequest {
        let sent = configuration.record(of: body.map(NetworkLoggerPayload.data))
        return NetworkLoggerRequest(
            method: request.httpMethod,
            url: request.url.map { NetworkLoggerRedactor.redacted(url: $0, configuration: configuration.redaction) },
            host: request.url?.host,
            path: request.url?.path,
            headers: NetworkLoggerRedactor.redacted(request.allHTTPHeaderFields ?? [:], configuration: configuration.redaction),
            bodyByteCount: sent.byteCount,
            bodyPreview: sent.preview,
            bodyPreviewEncoding: sent.encoding
        )
    }

    func httpResponseRecord(_ response: HTTPURLResponse, body: Data?) -> NetworkLoggerResponse {
        let received = configuration.record(of: body.map(NetworkLoggerPayload.data))
        return NetworkLoggerResponse(
            statusCode: response.statusCode,
            headers: NetworkLoggerRedactor.redacted(response.stringHeaders, configuration: configuration.redaction),
            bodyByteCount: received.byteCount,
            bodyPreview: received.preview,
            bodyPreviewEncoding: received.encoding
        )
    }

    public func startGRPCCall(
        service: String? = nil,
        method: String? = nil,
        fullMethod: String? = nil,
        authority: String? = nil,
        requestMetadata: [String: String] = [:],
        requestMessageBytes: Int? = nil,
        requestMessagePreview: String? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:]
    ) -> NetworkLoggerGRPCRecorder {
        NetworkLoggerGRPCRecorder(
            logger: self,
            service: service,
            method: method,
            fullMethod: fullMethod,
            authority: authority,
            requestMetadata: requestMetadata,
            requestMessageBytes: requestMessageBytes,
            requestMessagePreview: requestMessagePreview,
            rawMetadata: rawMetadata
        )
    }

    @discardableResult
    public func recordGRPC(
        service: String? = nil,
        method: String? = nil,
        fullMethod: String? = nil,
        authority: String? = nil,
        requestMetadata: [String: String] = [:],
        responseMetadata: [String: String] = [:],
        statusCode: String? = nil,
        statusMessage: String? = nil,
        requestMessageBytes: Int? = nil,
        responseMessageBytes: Int? = nil,
        requestMessagePreview: String? = nil,
        responseMessagePreview: String? = nil,
        durationMilliseconds: Double,
        error: Error? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:],
        mocked: Bool = false,
        mockRuleId: String? = nil
    ) async -> NetworkLoggerEvent {
        let request = NetworkLoggerRequest(
            path: fullMethod,
            bodyPreview: boundedMessagePreview(requestMessagePreview),
            grpcService: service,
            grpcMethod: method,
            grpcAuthority: authority,
            metadata: NetworkLoggerRedactor.redacted(requestMetadata, configuration: configuration.redaction),
            messageByteCount: requestMessageBytes
        )
        let response = NetworkLoggerResponse(
            bodyPreview: boundedMessagePreview(responseMessagePreview),
            grpcStatusCode: statusCode,
            grpcStatusMessage: statusMessage,
            metadata: NetworkLoggerRedactor.redacted(responseMetadata, configuration: configuration.redaction),
            messageByteCount: responseMessageBytes
        )
        let event = NetworkLoggerEvent(
            appBundleID: configuration.appBundleID,
            appDisplayName: configuration.appDisplayName,
            networkProtocol: .grpc,
            durationMilliseconds: durationMilliseconds,
            request: request,
            response: response,
            error: error.map(NetworkLoggerError.init),
            rawMetadata: rawMetadata,
            mocked: mocked,
            mockRuleId: mockRuleId
        )
        await record(event)
        return event
    }

    /// Bounds a host-provided message preview to the configured ceiling when body capture is on.
    private func boundedMessagePreview(_ preview: String?) -> String? {
        guard configuration.captureBodyPreviews, let preview, !preview.isEmpty else { return nil }
        return NetworkLoggerRedactor.preview(data: Data(preview.utf8), maxBytes: configuration.maxBodyPreviewBytes)
    }
}

public struct NetworkLoggerGRPCRecorder: Sendable {
    private let logger: SimToolNetworkLogger
    private let startedAt: Date
    private let service: String?
    private let method: String?
    private let fullMethod: String?
    private let authority: String?
    private let requestMetadata: [String: String]
    private let requestMessageBytes: Int?
    private let requestMessagePreview: String?
    private let rawMetadata: [String: NetworkLoggerJSONValue]

    fileprivate init(
        logger: SimToolNetworkLogger,
        service: String?,
        method: String?,
        fullMethod: String?,
        authority: String?,
        requestMetadata: [String: String],
        requestMessageBytes: Int?,
        requestMessagePreview: String?,
        rawMetadata: [String: NetworkLoggerJSONValue]
    ) {
        self.logger = logger
        self.startedAt = Date()
        self.service = service
        self.method = method
        self.fullMethod = fullMethod
        self.authority = authority
        self.requestMetadata = requestMetadata
        self.requestMessageBytes = requestMessageBytes
        self.requestMessagePreview = requestMessagePreview
        self.rawMetadata = rawMetadata
    }

    @discardableResult
    public func finish(
        responseMetadata: [String: String] = [:],
        statusCode: String? = nil,
        statusMessage: String? = nil,
        responseMessageBytes: Int? = nil,
        responseMessagePreview: String? = nil,
        error: Error? = nil
    ) async -> NetworkLoggerEvent {
        await logger.recordGRPC(
            service: service,
            method: method,
            fullMethod: fullMethod,
            authority: authority,
            requestMetadata: requestMetadata,
            responseMetadata: responseMetadata,
            statusCode: statusCode,
            statusMessage: statusMessage,
            requestMessageBytes: requestMessageBytes,
            responseMessageBytes: responseMessageBytes,
            requestMessagePreview: requestMessagePreview,
            responseMessagePreview: responseMessagePreview,
            durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
            error: error,
            rawMetadata: rawMetadata
        )
    }
}

private final class NetworkLoggerURLProtocol: URLProtocol {
    static var logger: SimToolNetworkLogger?
    private static let handledKey = "SimToolNetworkLoggerHandled"
    private static let forwardingSession = URLSession(configuration: .default)

    private var forwardingTask: URLSessionDataTask?
    private var startedAt = Date()

    override class func canInit(with request: URLRequest) -> Bool {
        guard logger != nil,
              URLProtocol.property(forKey: handledKey, in: request) == nil,
              let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        startedAt = Date()
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)
        let forwardedRequest = mutableRequest as URLRequest
        forwardingTask = Self.forwardingSession.dataTask(with: forwardedRequest) { [weak self] data, response, error in
            guard let self else { return }
            let httpResponse = response as? HTTPURLResponse
            let duration = Date().timeIntervalSince(self.startedAt) * 1_000
            if let logger = Self.logger {
                Task {
                    await logger.recordHTTP(
                        request: forwardedRequest,
                        response: httpResponse,
                        requestBody: forwardedRequest.httpBody,
                        responseBody: data,
                        durationMilliseconds: duration,
                        error: error
                    )
                }
            }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        forwardingTask?.resume()
    }

    override func stopLoading() {
        forwardingTask?.cancel()
    }
}

private extension HTTPURLResponse {
    var stringHeaders: [String: String] {
        allHeaderFields.reduce(into: [:]) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        }
    }
}
