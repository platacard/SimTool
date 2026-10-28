import Foundation

extension SimToolNetworkLogger {
    /// Starts a call of any request–response protocol — a GraphQL operation, a
    /// JSON-RPC method, a request over the app's own socket protocol — and
    /// returns the recorder that finishes it. Nothing is reported until then.
    ///
    /// - Parameters:
    ///   - networkProtocol: the protocol's name, as the viewer lists and filters it.
    ///   - method: the verb or operation: `GET`, `query Profile`, `eth_call`.
    ///   - url: where the call went, when it has a URL.
    ///   - target: where it went when that is not a URL: a method path, a topic, `host:port`.
    ///   - headers: headers or their protocol's equivalent; redacted.
    ///   - metadata: the protocol's own details; redacted like headers.
    ///   - body: what the app sent.
    public func startCall(
        _ networkProtocol: NetworkLoggerProtocol,
        method: String? = nil,
        url: URL? = nil,
        target: String? = nil,
        headers: [String: String] = [:],
        metadata: [String: String] = [:],
        body: NetworkLoggerPayload? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:]
    ) -> NetworkLoggerCallRecorder {
        let sent = configuration.record(of: body)
        return NetworkLoggerCallRecorder(
            logger: self,
            networkProtocol: networkProtocol,
            request: NetworkLoggerRequest(
                method: method,
                url: url.map { NetworkLoggerRedactor.redacted(url: $0, configuration: configuration.redaction) },
                host: url?.host,
                path: target ?? url?.path,
                headers: NetworkLoggerRedactor.redacted(headers, configuration: configuration.redaction),
                bodyByteCount: sent.byteCount,
                bodyPreview: sent.preview,
                bodyPreviewEncoding: sent.encoding,
                metadata: NetworkLoggerRedactor.redacted(metadata, configuration: configuration.redaction)
            ),
            rawMetadata: rawMetadata
        )
    }

    /// Starts an HTTP call made by the app's own HTTP layer — a client that
    /// does not go through an instrumented `URLSession`, or one that wants its
    /// own record of a call. `body` is the request's body when it is not in
    /// `httpBody` (a stream, an upload).
    public func startHTTPCall(
        _ request: URLRequest,
        body: Data? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:]
    ) -> NetworkLoggerCallRecorder {
        NetworkLoggerCallRecorder(
            logger: self,
            networkProtocol: .http,
            request: httpRequestRecord(request, body: body ?? request.httpBody),
            rawMetadata: rawMetadata
        )
    }
}

/// A call under way: `finish` reports it, with how long it took since it started.
/// Reporting never blocks the caller and never fails it; call `finish` once.
public struct NetworkLoggerCallRecorder: Sendable {
    /// The id the call's event will have.
    public let id: String
    public let networkProtocol: NetworkLoggerProtocol
    private let logger: SimToolNetworkLogger
    private let startedAt: Date
    private let request: NetworkLoggerRequest
    private let rawMetadata: [String: NetworkLoggerJSONValue]

    init(
        logger: SimToolNetworkLogger,
        networkProtocol: NetworkLoggerProtocol,
        request: NetworkLoggerRequest,
        rawMetadata: [String: NetworkLoggerJSONValue]
    ) {
        self.id = UUID().uuidString
        self.networkProtocol = networkProtocol
        self.logger = logger
        self.startedAt = Date()
        self.request = request
        self.rawMetadata = rawMetadata
    }

    /// Reports the call with its answer. With no answer at all — no status,
    /// headers, metadata or body — and an `error`, the call failed before
    /// anything came back.
    ///
    /// - Parameters:
    ///   - statusCode: a numeric status, as HTTP has.
    ///   - status: the status in the protocol's own words: `OK`, `NOT_FOUND`, `ack`.
    ///   - error: why the call failed. A `NetworkLoggerError` is reported as it is.
    @discardableResult
    public func finish(
        statusCode: Int? = nil,
        status: String? = nil,
        headers: [String: String] = [:],
        metadata: [String: String] = [:],
        body: NetworkLoggerPayload? = nil,
        error: Error? = nil
    ) -> NetworkLoggerEvent {
        let configuration = logger.configuration
        let answered = statusCode != nil || status != nil || !headers.isEmpty || !metadata.isEmpty || body != nil || error == nil
        let received = configuration.record(of: body)
        return report(answered ? NetworkLoggerResponse(
            statusCode: statusCode,
            status: status,
            headers: NetworkLoggerRedactor.redacted(headers, configuration: configuration.redaction),
            bodyByteCount: received.byteCount,
            bodyPreview: received.preview,
            bodyPreviewEncoding: received.encoding,
            metadata: NetworkLoggerRedactor.redacted(metadata, configuration: configuration.redaction)
        ) : nil, error: error)
    }

    /// Reports an HTTP call with what `URLSession` or the app's HTTP layer handed back.
    @discardableResult
    public func finish(response: URLResponse?, body: Data?, error: Error?) -> NetworkLoggerEvent {
        report((response as? HTTPURLResponse).map { logger.httpResponseRecord($0, body: body) }, error: error)
    }

    private func report(_ response: NetworkLoggerResponse?, error: Error?) -> NetworkLoggerEvent {
        let event = NetworkLoggerEvent(
            id: id,
            appBundleID: logger.configuration.appBundleID,
            appDisplayName: logger.configuration.appDisplayName,
            networkProtocol: networkProtocol,
            durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
            request: request,
            response: response,
            error: error.map(NetworkLoggerError.init),
            rawMetadata: rawMetadata
        )
        logger.emit(event)
        return event
    }
}
