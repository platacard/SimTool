import Foundation

public enum NetworkLoggerJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: NetworkLoggerJSONValue])
    case array([NetworkLoggerJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: NetworkLoggerJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([NetworkLoggerJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// The wire protocol of a call or a stream. The set is open: `http`, `grpc` and
/// `websocket` are the names SimTool knows, and any other name an app's network
/// layer gives (`sse`, `mqtt`, `graphql`, `tcp`…) is kept, shown and filtered on
/// as it is, so a logger can report a protocol a server or viewer has never
/// heard of. Names are compared lowercased.
public struct NetworkLoggerProtocol: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public init(_ name: String) {
        self.init(rawValue: name)
    }

    public init(stringLiteral name: String) {
        self.init(rawValue: name)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let http: NetworkLoggerProtocol = "http"
    public static let grpc: NetworkLoggerProtocol = "grpc"
    public static let websocket: NetworkLoggerProtocol = "websocket"
}

public struct NetworkLoggerRequest: Codable, Equatable, Sendable {
    public var method: String?
    public var url: String?
    public var host: String?
    public var path: String?
    public var headers: [String: String]
    public var bodyByteCount: Int?
    public var bodyPreview: String?
    /// How `bodyPreview` is written: nil for text, `base64` for bytes that are not.
    public var bodyPreviewEncoding: String?
    public var grpcService: String?
    public var grpcMethod: String?
    public var grpcAuthority: String?
    public var metadata: [String: String]
    public var messageByteCount: Int?

    public init(
        method: String? = nil,
        url: String? = nil,
        host: String? = nil,
        path: String? = nil,
        headers: [String: String] = [:],
        bodyByteCount: Int? = nil,
        bodyPreview: String? = nil,
        bodyPreviewEncoding: String? = nil,
        grpcService: String? = nil,
        grpcMethod: String? = nil,
        grpcAuthority: String? = nil,
        metadata: [String: String] = [:],
        messageByteCount: Int? = nil
    ) {
        self.method = method
        self.url = url
        self.host = host
        self.path = path
        self.headers = headers
        self.bodyByteCount = bodyByteCount
        self.bodyPreview = bodyPreview
        self.bodyPreviewEncoding = bodyPreviewEncoding
        self.grpcService = grpcService
        self.grpcMethod = grpcMethod
        self.grpcAuthority = grpcAuthority
        self.metadata = metadata
        self.messageByteCount = messageByteCount
    }
}

public struct NetworkLoggerResponse: Codable, Equatable, Sendable {
    public var statusCode: Int?
    /// The answer's status in its protocol's own words, for a protocol whose
    /// status is not an HTTP code or a gRPC one: `OK`, `NOT_FOUND`, `ack`.
    public var status: String?
    public var headers: [String: String]
    public var bodyByteCount: Int?
    public var bodyPreview: String?
    /// How `bodyPreview` is written: nil for text, `base64` for bytes that are not.
    public var bodyPreviewEncoding: String?
    public var grpcStatusCode: String?
    public var grpcStatusMessage: String?
    public var metadata: [String: String]
    public var messageByteCount: Int?

    public init(
        statusCode: Int? = nil,
        status: String? = nil,
        headers: [String: String] = [:],
        bodyByteCount: Int? = nil,
        bodyPreview: String? = nil,
        bodyPreviewEncoding: String? = nil,
        grpcStatusCode: String? = nil,
        grpcStatusMessage: String? = nil,
        metadata: [String: String] = [:],
        messageByteCount: Int? = nil
    ) {
        self.statusCode = statusCode
        self.status = status
        self.headers = headers
        self.bodyByteCount = bodyByteCount
        self.bodyPreview = bodyPreview
        self.bodyPreviewEncoding = bodyPreviewEncoding
        self.grpcStatusCode = grpcStatusCode
        self.grpcStatusMessage = grpcStatusMessage
        self.metadata = metadata
        self.messageByteCount = messageByteCount
    }
}

public struct NetworkLoggerError: Error, Codable, Equatable, Sendable {
    public var domain: String?
    public var code: Int?
    public var message: String

    public init(domain: String? = nil, code: Int? = nil, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    public init(_ error: Error) {
        if let error = error as? NetworkLoggerError {
            self = error
            return
        }
        let nsError = error as NSError
        self.domain = nsError.domain
        self.code = nsError.code
        self.message = nsError.localizedDescription
    }
}

/// What happened on a stream: the connection's lifecycle, a channel's, or one
/// message. The set is open — an app names a message after its protocol
/// (`publication`, `ping`, an event name) and the name is kept as given.
public struct NetworkLoggerStreamEventKind: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ name: String) {
        self.init(rawValue: name)
    }

    public init(stringLiteral name: String) {
        self.init(rawValue: name)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    // The connection.
    public static let connecting: NetworkLoggerStreamEventKind = "connecting"
    public static let connected: NetworkLoggerStreamEventKind = "connected"
    public static let disconnected: NetworkLoggerStreamEventKind = "disconnected"
    public static let error: NetworkLoggerStreamEventKind = "error"
    // A channel on it: a subscription, a topic, a room.
    public static let subscribing: NetworkLoggerStreamEventKind = "subscribing"
    public static let subscribed: NetworkLoggerStreamEventKind = "subscribed"
    public static let unsubscribed: NetworkLoggerStreamEventKind = "unsubscribed"
    public static let subscriptionError: NetworkLoggerStreamEventKind = "subscriptionError"
    // A message, either way.
    public static let message: NetworkLoggerStreamEventKind = "message"
}

public enum NetworkLoggerStreamDirection: String, Codable, Equatable, Sendable {
    /// From the server to the app.
    case incoming = "in"
    /// From the app to the server.
    case outgoing = "out"
}

/// One event of a long-lived connection — a WebSocket, a server-sent event
/// stream, a gRPC stream, an MQTT or a raw socket session. Each event is its own
/// record, so ingest stays append-only; whoever shows them groups them by
/// `sessionId`. A message has a `direction`; the lifecycle of the connection or
/// of a channel has none.
public struct NetworkLoggerStream: Codable, Equatable, Sendable {
    /// One connection object's lifetime; its reconnects stay inside it.
    public var sessionId: String
    /// The event's place in its session, from 0: the order it happened in, even
    /// when two events share a timestamp or reach the server out of order.
    public var sequence: Int?
    /// What runs over the connection: `graphql-transport-ws`, `mqtt`, a chat
    /// protocol's name. Nil for a bare connection.
    public var subprotocol: String?
    public var kind: NetworkLoggerStreamEventKind
    public var direction: NetworkLoggerStreamDirection?
    /// The channel, topic, room or stream the event belongs to, if the protocol has them.
    public var channel: String?
    public var payloadPreview: String?
    /// How `payloadPreview` is written: nil for text, `base64` for bytes that are not.
    public var payloadEncoding: String?
    public var payloadByteCount: Int?
    /// A close code, an error code, a protocol's status number.
    public var code: Int?
    public var reason: String?
    /// The protocol's own details: a client id, an offset, a message id. Redacted like headers.
    public var metadata: [String: String]

    public init(
        sessionId: String,
        sequence: Int? = nil,
        subprotocol: String? = nil,
        kind: NetworkLoggerStreamEventKind,
        direction: NetworkLoggerStreamDirection? = nil,
        channel: String? = nil,
        payloadPreview: String? = nil,
        payloadEncoding: String? = nil,
        payloadByteCount: Int? = nil,
        code: Int? = nil,
        reason: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.sessionId = sessionId
        self.sequence = sequence
        self.subprotocol = subprotocol
        self.kind = kind
        self.direction = direction
        self.channel = channel
        self.payloadPreview = payloadPreview
        self.payloadEncoding = payloadEncoding
        self.payloadByteCount = payloadByteCount
        self.code = code
        self.reason = reason
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, sequence, subprotocol, kind, direction, channel, payloadPreview, payloadEncoding, payloadByteCount, code, reason, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence)
        subprotocol = try container.decodeIfPresent(String.self, forKey: .subprotocol)
        kind = try container.decode(NetworkLoggerStreamEventKind.self, forKey: .kind)
        // A direction this release does not know reads as none rather than failing the event.
        direction = (try? container.decodeIfPresent(NetworkLoggerStreamDirection.self, forKey: .direction)) ?? nil
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        payloadPreview = try container.decodeIfPresent(String.self, forKey: .payloadPreview)
        payloadEncoding = try container.decodeIfPresent(String.self, forKey: .payloadEncoding)
        payloadByteCount = try container.decodeIfPresent(Int.self, forKey: .payloadByteCount)
        code = try container.decodeIfPresent(Int.self, forKey: .code)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

public struct NetworkLoggerEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var timestamp: String
    public var appBundleID: String?
    public var appDisplayName: String?
    public var networkProtocol: NetworkLoggerProtocol
    public var durationMilliseconds: Double
    public var request: NetworkLoggerRequest
    public var response: NetworkLoggerResponse?
    public var error: NetworkLoggerError?
    public var rawMetadata: [String: NetworkLoggerJSONValue]
    /// Emitting process identifier, when known. Lets a SimTool server attribute the event to an
    /// app launch. Optional so existing payloads keep round-tripping.
    public var pid: Int?
    /// App launch this event belongs to, assigned by the SimTool server on ingestion. Apps leave
    /// this `nil`; only the server populates it.
    public var launchId: Int?
    /// True when this event's response was produced by a SimTool mock rule rather than the backend.
    public var mocked: Bool
    /// Identifier of the mock rule that produced the response, when `mocked` is true.
    public var mockRuleId: String?
    /// Set when the event belongs to a stream — a connection's lifecycle or one
    /// of its messages — rather than being a call with a request and a response.
    public var stream: NetworkLoggerStream?

    public init(
        id: String = UUID().uuidString,
        timestamp: String = NetworkLoggerTimestamp.now(),
        appBundleID: String? = nil,
        appDisplayName: String? = nil,
        networkProtocol: NetworkLoggerProtocol,
        durationMilliseconds: Double,
        request: NetworkLoggerRequest,
        response: NetworkLoggerResponse? = nil,
        error: NetworkLoggerError? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:],
        pid: Int? = nil,
        launchId: Int? = nil,
        mocked: Bool = false,
        mockRuleId: String? = nil,
        stream: NetworkLoggerStream? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appBundleID = appBundleID
        self.appDisplayName = appDisplayName
        self.networkProtocol = networkProtocol
        self.durationMilliseconds = durationMilliseconds
        self.request = request
        self.response = response
        self.error = error
        self.rawMetadata = rawMetadata
        self.pid = pid
        self.launchId = launchId
        self.mocked = mocked
        self.mockRuleId = mockRuleId
        self.stream = stream
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case appBundleID
        case appDisplayName
        case networkProtocol = "protocol"
        case durationMilliseconds
        case request
        case response
        case error
        case rawMetadata
        case pid
        case launchId
        case mocked
        case mockRuleId
        case stream
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        appBundleID = try container.decodeIfPresent(String.self, forKey: .appBundleID)
        appDisplayName = try container.decodeIfPresent(String.self, forKey: .appDisplayName)
        networkProtocol = try container.decode(NetworkLoggerProtocol.self, forKey: .networkProtocol)
        durationMilliseconds = try container.decode(Double.self, forKey: .durationMilliseconds)
        request = try container.decode(NetworkLoggerRequest.self, forKey: .request)
        response = try container.decodeIfPresent(NetworkLoggerResponse.self, forKey: .response)
        error = try container.decodeIfPresent(NetworkLoggerError.self, forKey: .error)
        rawMetadata = try container.decodeIfPresent([String: NetworkLoggerJSONValue].self, forKey: .rawMetadata) ?? [:]
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        launchId = try container.decodeIfPresent(Int.self, forKey: .launchId)
        mocked = try container.decodeIfPresent(Bool.self, forKey: .mocked) ?? false
        mockRuleId = try container.decodeIfPresent(String.self, forKey: .mockRuleId)
        stream = try container.decodeIfPresent(NetworkLoggerStream.self, forKey: .stream)
    }
}

public struct NetworkLoggerBatchPayload: Codable, Equatable, Sendable {
    public var source: String?
    public var events: [NetworkLoggerEvent]
    /// Emitting process identifier shared by every event in the batch, used by a SimTool server to
    /// attribute the batch to an app launch. Optional so existing payloads keep round-tripping.
    public var pid: Int?
    /// The sending logger's `SimToolNetworkLogger.version`. Loggers before 1.0 send none.
    public var loggerVersion: String?

    public init(events: [NetworkLoggerEvent], source: String? = nil, pid: Int? = nil, loggerVersion: String? = nil) {
        self.source = source
        self.events = events
        self.pid = pid
        self.loggerVersion = loggerVersion
    }
}

extension NetworkLoggerBatchPayload {
    /// Reads a batch event by event: an event the reader cannot decode — from a
    /// logger newer than it, say — is skipped and counted, and costs the batch
    /// nothing else. Throws only when the batch itself is not one.
    public static func decodingEachEvent(
        from data: Data,
        decoder: JSONDecoder = NetworkLoggerJSON.decoder
    ) throws -> (batch: NetworkLoggerBatchPayload, rejectedCount: Int) {
        let lenient = try decoder.decode(LenientBatch.self, from: data)
        return (lenient.batch, lenient.rejectedCount)
    }

    private struct LenientBatch: Decodable {
        var batch: NetworkLoggerBatchPayload
        var rejectedCount = 0

        private enum CodingKeys: String, CodingKey {
            case source, events, pid, loggerVersion
        }

        /// Decodes anything, so a list can step past an element it cannot read.
        private struct Skipped: Decodable {
            init(from decoder: Decoder) {}
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var list = try container.nestedUnkeyedContainer(forKey: .events)
            var events: [NetworkLoggerEvent] = []
            while !list.isAtEnd {
                if let event = try? list.decode(NetworkLoggerEvent.self) {
                    events.append(event)
                } else {
                    _ = try list.decode(Skipped.self)
                    rejectedCount += 1
                }
            }
            batch = NetworkLoggerBatchPayload(
                events: events,
                source: try container.decodeIfPresent(String.self, forKey: .source),
                pid: try container.decodeIfPresent(Int.self, forKey: .pid),
                loggerVersion: try container.decodeIfPresent(String.self, forKey: .loggerVersion)
            )
        }
    }
}

public struct NetworkLoggerEventsPayload: Codable, Equatable, Sendable {
    public var eventCount: Int
    public var events: [NetworkLoggerEvent]
    public var warnings: [String]

    public init(events: [NetworkLoggerEvent], warnings: [String] = []) {
        self.eventCount = events.count
        self.events = events
        self.warnings = warnings
    }
}

public struct NetworkLoggerIngestionResponse: Codable, Equatable, Sendable {
    public var acceptedCount: Int
    /// Events in the batch the server could not read and skipped; nil when it read them all.
    public var rejectedCount: Int?

    public init(acceptedCount: Int, rejectedCount: Int? = nil) {
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
    }
}

public struct NetworkLoggerEventFilter: Codable, Equatable, Sendable {
    public var app: String?
    public var networkProtocol: NetworkLoggerProtocol?
    /// Only the events of this stream session.
    public var session: String?
    public var since: String?
    public var limit: Int?

    public init(
        app: String? = nil,
        networkProtocol: NetworkLoggerProtocol? = nil,
        session: String? = nil,
        since: String? = nil,
        limit: Int? = nil
    ) {
        self.app = app
        self.networkProtocol = networkProtocol
        self.session = session
        self.since = since
        self.limit = limit
    }

    public func apply(to events: [NetworkLoggerEvent]) -> [NetworkLoggerEvent] {
        let sinceDate = since.flatMap(NetworkLoggerTimestamp.date(from:))
        var filtered = events.filter { event in
            if let app, event.appBundleID != app { return false }
            if let networkProtocol, event.networkProtocol != networkProtocol { return false }
            if let session, event.stream?.sessionId != session { return false }
            if let since {
                if let sinceDate, let eventDate = NetworkLoggerTimestamp.date(from: event.timestamp) {
                    return eventDate >= sinceDate
                }
                if event.timestamp < since { return false }
            }
            return true
        }
        if let limit {
            filtered = Array(filtered.suffix(max(0, limit)))
        }
        return filtered
    }
}
