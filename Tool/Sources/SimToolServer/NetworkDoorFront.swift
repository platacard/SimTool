import Foundation
import Network

/// What the network door reads of an HTTP/1.1 message head: enough to frame
/// it — where the next message starts — and nothing more.
struct HTTPMessageHead: Equatable {
    /// `GET /path HTTP/1.1`, or `HTTP/1.1 200 OK`: the start line's words.
    var startLine: [String]
    /// In order, as sent; names as written.
    var fields: [(name: String, value: String)]

    static func == (a: HTTPMessageHead, b: HTTPMessageHead) -> Bool {
        a.startLine == b.startLine && a.fields.map { [$0.name, $0.value] } == b.fields.map { [$0.name, $0.value] }
    }

    /// The head of `bytes` (up to and including the empty line), or nil when
    /// it does not read as one.
    static func parse(_ bytes: Data) -> HTTPMessageHead? {
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        while lines.last == "" { lines.removeLast() }
        guard let first = lines.first, !first.isEmpty else { return nil }
        let startLine = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard startLine.count >= 2 else { return nil }
        var fields: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
            let name = String(line[..<colon])
            guard !name.contains(" ") else { return nil }
            fields.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return HTTPMessageHead(startLine: startLine, fields: fields)
    }

    func values(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    func has(_ name: String) -> Bool { !values(name).isEmpty }

    /// The comma-separated tokens of every field of `name`, lowercased.
    func tokens(_ name: String) -> Set<String> {
        Set(values(name).flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    /// `Content-Length`: nil when absent, and `.invalid` when it is not one
    /// non-negative number (repeated with different values included).
    var contentLength: ContentLength {
        let all = values("Content-Length")
        guard let first = all.first else { return .absent }
        guard all.allSatisfy({ $0 == first }), let value = Int64(first), value >= 0 else { return .invalid }
        return .length(value)
    }

    enum ContentLength: Equatable { case absent, invalid, length(Int64) }

    /// The head as bytes, its fields named `dropping` left out and `adding` appended.
    func serialized(dropping: Set<String> = [], adding: [(String, String)] = []) -> Data {
        var text = startLine.joined(separator: " ") + "\r\n"
        for field in fields where !dropping.contains(field.name.lowercased()) {
            text += "\(field.name): \(field.value)\r\n"
        }
        for (name, value) in adding { text += "\(name): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }
}

/// How the door handles one request from the network, decided from its head
/// before anything reaches the server.
enum DoorRequestPlan: Equatable {
    /// Refused here: status line, reason; the connection closes after it.
    case refuse(status: Int, phrase: String, reason: String)
    /// A protocol switch (the input WebSocket): the rest of the connection is
    /// passed through as it is.
    case upgrade
    /// A request with a body of `bodyLength` bytes (0 without one); the
    /// connection stays open after its response unless `closeAfter`.
    case forward(bodyLength: Int64, closeAfter: Bool)

    static func plan(_ head: HTTPMessageHead, bodyLimit: Int64) -> DoorRequestPlan {
        guard head.startLine.count == 3, head.startLine[2].hasPrefix("HTTP/1.") else {
            return .refuse(status: 400, phrase: "Bad Request", reason: "Not an HTTP/1.1 request")
        }
        if head.has("Transfer-Encoding") {
            // The server reads a body by its length only.
            return .refuse(status: 411, phrase: "Length Required", reason: "Send the body with a Content-Length")
        }
        let length: Int64
        switch head.contentLength {
        case .absent: length = 0
        case .invalid: return .refuse(status: 400, phrase: "Bad Request", reason: "Content-Length is not one number")
        case let .length(value): length = value
        }
        if length > bodyLimit {
            return .refuse(status: 413, phrase: "Content Too Large",
                           reason: "A body over the network is at most \(bodyLimit / 1_048_576) MB; install a larger build on the Mac itself or from a URL")
        }
        if head.has("Upgrade"), head.tokens("Connection").contains("upgrade") { return .upgrade }
        let closeAfter = head.startLine[2] == "HTTP/1.0" || head.tokens("Connection").contains("close")
        return .forward(bodyLength: length, closeAfter: closeAfter)
    }

    /// The request as the server gets it: asked to close once it answered,
    /// so the end of its answer is the end of that connection.
    static func upstreamHead(_ head: HTTPMessageHead) -> Data {
        head.serialized(dropping: ["connection", "keep-alive", "proxy-connection"], adding: [("Connection", "close")])
    }
}

/// Where a response from the server ends, read from its head.
enum DoorResponseFraming: Equatable {
    /// `bytes` of body follow the head; the client's connection may carry
    /// the next request.
    case length(Int64)
    /// The body runs until the server closes (a stream, the event stream):
    /// the client is told, and its connection closes after it.
    case untilClose

    static func framing(of response: HTTPMessageHead, requestMethod: String) -> DoorResponseFraming {
        let status = response.startLine.count > 1 ? Int(response.startLine[1]) ?? 0 : 0
        if requestMethod.uppercased() == "HEAD" || (100..<200).contains(status) || status == 204 || status == 304 { return .length(0) }
        if case let .length(value) = response.contentLength, !response.has("Transfer-Encoding") { return .length(value) }
        return .untilClose
    }

    /// The response head as the client gets it.
    func clientHead(_ response: HTTPMessageHead) -> Data {
        switch self {
        case .length: return response.serialized(dropping: ["connection", "keep-alive"])
        case .untilClose: return response.serialized(dropping: ["connection", "keep-alive"], adding: [("Connection", "close")])
        }
    }
}

/// One TLS connection from the network, decrypted, in front of the server
/// for the network. The server answers one request per connection and closes
/// it without saying so; a browser that reuses its connection then runs into
/// a closed one and starts again — over and over for a page whose certificate
/// it was told to accept. So the door keeps the browser's connection and
/// gives each request a connection of its own to the server, and refuses
/// what the server would choke on (a body it cannot hold) before it gets
/// there.
final class DoorFront: @unchecked Sendable {
    static let headLimit = 64 * 1024
    /// The largest request body passed on from the network: the server holds
    /// a body in memory.
    static let bodyLimit: Int64 = 512 * 1_048_576
    /// How long a browser may keep a connection open between requests.
    static let idleTimeout: TimeInterval = 15

    /// What the client's next bytes are for.
    private enum Phase {
        /// The head of its next request.
        case head
        /// The body of the request being passed on.
        case body
        /// Nothing, while the server's answer goes back: its next request
        /// (pipelined) waits in the buffer, the end of its connection ends ours.
        case relaying
        /// A protocol switch: both ways pass through as they come.
        case passthrough
    }

    private let client: NWConnection
    private let port: UInt16
    private let queue: DispatchQueue
    /// Bytes from the client not yet passed on.
    private var buffer = Data()
    private var upstream: NWConnection?
    private var phase = Phase.head
    /// One read of the client at a time; its bytes go where the phase says.
    private var receiving = false
    private var clientDone = false
    private var bodyContinuation: (() -> Void)?
    private var closed = false
    private var timer: DispatchWorkItem?

    init(client: NWConnection, port: UInt16, queue: DispatchQueue) {
        self.client = client
        self.port = port
        self.queue = queue
    }

    /// The server is reached only once the client finished its TLS
    /// handshake; one that does not within `handshakeTimeout` is let go.
    func start() {
        client.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: nextRequest()
            case .failed, .cancelled: close()
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + NetworkDoor.handshakeTimeout) { [self] in
            if client.state != .ready { close() }
        }
        client.start(queue: queue)
    }

    // MARK: - The client's bytes

    private func readClient() {
        guard !receiving, !clientDone, !closed else { return }
        receiving = true
        client.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, complete, error in
            receiving = false
            guard !closed else { return }
            if let data, !data.isEmpty { buffer.append(data) }
            if error != nil { return close() }
            if complete { clientDone = true }
            clientProgress()
        }
    }

    private func clientProgress() {
        switch phase {
        case .head:
            nextRequest()
        case .body:
            let next = bodyContinuation
            bodyContinuation = nil
            next?()
        case .relaying:
            // A browser does not end its side mid-answer; one that does is gone.
            if clientDone { return close() }
            if buffer.count <= Self.headLimit { readClient() }
        case .passthrough:
            // What a read begun before the switch brought goes on first.
            guard let up = upstream else { return }
            let bytes = buffer
            buffer.removeAll()
            send(bytes, to: up) { [self] in
                if clientDone { finish(up) } else { pump(from: client, to: up) }
            }
        }
    }

    // MARK: - A request

    private func nextRequest() {
        guard !closed else { return }
        phase = .head
        if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
            disarm()
            let head = Data(buffer[buffer.startIndex..<end.upperBound])
            buffer = Data(buffer[end.upperBound...])
            return handle(head)
        }
        if buffer.count > Self.headLimit {
            return refuse(431, "Request Header Fields Too Large", "The request head is too long")
        }
        if clientDone { return close() }
        arm(Self.idleTimeout)
        readClient()
    }

    private func handle(_ bytes: Data) {
        guard let head = HTTPMessageHead.parse(bytes) else {
            return refuse(400, "Bad Request", "The request head does not read")
        }
        switch DoorRequestPlan.plan(head, bodyLimit: Self.bodyLimit) {
        case let .refuse(status, phrase, reason):
            refuse(status, phrase, reason)
        case .upgrade:
            phase = .passthrough
            connectUpstream { [self] up in
                let early = buffer
                buffer.removeAll()
                send(bytes + early, to: up) { [self] in
                    pump(from: up, to: client)
                    // A read already under way hands its bytes on itself.
                    if !receiving { pump(from: client, to: up) }
                }
            }
        case let .forward(bodyLength, closeAfter):
            let method = head.startLine[0]
            connectUpstream { [self] up in
                send(DoorRequestPlan.upstreamHead(head), to: up) { [self] in
                    sendBody(remaining: bodyLength, to: up) { [self] in
                        relayResponse(from: up, method: method, closeAfter: closeAfter)
                    }
                }
            }
        }
    }

    private func sendBody(remaining: Int64, to up: NWConnection, then done: @escaping () -> Void) {
        phase = .body
        guard remaining > 0 else { return done() }
        if !buffer.isEmpty {
            let take = Int(min(Int64(buffer.count), remaining))
            let chunk = Data(buffer.prefix(take))
            buffer = Data(buffer.dropFirst(take))
            return send(chunk, to: up) { [self] in sendBody(remaining: remaining - Int64(take), to: up, then: done) }
        }
        if clientDone { return close() }
        bodyContinuation = { [self] in sendBody(remaining: remaining, to: up, then: done) }
        readClient()
    }

    // MARK: - The answer

    private func relayResponse(from up: NWConnection, method: String, closeAfter: Bool) {
        phase = .relaying
        // A client gone while the server answers ends the answer too (a
        // stream's writer learns it from its next write).
        readClient()
        readResponseHead(from: up, so: Data()) { [self] response, rest in
            let framing = DoorResponseFraming.framing(of: response, requestMethod: method)
            send(framing.clientHead(response), to: client) { [self] in
                switch framing {
                case let .length(length):
                    relayBody(from: up, first: rest, remaining: length) { [self] in
                        up.stateUpdateHandler = nil
                        up.cancel()
                        if upstream === up { upstream = nil }
                        if closeAfter { finishClient() } else { nextRequest() }
                    }
                case .untilClose:
                    send(rest, to: client) { [self] in pump(from: up, to: client) }
                }
            }
        }
    }

    private func readResponseHead(from up: NWConnection, so soFar: Data, then next: @escaping (HTTPMessageHead, Data) -> Void) {
        up.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, complete, error in
            guard !closed else { return }
            var head = soFar
            if let data { head.append(data) }
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                guard let response = HTTPMessageHead.parse(Data(head[head.startIndex..<end.upperBound])) else { return close() }
                return next(response, Data(head[end.upperBound...]))
            }
            if head.count > Self.headLimit || error != nil || complete { return close() }
            readResponseHead(from: up, so: head, then: next)
        }
    }

    private func relayBody(from up: NWConnection, first: Data, remaining: Int64, then done: @escaping () -> Void) {
        let take = Int(min(Int64(first.count), remaining))
        let left = remaining - Int64(take)
        send(Data(first.prefix(take)), to: client) { [self] in
            guard left > 0 else { return done() }
            up.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, complete, error in
                guard !closed else { return }
                if let data, !data.isEmpty { return relayBody(from: up, first: data, remaining: left, then: done) }
                if error != nil || complete { return close() }
                relayBody(from: up, first: Data(), remaining: left, then: done)
            }
        }
    }

    // MARK: - Plumbing

    private func connectUpstream(_ ready: @escaping (NWConnection) -> Void) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let up = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any, using: NWParameters(tls: nil, tcp: tcp))
        upstream = up
        var started = false
        up.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard !started else { return }
                started = true
                ready(up)
            case .failed, .cancelled:
                guard upstream === up else { return }
                if started { close() } else { refuse(502, "Bad Gateway", "The server did not answer") }
            default:
                break
            }
        }
        up.start(queue: queue)
    }

    private func send(_ data: Data, to connection: NWConnection, then next: @escaping () -> Void) {
        guard !data.isEmpty else { return next() }
        connection.send(content: data, completion: .contentProcessed { [self] error in
            guard !closed else { return }
            if error != nil { return close() }
            next()
        })
    }

    /// One way as it comes, until that side is done — then both go.
    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, complete, error in
            guard !closed else { return }
            if let data, !data.isEmpty {
                send(data, to: sink) { [self] in
                    if complete { finish(sink) } else { pump(from: source, to: sink) }
                }
            } else if error != nil || complete {
                finish(sink)
            } else {
                pump(from: source, to: sink)
            }
        }
    }

    private func finish(_ sink: NWConnection) {
        sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in close() })
    }

    private func finishClient() {
        finish(client)
    }

    private func refuse(_ status: Int, _ phrase: String, _ reason: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": reason])) ?? Data()
        let head = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        if let up = upstream {
            up.stateUpdateHandler = nil
            up.cancel()
            upstream = nil
        }
        send(Data(head.utf8) + body, to: client) { [self] in finishClient() }
    }

    private func arm(_ seconds: TimeInterval) {
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.close() }
        timer = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func disarm() {
        timer?.cancel()
        timer = nil
    }

    private func close() {
        guard !closed else { return }
        closed = true
        disarm()
        bodyContinuation = nil
        client.stateUpdateHandler = nil
        client.cancel()
        if let up = upstream {
            up.stateUpdateHandler = nil
            up.cancel()
            upstream = nil
        }
    }
}
