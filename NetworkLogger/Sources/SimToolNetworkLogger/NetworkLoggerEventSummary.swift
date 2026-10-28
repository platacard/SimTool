import Foundation

public extension NetworkLoggerEvent {
    var displayApp: String {
        appBundleID ?? appDisplayName ?? ""
    }

    /// A call's method and where it went; a stream event's direction, kind and
    /// channel, or for the connection's lifecycle, where it goes.
    var displayRequest: String {
        if let stream {
            let arrow = stream.direction.map { $0 == .incoming ? "↓" : "↑" }
            let place = stream.direction == nil && stream.channel == nil ? request.url ?? request.path : stream.channel
            return [arrow, stream.kind.rawValue, place].compactMap { $0 }.joined(separator: " ")
        }
        if networkProtocol == .grpc {
            if let path = request.path { return path }
            return [request.grpcService, request.grpcMethod]
                .compactMap { $0 }
                .joined(separator: "/")
        }
        return [request.method, request.url ?? request.path]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    var displayStatus: String {
        if let stream {
            return [stream.code.map(String.init), stream.reason].compactMap { $0 }.joined(separator: " ")
        }
        if networkProtocol == .grpc {
            return [response?.grpcStatusCode, response?.grpcStatusMessage]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return response?.statusCode.map(String.init) ?? response?.status ?? ""
    }

    var displayDuration: String {
        String(format: "%.0fms", durationMilliseconds)
    }
}
