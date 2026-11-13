import Darwin
import Foundation
import Network
import Security
import SimToolCore
import Swifter
import XCTest
@testable import SimToolServer

// A server opened to the network: the HTTPS door's same-origin rules and
// the page plain HTTP from the network gets; and the live server — this Mac
// keeps plain HTTP on loopback, the network gets HTTPS and a page pointing there.
final class NetworkDoorPolicyTests: XCTestCase {
    // The network door is HTTPS: its pages' Origin is https, its socket wss,
    // and the Mac's own names are its hosts — a name that merely resolves
    // here still is not.
    func testThePolicyBehindTheNetworkDoor() throws {
        let policy = SameOriginPolicy(serverHost: "127.0.0.1", networkNames: ["my-mac.local"])
        let viewer = ["host": "my-mac.local:3200", "origin": "https://my-mac.local:3200", "sec-fetch-site": "same-origin"]
        XCTAssertNil(policy.rejection(method: "GET", path: "/config", headers: viewer, door: .network))
        XCTAssertNil(policy.rejection(method: "GET", path: "/config", headers: ["host": "192.168.0.10:3200", "origin": "https://192.168.0.10:3200"], door: .network))
        XCTAssertNotNil(policy.rejection(method: "GET", path: "/config", headers: ["host": "my-mac.local:3200", "origin": "http://my-mac.local:3200"], door: .network), "an http page is not the network viewer")
        XCTAssertNotNil(policy.rejection(method: "POST", path: "/api/v1/input", headers: ["host": "my-mac.local:3200", "origin": "https://evil.example"], door: .network), "another site cannot drive it over HTTPS either")
        let rebound = try XCTUnwrap(policy.rejection(method: "GET", path: "/config", headers: ["host": "rebind.example:3200", "origin": "https://rebind.example:3200"], door: .network))
        XCTAssertTrue(rebound.contains("https://my-mac.local"), rebound)
        XCTAssertTrue(policy.contentSecurityPolicy(host: "my-mac.local:3200", door: .network).contains("connect-src 'self' wss://my-mac.local:3200"))
        XCTAssertTrue(policy.contentSecurityPolicy(host: "127.0.0.1:3200").contains("connect-src 'self' ws://127.0.0.1:3200"))
        XCTAssertFalse(SameOriginPolicy(serverHost: "127.0.0.1").isAllowedHost("my-mac.local:3200"), "a server not on the network knows no such name")
    }

    func testAWildcardCertificateCoversOneLabel() {
        let policy = SameOriginPolicy(serverHost: "127.0.0.1", networkNames: ["*.corp.example"])
        XCTAssertTrue(policy.isAllowedHost("mac.corp.example:3200"))
        XCTAssertFalse(policy.isAllowedHost("a.mac.corp.example:3200"))
        XCTAssertFalse(policy.isAllowedHost("corp.example:3200"))
        XCTAssertFalse(policy.isAllowedHost("mac.corp.example.evil:3200"))
    }

    func testThePlainPageFromTheNetworkPointsToHTTPS() {
        let head = Data("GET / HTTP/1.1\r\nHost: my-mac.local:3200\r\n\r\n".utf8)
        let page = String(decoding: PlainRequest.response(to: head, authority: Data([1, 2, 3])) { host in "page for \(host ?? "-")" }, as: UTF8.self)
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 200 OK\r\n"), page)
        XCTAssertTrue(page.hasSuffix("page for my-mac.local:3200"), page)
        let certificate = PlainRequest.response(to: Data("GET /simtool-ca.cer HTTP/1.1\r\n\r\n".utf8), authority: Data([1, 2, 3])) { _ in "" }
        XCTAssertTrue(String(decoding: certificate, as: UTF8.self).contains("Content-Type: application/x-x509-ca-cert"))
        XCTAssertEqual(Array(certificate.suffix(3)), [1, 2, 3])
        for request in ["GET /config HTTP/1.1", "GET /api/v1/network/events HTTP/1.1", "POST / HTTP/1.1", "GET /stream.avcc HTTP/1.1"] {
            let refused = String(decoding: PlainRequest.response(to: Data((request + "\r\n\r\n").utf8), authority: nil) { _ in "page" }, as: UTF8.self)
            XCTAssertTrue(refused.hasPrefix(request.hasPrefix("GET /config") ? "HTTP/1.1 200" : "HTTP/1.1 403"), "\(request): \(refused.prefix(40))")
        }
        let landing = NetworkPages.landing(secureURL: "https://my-mac.local:3200/", offersAuthority: true)
        XCTAssertTrue(landing.contains("href=\"https://my-mac.local:3200/\""))
        XCTAssertTrue(landing.contains("Certificate Trust Settings"))
        XCTAssertTrue(landing.contains("SHA-256 fingerprint"))
        XCTAssertFalse(NetworkPages.landing(secureURL: "https://ci.example/", offersAuthority: false).contains(NetworkPages.authorityPath), "no certificate to offer for one someone else issued")
    }
}

final class NetworkDoorRouteTests: XCTestCase {
    private var home: URL!
    private var exposure: NetworkExposure!
    private var anchor: SecCertificate!

    override func setUp() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("needs macOS 15") }
        home = FileManager.default.temporaryDirectory.appendingPathComponent("simtool-door-\(UUID().uuidString)", isDirectory: true)
        let authority = try await LocalCertificateAuthority.loadOrCreate(in: home, label: "test")
        let identity = try await authority.issue(names: ["test-mac.local", "localhost"], addresses: ["127.0.0.1"] + [nonLoopbackIPv4()].compactMap { $0 })
        anchor = SecCertificateCreateWithData(nil, try authority.certificateDER() as CFData)
        exposure = NetworkExposure(identity: identity, localHostName: "test-mac.local")
    }

    override func tearDown() {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func startServer(port: UInt16? = nil) throws -> (StreamServer, UInt16) {
        let port = try port ?? freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false, network: exposure))
        try server.start()
        return (server, port)
    }

    // This Mac — the CLI, the loggers in the simulator, its own viewer — keeps
    // plain HTTP on loopback.
    func testThisMacKeepsPlainHTTP() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let config = try rawHTTP(port: port, "/config")
        XCTAssertEqual(config.status, 200)
        let payload = try JSONDecoder().decode(ServerConfigPayload.self, from: Data(config.body.utf8))
        let network = try XCTUnwrap(payload.network)
        XCTAssertEqual(network.certificate, NetworkPages.authorityPath)
        XCTAssertEqual(network.certificateFingerprint?.split(separator: " ").count, 32)
        XCTAssertFalse(network.urls.contains { $0.contains("127.0.0.1") || $0.contains("localhost") }, "no other device reaches loopback: \(network.urls)")
        XCTAssertEqual(network.urls.first, "https://test-mac.local:\(port)/", "the Bonjour name first: it outlives a new address")
        let viewer = try rawHTTP(port: port, "/", headers: ["Origin": "", "Sec-Fetch-Dest": "document"])
        XCTAssertEqual(viewer.status, 200)
        XCTAssertTrue(viewer.headers["content-security-policy"]?.contains("ws://127.0.0.1:\(port)") == true)
        XCTAssertEqual(try rawHTTP(port: port, NetworkPages.authorityPath).status, 200)
        XCTAssertEqual(try rawHTTP(port: port, "/api/v1/network/qr.png").headers["content-type"], "image/png")
    }

    // HTTPS on the same port, from any address: the viewer, its API and its
    // socket as an https origin.
    func testTheNetworkGetsHTTPS() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let client = TLSClient(anchor: anchor)
        let base = "https://localhost:\(port)"
        let config = try await client.get(base + "/config")
        XCTAssertEqual(config.status, 200)
        XCTAssertNotNil(try JSONDecoder().decode(ServerConfigPayload.self, from: Data(config.body.utf8)).network)
        let viewer = try await client.get(base + "/", headers: ["Accept": "text/html"])
        XCTAssertEqual(viewer.status, 200)
        XCTAssertTrue(viewer.headers["content-security-policy"]?.contains("wss://localhost:\(port)") == true, "\(viewer.headers)")
        let elsewhere = try await client.get(base + "/config", headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(elsewhere.status, 403, "another site's page is refused on HTTPS too")
        let certificate = try await client.get(base + NetworkPages.authorityPath)
        XCTAssertEqual(certificate.status, 200)
    }

    // Plain HTTP from another device gets a page pointing to HTTPS — never
    // the viewer, the API or the stream.
    func testPlainHTTPFromTheNetworkIsPointedToHTTPS() throws {
        guard let lan = nonLoopbackIPv4() else { throw XCTSkip("this Mac has no network address besides loopback") }
        let (server, port) = try startServer()
        defer { server.stop() }
        let page = try exchange(lan, port, "GET / HTTP/1.1\r\nHost: \(lan):\(port)\r\n\r\n")
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 200"), String(page.prefix(80)))
        XCTAssertTrue(page.contains("href=\"https://\(lan):\(port)/\""), "the HTTPS address the device used")
        XCTAssertTrue(try exchange(lan, port, "GET /config HTTP/1.1\r\nHost: \(lan):\(port)\r\n\r\n").contains("SimTool opens over HTTPS"), "a page, not the config")
        XCTAssertTrue(try exchange(lan, port, "GET /api/v1/status HTTP/1.1\r\nHost: \(lan):\(port)\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(try exchange(lan, port, "GET /simtool-ca.cer HTTP/1.1\r\nHost: \(lan):\(port)\r\n\r\n").contains("application/x-x509-ca-cert"))
    }

    // A restart right after a stop finds connections of the old server still
    // lingering on the port (TIME_WAIT): the port opens all the same.
    func testTheServerOpensAgainRightAfterAStop() throws {
        let (first, port) = try startServer()
        XCTAssertEqual(try rawHTTP(port: port, "/health").status, 200)
        first.stop()
        let (second, _) = try startServer(port: port)
        defer { second.stop() }
        XCTAssertEqual(try rawHTTP(port: port, "/health").status, 200)
    }

    // A browser keeps its connection across requests: the server closes its
    // own after each answer, the door does not — or a page whose certificate
    // the browser was told to accept fails part of its files.
    func testABrowserKeepsItsConnectionAcrossRequests() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let client = TLSClient(anchor: anchor)
        var reused: [Bool] = []
        for path in ["/health", "/config", "/health", "/api/v1/status"] {
            let answer = try await client.get("https://localhost:\(port)" + path)
            XCTAssertEqual(answer.status, 200, path)
            reused.append(answer.reused)
        }
        XCTAssertEqual(reused, [false, true, true, true], "one connection for every request")
    }

    // From the network the process list is read — what runs and what the
    // Mac's memory and CPU go to — and nothing in it is stopped.
    func testTheProcessListIsReadButNothingIsStoppedFromTheNetwork() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let list = try await TLSClient(anchor: anchor).get("https://localhost:\(port)/api/v1/processes")
        XCTAssertEqual(list.status, 200, list.body)
        let machine = try XCTUnwrap(try JSON.decoder.decode(SimToolProcessList.self, from: Data(list.body.utf8)).machine)
        XCTAssertEqual(machine.memory, ProcessInfo.processInfo.physicalMemory)
        for path in ["/api/v1/processes/999999/kill", "/api/v1/processes/kill-orphans"] {
            let refused = try tlsExchange(port: port, "POST \(path) HTTP/1.1\r\nHost: localhost:\(port)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            XCTAssertTrue(refused.hasPrefix("HTTP/1.1 403"), "\(path): \(refused.prefix(120))")
            XCTAssertTrue(refused.contains("Stopping SimTool's processes is open on the Mac itself"), String(refused.prefix(400)))
        }
    }

    // A body the server could not hold is refused before it gets there, and
    // the server answers on: one request must not take it down.
    func testAnImpossibleBodyIsRefusedAndTheServerLives() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let huge = try tlsExchange(port: port, "POST /api/v1/input HTTP/1.1\r\nHost: localhost:\(port)\r\nContent-Length: 9223372036854775807\r\n\r\n")
        XCTAssertTrue(huge.hasPrefix("HTTP/1.1 413"), String(huge.prefix(120)))
        let chunked = try tlsExchange(port: port, "POST /api/v1/input HTTP/1.1\r\nHost: localhost:\(port)\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
        XCTAssertTrue(chunked.hasPrefix("HTTP/1.1 411"), String(chunked.prefix(120)))
        let twoLengths = try tlsExchange(port: port, "POST /api/v1/input HTTP/1.1\r\nHost: localhost:\(port)\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}")
        XCTAssertTrue(twoLengths.hasPrefix("HTTP/1.1 400"), String(twoLengths.prefix(120)))
        let health = try await TLSClient(anchor: anchor).get("https://localhost:\(port)/health")
        XCTAssertEqual(health.status, 200)
    }

    // A pipelined second request is answered on the same connection, and a
    // body is passed on whole.
    func testRequestsOnOneConnectionAreAnsweredInTurn() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let body = #"{"action":"teleport"}"#
        let answer = try tlsExchange(port: port, "POST /api/v1/device HTTP/1.1\r\nHost: localhost:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)GET /health HTTP/1.1\r\nHost: localhost:\(port)\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 400"), String(answer.prefix(120)))
        XCTAssertTrue(answer.contains("Unknown device action teleport"), "the body reached the server whole")
        XCTAssertTrue(answer.contains(#"{"status":"ok"}"#), "the second request was answered: \(answer)")
    }

    // The live-input socket opens through the door and answers a ping.
    func testTheInputSocketOpensThroughTheDoor() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let client = TLSClient(anchor: anchor)
        let pong = try await client.socketExchange("wss://localhost:\(port)/api/v1/input/stream", origin: "https://localhost:\(port)", send: #"{"t":"ping","id":7}"#)
        XCTAssertTrue(pong.contains(#""t":"pong""#) && pong.contains(#""id":7"#), pong)
    }

    /// One exchange over TLS with the door, as raw bytes: what a test needs
    /// to send that URLSession would not.
    private func tlsExchange(port: UInt16, _ request: String) throws -> String {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, DispatchQueue.global())
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls))
        let done = DispatchSemaphore(value: 0)
        let box = ExchangeBox()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data { box.append(data) }
                if complete || error != nil { done.signal() } else { receive() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                receive()
            case .failed, .cancelled:
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "test.tls-exchange"))
        _ = done.wait(timeout: .now() + 10)
        connection.cancel()
        return box.text
    }

    private func exchange(_ ip: String, _ port: UInt16, _ request: String) throws -> String {
        let descriptor = try connectTCP(ip, port: port, timeout: 3).get()
        defer { close(descriptor) }
        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
        var received = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count <= 0 { break }
            received += buffer[0..<count]
        }
        return String(decoding: received, as: UTF8.self)
    }
}

private final class ExchangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
}

/// An HTTPS client that trusts SimTool's test authority alone and follows no
/// redirect, so a test sees each answer as it came.
private final class TLSClient: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let anchor: SecCertificate
    private lazy var session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }(), delegate: self, delegateQueue: nil)

    init(anchor: SecCertificate) {
        self.anchor = anchor
    }

    func get(_ url: String, headers: [String: String] = [:]) async throws -> (status: Int, headers: [String: String], body: String, reused: Bool) {
        var request = URLRequest(url: URL(string: url)!)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let metrics = MetricsCollector()
        let (data, response) = try await session.data(for: request, delegate: metrics)
        let http = response as! HTTPURLResponse
        var lowered: [String: String] = [:]
        for (name, value) in http.allHeaderFields { lowered["\(name)".lowercased()] = "\(value)" }
        return (http.statusCode, lowered, String(decoding: data, as: UTF8.self), metrics.reused)
    }

    /// Opens a WebSocket, sends one message and answers the first message back.
    func socketExchange(_ url: String, origin: String, send message: String) async throws -> String {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        try await task.send(.string(message))
        switch try await task.receive() {
        case let .string(text): return text
        case let .data(data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Whether a request went over a connection an earlier one opened.
private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var reused: Bool { lock.withLock { value } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { value = metrics.transactionMetrics.last?.isReusedConnection ?? false }
    }
}
