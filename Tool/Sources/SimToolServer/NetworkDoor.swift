import Darwin
import Foundation
import Network
import SimToolCore

/// A server's port when it is open to the network. Every connection to the
/// port comes here first, and its first byte says what it is:
///
/// - TLS (a ClientHello, `0x16`) — the network door, from any address: it is
///   decrypted with the server's certificate and handed to the server for the
///   network (`NetworkDoorServer`), an HTTPS origin;
/// - plain HTTP from this Mac (loopback) — the server for this Mac, as when
///   the server is not open: the viewer at `http://127.0.0.1`, the CLI, the
///   loggers in the simulator;
/// - plain HTTP from the network — a page pointing to HTTPS and to the
///   certificate (`NetworkPages.landing`), and nothing else.
///
/// Both servers listen on loopback ports of their own; this door splices
/// each connection to its server byte for byte, so a slow reader still slows
/// its writer down. Swifter speaks no TLS and accepts only its own sockets,
/// hence the splice.
///
/// The port is a BSD socket with `SO_REUSEADDR`, like Swifter's: Network's
/// listener refuses a port while connections of a server that just stopped
/// linger on it (TIME_WAIT), which would fail a restart for half a minute.
final class NetworkDoor: @unchecked Sendable {
    private let port: UInt16
    private let localPort: UInt16
    private let networkPort: UInt16
    private let identity: NetworkServerIdentity
    private let landing: @Sendable (_ host: String?) -> String
    /// SimTool's certificate authority, downloadable over plain HTTP too.
    private let authority: Data?
    private let queue = DispatchQueue(label: "simtool.network-door", qos: .userInteractive)
    private let lock = NSLock()
    private var listening: Int32 = -1
    /// Written once to wake the accept loop for good; the loop closes the
    /// port and says so on `loopEnded`.
    private var wake: Int32 = -1
    private let loopEnded = DispatchSemaphore(value: 0)
    private var secure: NWListener?
    private var securePort: UInt16 = 0
    /// Connections from the network open now. A few viewers use a few dozen;
    /// past `networkConnectionLimit` a new one is closed at once, so nobody
    /// on the network can tie up the server's threads and descriptors.
    private var networkConnections = 0
    static let networkConnectionLimit = 48
    /// How long a TLS client may take to finish its handshake.
    static let handshakeTimeout: TimeInterval = 10

    /// - Parameters:
    ///   - port: the server's port, on every interface.
    ///   - localPort: the server for this Mac, on 127.0.0.1.
    ///   - networkPort: the server for the network, on 127.0.0.1.
    ///   - landing: the page a plain request from the network gets, for the
    ///     Host it named.
    init(port: UInt16, localPort: UInt16, networkPort: UInt16, identity: NetworkServerIdentity, landing: @escaping @Sendable (_ host: String?) -> String) {
        self.port = port
        self.localPort = localPort
        self.networkPort = networkPort
        self.identity = identity
        self.authority = identity.authority
        self.landing = landing
    }

    /// Opens the port; throws when it cannot (in use: `EADDRINUSE`).
    func start() throws {
        let tls = NWProtocolTLS.Options()
        guard let local = sec_identity_create_with_certificates(identity.identity, identity.chain as CFArray) else {
            throw SimToolError("The server certificate cannot be used for TLS")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let secure = try NWListener(using: parameters)
        secure.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            Splice(inbound: connection, port: self.networkPort, queue: self.queue).start()
        }
        securePort = try Self.open(secure, queue: queue)
        self.secure = secure

        let socket: Int32
        do {
            socket = try Self.listen(on: port)
        } catch {
            secure.cancel()
            self.secure = nil
            throw error
        }
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else {
            Darwin.close(socket)
            secure.cancel()
            self.secure = nil
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
        }
        lock.withLock {
            listening = socket
            wake = pipeEnds[1]
        }
        let wakeRead = pipeEnds[0]
        let thread = Thread { [weak self] in self?.acceptLoop(socket, wake: wakeRead) }
        thread.name = "simtool.network-door.accept"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Wakes the accept loop, which closes the port on its way out — so its
    /// descriptor is never reused under it — and waits for that, so the port
    /// is free for a server started right after.
    func stop() {
        let wakeWrite = lock.withLock { () -> Int32 in
            defer {
                listening = -1
                wake = -1
            }
            return wake
        }
        if wakeWrite >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wakeWrite, &byte, 1)
            Darwin.close(wakeWrite)
            _ = loopEnded.wait(timeout: .now() + 2)
        }
        secure?.cancel()
        secure = nil
    }

    private func acceptLoop(_ socket: Int32, wake: Int32) {
        defer {
            Darwin.close(socket)
            Darwin.close(wake)
            loopEnded.signal()
        }
        // Non-blocking: a connection gone between the poll and the accept
        // does not hold the loop.
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        while true {
            var watched = [pollfd(fd: socket, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
            if poll(&watched, 2, -1) < 0 {
                if errno != EINTR { usleep(100_000) }
                continue
            }
            if watched[1].revents != 0 { return }
            guard watched[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = Darwin.accept(socket, nil, nil)
            if client < 0 {
                // Out of descriptors or memory for a moment: the door stays open.
                if errno != EINTR && errno != ECONNABORTED && errno != EAGAIN { usleep(100_000) }
                continue
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            let thread = Thread { [weak self] in
                guard let self else { Darwin.close(client); return }
                self.route(client)
            }
            thread.name = "simtool.network-door.connection"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    /// Reads the connection's first bytes and hands it to whoever answers it.
    private func route(_ client: Int32) {
        SocketIO.prepare(client)
        let local = SocketIO.peerIsLoopback(client)
        if !local {
            let admitted = lock.withLock { () -> Bool in
                guard networkConnections < Self.networkConnectionLimit else { return false }
                networkConnections += 1
                return true
            }
            guard admitted else {
                DebugLog.write("server", "network door: too many connections, one closed")
                Darwin.close(client)
                return
            }
        }
        defer { if !local { lock.withLock { networkConnections -= 1 } } }
        // A connection that says nothing for a while is not kept waiting for.
        SocketIO.setReadTimeout(client, seconds: 30)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(client, &buffer, buffer.count)
        SocketIO.setReadTimeout(client, seconds: 0)
        guard count > 0 else { Darwin.close(client); return }
        let first = Data(buffer[0..<count])
        if first[0] == 0x16 {
            SocketSplice.run(client: client, first: first, port: securePort)
        } else if local {
            SocketSplice.run(client: client, first: first, port: localPort)
        } else {
            PlainRequest(socket: client, head: first, authority: authority, page: landing).respond()
        }
    }

    /// A dual-stack socket listening on `port` on every interface (IPv4 alone
    /// where IPv6 is off).
    static func listen(on port: UInt16) throws -> Int32 {
        var socket = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        var bound: Int32
        var on: Int32 = 1, off: Int32 = 0
        if socket >= 0 {
            setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(socket, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard bound == 0, Darwin.listen(socket, SOMAXCONN) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
            Darwin.close(socket)
            throw POSIXError(code)
        }
        return socket
    }

    /// Starts a listener and waits until it listens: its port, or why not.
    private static func open(_ listener: NWListener, queue: DispatchQueue) throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        let outcome = ListenerOutcome<UInt16>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.set(.success(listener.port?.rawValue ?? 0))
                ready.signal()
            case let .failed(error), let .waiting(error):
                outcome.set(.failure(SimToolError("The TLS listener failed: \(error)")))
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let result = outcome.result else {
            listener.cancel()
            throw SimToolError("The TLS listener did not start")
        }
        if case .failure = result { listener.cancel() }
        listener.stateUpdateHandler = nil
        return try result.get()
    }

    private final class ListenerOutcome<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Value, Error>?
        var result: Result<Value, Error>? { lock.withLock { stored } }
        func set(_ value: Result<Value, Error>) { lock.withLock { if stored == nil { stored = value } } }
    }
}

/// Socket chores the door's connections share.
enum SocketIO {
    /// No SIGPIPE for a peer that is gone, no Nagle delay for small frames.
    static func prepare(_ socket: Int32) {
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setReadTimeout(_ socket: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Whether the other end is this Mac's loopback: 127.0.0.0/8 or ::1,
    /// also as an IPv4-mapped IPv6 address.
    static func peerIsLoopback(_ socket: Int32) -> Bool {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let read = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(socket, $0, &length) } }
        guard read == 0 else { return false }
        switch Int32(storage.ss_family) {
        case AF_INET:
            let address = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr } }
            return UInt32(bigEndian: address) >> 24 == 127
        case AF_INET6:
            let bytes = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            } }
            if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
            let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
            return mapped && bytes[12] == 127
        default:
            return false
        }
    }

    /// Connects to `port` on 127.0.0.1.
    static func connectLoopback(_ port: UInt16) -> Int32? {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else {
            Darwin.close(socket)
            return nil
        }
        prepare(socket)
        return socket
    }

    /// Writes all of `bytes`; false once the peer is gone.
    static func writeAll(_ socket: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(socket, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    static func writeAll(_ socket: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { writeAll(socket, $0) }
    }
}

/// A connection from the port joined to a server on a loopback port, both
/// ways, one thread each. The client finishing its side is passed on (the
/// server may still answer); the server finishing, or either side failing,
/// ends both — a client that stays silent is not waited for.
private final class SocketSplice: @unchecked Sendable {
    private let client: Int32
    private let upstream: Int32
    private let lock = NSLock()
    private var open = 2

    private init(client: Int32, upstream: Int32) {
        self.client = client
        self.upstream = upstream
    }

    /// Runs on the calling thread until the connection is over.
    static func run(client: Int32, first: Data, port: UInt16) {
        guard let upstream = SocketIO.connectLoopback(port) else { Darwin.close(client); return }
        guard SocketIO.writeAll(upstream, first) else {
            Darwin.close(upstream)
            Darwin.close(client); return
        }
        let splice = SocketSplice(client: client, upstream: upstream)
        let back = Thread { splice.pump(from: upstream, to: client) }
        back.name = "simtool.network-door.splice"
        back.qualityOfService = .userInteractive
        back.start()
        splice.pump(from: client, to: upstream)
    }

    private func pump(from source: Int32, to sink: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var failed = false
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                failed = true
                break
            }
            let sent = buffer.withUnsafeBytes { SocketIO.writeAll(sink, UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            if !sent {
                failed = true
                break
            }
        }
        if failed || source == upstream {
            // Wakes the other direction, wherever it waits; what was written
            // to the client still goes out before its end.
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.shutdown(upstream, SHUT_RDWR)
        } else {
            Darwin.shutdown(sink, SHUT_WR)
        }
        let last = lock.withLock { () -> Bool in
            open -= 1
            return open == 0
        }
        if last {
            Darwin.close(client)
            Darwin.close(upstream)
        }
    }
}

/// A TLS connection out of the door's own listener joined to the server for
/// the network, both ways, until either side is done. Each direction reads
/// again only once what it read went out, so a client that reads slowly
/// holds the server's writes back rather than piling them up here.
private final class Splice: @unchecked Sendable {
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue: DispatchQueue
    private var directionsOpen = 2
    private var closed = false

    init(inbound: NWConnection, port: UInt16, queue: DispatchQueue) {
        self.inbound = inbound
        self.queue = queue
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        outbound = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any, using: NWParameters(tls: nil, tcp: tcp))
    }

    /// The server is reached only once the client finished its TLS
    /// handshake; one that does not within `handshakeTimeout` is let go.
    func start() {
        inbound.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: outbound.start(queue: queue)
            case .failed, .cancelled: close()
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + NetworkDoor.handshakeTimeout) { [self] in
            if inbound.state != .ready { close() }
        }
        outbound.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                pump(from: inbound, to: outbound)
                pump(from: outbound, to: inbound)
            case .failed, .cancelled:
                close()
            default:
                break
            }
        }
        inbound.start(queue: queue)
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, complete, error in
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { [self] sendError in
                    if sendError != nil { return close() }
                    if complete { finish(sink) } else { pump(from: source, to: sink) }
                })
            } else if error != nil {
                close()
            } else if complete {
                finish(sink)
            } else {
                pump(from: source, to: sink)
            }
        }
    }

    /// One side said it is done: the other side hears so. A connection whose
    /// other side never finishes goes after a while all the same.
    private func finish(_ sink: NWConnection) {
        sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        directionsOpen -= 1
        if directionsOpen <= 0 {
            close()
        } else {
            queue.asyncAfter(deadline: .now() + 30) { [self] in close() }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        inbound.stateUpdateHandler = nil
        outbound.stateUpdateHandler = nil
        inbound.cancel()
        outbound.cancel()
    }
}

/// A plain HTTP request from the network: read up to the end of its head,
/// answered with a page pointing to HTTPS — or SimTool's certificate, or 403
/// for anything but a page — then closed.
struct PlainRequest {
    let socket: Int32
    var head: Data
    let authority: Data?
    let page: @Sendable (_ host: String?) -> String
    private static let limit = 16 * 1024

    init(socket: Int32, head: Data, authority: Data?, page: @escaping @Sendable (_ host: String?) -> String) {
        self.socket = socket
        self.head = head
        self.authority = authority
        self.page = page
    }

    func respond() {
        var head = head
        SocketIO.setReadTimeout(socket, seconds: 10)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil, head.count < Self.limit {
            let count = Darwin.read(socket, &buffer, buffer.count)
            if count <= 0 { Darwin.close(socket); return }
            head.append(contentsOf: buffer[0..<count])
        }
        _ = SocketIO.writeAll(socket, Self.response(to: head, authority: authority, page: page))
        Darwin.shutdown(socket, SHUT_WR)
        Darwin.close(socket)
    }

    static func response(to head: Data, authority: Data?, page: (_ host: String?) -> String) -> Data {
        let text = String(decoding: head.prefix(limit), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let method = requestLine.first.map(String.init) ?? ""
        let path = requestLine.count > 1 ? String(requestLine[1].split(separator: "?", maxSplits: 1).first ?? "/") : "/"
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        let reads = method == "GET" || method == "HEAD"
        let status: String, type: String, body: Data
        if reads, path == NetworkPages.authorityPath, let authority {
            // Safari on iOS offers a certificate of this type as a profile to install.
            (status, type, body) = ("200 OK", "application/x-x509-ca-cert", authority)
        } else if reads, !path.hasPrefix("/api/"), path != "/stream.avcc" {
            (status, type, body) = ("200 OK", "text/html; charset=utf-8", Data(page(host).utf8))
        } else {
            let reason = "SimTool answers the network over HTTPS only"
            (status, type, body) = ("403 Forbidden", "application/json", (try? JSONSerialization.data(withJSONObject: ["error": reason])) ?? Data())
        }
        var bytes = Data("""
        HTTP/1.1 \(status)\r
        Content-Type: \(type)\r
        Content-Length: \(body.count)\r
        Content-Security-Policy: \(NetworkPages.contentSecurityPolicy)\r
        X-Content-Type-Options: nosniff\r
        X-Frame-Options: DENY\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """.utf8)
        if method != "HEAD" { bytes.append(body) }
        return bytes
    }
}
