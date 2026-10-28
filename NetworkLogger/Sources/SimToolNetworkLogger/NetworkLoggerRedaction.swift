import Foundation

public struct NetworkLoggerRedactionConfiguration: Equatable, Sendable {
    public static let defaultSensitiveKeys: Set<String> = [
        "authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "api-key",
        "apikey",
        "proxy-authorization",
    ]

    public var sensitiveKeys: Set<String>
    public var replacement: String

    public init(
        sensitiveKeys: Set<String> = Self.defaultSensitiveKeys,
        replacement: String = "<redacted>"
    ) {
        self.sensitiveKeys = sensitiveKeys
        self.replacement = replacement
    }
}

public enum NetworkLoggerRedactor {
    public static func isSensitive(_ key: String, sensitiveKeys: Set<String> = NetworkLoggerRedactionConfiguration.defaultSensitiveKeys) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sensitiveKeys.contains(normalized)
            || normalized.contains("token")
            || normalized.contains("secret")
            || normalized.contains("api-key")
            || normalized.contains("api_key")
            || normalized.contains("apikey")
            || normalized.contains("password")
    }

    public static func redacted(
        _ values: [String: String],
        configuration: NetworkLoggerRedactionConfiguration = NetworkLoggerRedactionConfiguration()
    ) -> [String: String] {
        values.reduce(into: [:]) { result, pair in
            result[pair.key] = isSensitive(pair.key, sensitiveKeys: configuration.sensitiveKeys)
                ? configuration.replacement
                : pair.value
        }
    }

    public static func preview(data: Data?, maxBytes: Int) -> String? {
        encodedPreview(data: data, maxBytes: maxBytes)?.text
    }

    /// The first `maxBytes` of `data` as text, or as base64 when they are not
    /// UTF-8 — then `encoding` is `base64`. A cut that splits a character drops
    /// the split bytes rather than making text look binary.
    public static func encodedPreview(data: Data?, maxBytes: Int) -> (text: String, encoding: String?)? {
        guard let data, maxBytes > 0 else { return nil }
        let bounded = Data(data.prefix(maxBytes))
        if let string = String(data: bounded, encoding: .utf8) {
            return (string, nil)
        }
        if bounded.count < data.count {
            for dropped in 1...3 where bounded.count > dropped {
                if let string = String(data: bounded.dropLast(dropped), encoding: .utf8) { return (string, nil) }
            }
        }
        return (bounded.base64EncodedString(), "base64")
    }

    /// `url` with the values of its sensitive query parameters (`token`,
    /// `api_key`…) replaced, as headers are: a socket's connect URL often
    /// carries its credentials there. The replacement is written as it is, to
    /// be read, so the result is a record of the URL rather than one to open.
    public static func redacted(
        url: URL,
        configuration: NetworkLoggerRedactionConfiguration = NetworkLoggerRedactionConfiguration()
    ) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.contains(where: { isSensitive($0.name, sensitiveKeys: configuration.sensitiveKeys) && $0.value != nil }) else {
            return url.absoluteString
        }
        let marker = "SIMTOOL-REDACTED-\(UUID().uuidString)"
        components.queryItems = items.map { item in
            guard item.value != nil, isSensitive(item.name, sensitiveKeys: configuration.sensitiveKeys) else { return item }
            return URLQueryItem(name: item.name, value: marker)
        }
        return components.string?.replacingOccurrences(of: marker, with: configuration.replacement) ?? url.absoluteString
    }
}
