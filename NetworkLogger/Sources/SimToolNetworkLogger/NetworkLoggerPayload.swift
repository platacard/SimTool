import Foundation

/// A message body as the app has it: the bytes that went over the wire, or text.
/// The logger keeps a bounded preview of it — when `captureBodyPreviews` is on —
/// and its size.
public struct NetworkLoggerPayload: Equatable, Sendable, ExpressibleByStringLiteral {
    public var data: Data?
    public var text: String?
    /// The size on the wire; nil when the app does not know it.
    public var byteCount: Int?

    public init(data: Data? = nil, text: String? = nil, byteCount: Int? = nil) {
        self.data = data
        self.text = text
        self.byteCount = byteCount
    }

    /// The bytes as sent or received. A preview reads them as UTF-8 text, or as
    /// base64 when they are not.
    public static func data(_ data: Data) -> NetworkLoggerPayload {
        NetworkLoggerPayload(data: data, byteCount: data.count)
    }

    /// Text that went over the wire as it is: a WebSocket text frame, a JSON
    /// body, a server-sent event's data.
    public static func text(_ text: String) -> NetworkLoggerPayload {
        NetworkLoggerPayload(text: text, byteCount: text.utf8.count)
    }

    /// A readable rendering of a message that went over the wire in another
    /// form — the protobuf text format of a binary message, a description —
    /// with the size the wire carried, when the app knows it.
    public static func rendered(_ text: String, byteCount: Int? = nil) -> NetworkLoggerPayload {
        NetworkLoggerPayload(text: text, byteCount: byteCount)
    }

    public init(stringLiteral text: String) {
        self = .text(text)
    }
}

extension NetworkLoggerPayload {
    /// A WebSocket message as text or bytes; nil for a kind this SDK does not know.
    public init?(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .string(text): self = .text(text)
        case let .data(data): self = .data(data)
        @unknown default: return nil
        }
    }
}

/// What the logger keeps of a payload.
struct NetworkLoggerPayloadRecord {
    var preview: String?
    var encoding: String?
    var byteCount: Int?
}

extension NetworkLoggerConfiguration {
    func record(of payload: NetworkLoggerPayload?) -> NetworkLoggerPayloadRecord {
        guard let payload else { return NetworkLoggerPayloadRecord() }
        var record = NetworkLoggerPayloadRecord(byteCount: payload.byteCount)
        guard captureBodyPreviews else { return record }
        if let data = payload.data {
            let preview = NetworkLoggerRedactor.encodedPreview(data: data, maxBytes: maxBodyPreviewBytes)
            record.preview = preview?.text
            record.encoding = preview?.encoding
        } else if let text = payload.text, !text.isEmpty {
            record.preview = NetworkLoggerRedactor.preview(data: Data(text.utf8), maxBytes: maxBodyPreviewBytes)
        }
        return record
    }
}
