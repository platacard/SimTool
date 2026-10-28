import Foundation

extension SimToolNetworkLogger {
    /// Starts a session for a long-lived connection — a WebSocket, a
    /// server-sent event stream, an MQTT or a raw socket connection — and
    /// returns it: the app tells it what happens on the connection, and each
    /// call reports one event. Nothing is reported until the first.
    ///
    /// Make one session per connection object and keep it across reconnects:
    /// the viewer shows a session as one row and its events as its messages.
    ///
    /// - Parameters:
    ///   - networkProtocol: the protocol's name, as the viewer lists and filters it.
    ///   - url: where the connection goes, when it has a URL. Sensitive query
    ///     parameters (`token=`) are redacted.
    ///   - target: where it goes when that is not a URL: `host:port`, a method path.
    ///   - subprotocol: what runs over the connection: `graphql-transport-ws`, a chat protocol.
    ///   - headers: the handshake's headers; redacted, and reported with the
    ///     session's first event and with `connecting` and `connected`.
    public func startStream(
        _ networkProtocol: NetworkLoggerProtocol,
        url: URL? = nil,
        target: String? = nil,
        subprotocol: String? = nil,
        headers: [String: String] = [:]
    ) -> NetworkLoggerStreamSession {
        NetworkLoggerStreamSession(
            logger: self,
            networkProtocol: networkProtocol,
            subprotocol: subprotocol,
            request: NetworkLoggerRequest(
                url: url.map { NetworkLoggerRedactor.redacted(url: $0, configuration: configuration.redaction) },
                host: url?.host,
                path: target ?? url?.path,
                headers: NetworkLoggerRedactor.redacted(headers, configuration: configuration.redaction)
            )
        )
    }

    /// A session for a `URLSessionWebSocketTask`, with the URL, subprotocol and
    /// headers of its request. Report its messages with `sent(webSocket:)` and
    /// `received(webSocket:)`, and its close with `disconnected(closeCode:reason:)`.
    public func startStream(webSocket task: URLSessionWebSocketTask) -> NetworkLoggerStreamSession {
        let request = task.originalRequest ?? task.currentRequest
        return startStream(
            .websocket,
            url: request?.url,
            subprotocol: request?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"),
            headers: request?.allHTTPHeaderFields ?? [:]
        )
    }

    /// A session for a streaming gRPC call — client, server or bidirectional
    /// streaming — from the app's interceptor: each message is `sent` or
    /// `received`, and the call's end is `disconnected(code:reason:)` with its
    /// status code and message, or `failed`.
    public func startGRPCStream(
        service: String? = nil,
        method: String? = nil,
        fullMethod: String? = nil,
        authority: String? = nil,
        requestMetadata: [String: String] = [:]
    ) -> NetworkLoggerStreamSession {
        NetworkLoggerStreamSession(
            logger: self,
            networkProtocol: .grpc,
            subprotocol: nil,
            request: NetworkLoggerRequest(
                host: authority,
                path: fullMethod ?? "/" + [service, method].compactMap { $0 }.joined(separator: "/"),
                grpcService: service,
                grpcMethod: method,
                grpcAuthority: authority,
                metadata: NetworkLoggerRedactor.redacted(requestMetadata, configuration: configuration.redaction)
            )
        )
    }
}

/// One long-lived connection. Every method reports one event and returns at
/// once — safe to call from any thread and from synchronous delegate
/// callbacks; the events reach SimTool in the order they were reported.
public final class NetworkLoggerStreamSession: @unchecked Sendable {
    public let id: String
    public let networkProtocol: NetworkLoggerProtocol
    public let subprotocol: String?

    private let logger: SimToolNetworkLogger
    private let request: NetworkLoggerRequest
    private let lock = NSLock()
    private var nextSequence = 0
    private var connectedAt: Date?

    init(logger: SimToolNetworkLogger, networkProtocol: NetworkLoggerProtocol, subprotocol: String?, request: NetworkLoggerRequest) {
        self.id = UUID().uuidString
        self.logger = logger
        self.networkProtocol = networkProtocol
        self.subprotocol = subprotocol
        self.request = request
    }

    // MARK: The connection

    @discardableResult
    public func connecting() -> NetworkLoggerEvent {
        record(.connecting)
    }

    /// The connection is open. `metadata` is what the server said about it: a client id, a session.
    @discardableResult
    public func connected(metadata: [String: String] = [:]) -> NetworkLoggerEvent {
        record(.connected, metadata: metadata)
    }

    /// The connection closed, with its close code and reason when the protocol has them.
    @discardableResult
    public func disconnected(code: Int? = nil, reason: String? = nil, metadata: [String: String] = [:]) -> NetworkLoggerEvent {
        record(.disconnected, code: code, reason: reason, metadata: metadata)
    }

    /// The connection failed: it could not open, or it broke.
    @discardableResult
    public func failed(_ error: Error? = nil, code: Int? = nil, reason: String? = nil) -> NetworkLoggerEvent {
        record(.error, code: code, reason: reason, error: error)
    }

    // MARK: A channel on it — a subscription, a topic, a room

    @discardableResult
    public func subscribing(_ channel: String) -> NetworkLoggerEvent {
        record(.subscribing, channel: channel)
    }

    @discardableResult
    public func subscribed(_ channel: String, metadata: [String: String] = [:]) -> NetworkLoggerEvent {
        record(.subscribed, channel: channel, metadata: metadata)
    }

    @discardableResult
    public func unsubscribed(_ channel: String, code: Int? = nil, reason: String? = nil) -> NetworkLoggerEvent {
        record(.unsubscribed, channel: channel, code: code, reason: reason)
    }

    @discardableResult
    public func subscriptionFailed(_ channel: String, code: Int? = nil, reason: String? = nil) -> NetworkLoggerEvent {
        record(.subscriptionError, channel: channel, code: code, reason: reason)
    }

    // MARK: Messages

    /// A message the app sent. `kind` names it as its protocol does when that
    /// says more than `message`: `publish`, `ping`, an event name.
    @discardableResult
    public func sent(
        _ payload: NetworkLoggerPayload?,
        channel: String? = nil,
        kind: NetworkLoggerStreamEventKind = .message,
        metadata: [String: String] = [:]
    ) -> NetworkLoggerEvent {
        record(kind, direction: .outgoing, channel: channel, payload: payload, metadata: metadata)
    }

    /// A message the app received.
    @discardableResult
    public func received(
        _ payload: NetworkLoggerPayload?,
        channel: String? = nil,
        kind: NetworkLoggerStreamEventKind = .message,
        metadata: [String: String] = [:]
    ) -> NetworkLoggerEvent {
        record(kind, direction: .incoming, channel: channel, payload: payload, metadata: metadata)
    }

    // MARK: Anything else

    /// Reports any event of the session: what the methods above report, or one
    /// of the protocol's own. A `direction` makes it a message; without one it
    /// is the connection's or a channel's lifecycle.
    @discardableResult
    public func record(
        _ kind: NetworkLoggerStreamEventKind,
        direction: NetworkLoggerStreamDirection? = nil,
        channel: String? = nil,
        payload: NetworkLoggerPayload? = nil,
        code: Int? = nil,
        reason: String? = nil,
        metadata: [String: String] = [:],
        error: Error? = nil
    ) -> NetworkLoggerEvent {
        let now = Date()
        let (sequence, upFor) = advance(kind, at: now)
        let configuration = logger.configuration
        let carried = configuration.record(of: payload)
        var request = self.request
        // The handshake's headers ride with the events about the handshake, and with
        // the first event, so a session the app never says connected still shows them.
        if sequence != 0, kind != .connecting, kind != .connected { request.headers = [:] }
        let event = NetworkLoggerEvent(
            timestamp: NetworkLoggerTimestamp.string(from: now),
            appBundleID: configuration.appBundleID,
            appDisplayName: configuration.appDisplayName,
            networkProtocol: networkProtocol,
            durationMilliseconds: upFor.map { now.timeIntervalSince($0) * 1_000 } ?? 0,
            request: request,
            error: error.map(NetworkLoggerError.init),
            stream: NetworkLoggerStream(
                sessionId: id,
                sequence: sequence,
                subprotocol: subprotocol,
                kind: kind,
                direction: direction,
                channel: channel,
                payloadPreview: carried.preview,
                payloadEncoding: carried.encoding,
                payloadByteCount: carried.byteCount,
                code: code,
                reason: reason,
                metadata: NetworkLoggerRedactor.redacted(metadata, configuration: configuration.redaction)
            )
        )
        logger.emit(event)
        return event
    }

    /// The event's place in the session and, for an event that ends the
    /// connection, since when it was up.
    private func advance(_ kind: NetworkLoggerStreamEventKind, at now: Date) -> (Int, Date?) {
        lock.lock(); defer { lock.unlock() }
        let sequence = nextSequence
        nextSequence += 1
        switch kind {
        case .connected:
            connectedAt = now
            return (sequence, nil)
        case .disconnected, .error:
            defer { connectedAt = nil }
            return (sequence, connectedAt)
        default:
            return (sequence, nil)
        }
    }
}

extension NetworkLoggerStreamSession {
    /// A message the app sent over a `URLSessionWebSocketTask`.
    @discardableResult
    public func sent(webSocket message: URLSessionWebSocketTask.Message, channel: String? = nil) -> NetworkLoggerEvent {
        sent(NetworkLoggerPayload(message), channel: channel)
    }

    /// A message the app received from a `URLSessionWebSocketTask`.
    @discardableResult
    public func received(webSocket message: URLSessionWebSocketTask.Message, channel: String? = nil) -> NetworkLoggerEvent {
        received(NetworkLoggerPayload(message), channel: channel)
    }

    /// A WebSocket's close, as `URLSessionWebSocketDelegate` reports it.
    @discardableResult
    public func disconnected(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) -> NetworkLoggerEvent {
        disconnected(code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) })
    }
}
