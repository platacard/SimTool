import Darwin
import Foundation
import Security
import SimToolCore
import Swifter
import XCTest
@testable import SimToolServer

// A server opened to the network: what its door lets through on its own
// (the key, the cookie, the pages), and the live server — this Mac keeps
// plain HTTP on loopback, the network gets HTTPS behind the key and a page
// pointing there.
final class NetworkGateTests: XCTestCase {
    private let gate = NetworkGate(key: "k7fm-2qpx-9td3", names: ["my-mac.local"], port: 3200, offersAuthority: true)
    private let page = ["sec-fetch-dest": "document", "sec-fetch-mode": "navigate"]

    func testNothingButTheKeyPageAndTheCertificateWithoutTheKey() {
        XCTAssertEqual(admission(path: "/config"), .refused(page: false, wrongKey: false))
        XCTAssertEqual(admission(path: "/", headers: page), .refused(page: true, wrongKey: false))
        XCTAssertEqual(admission(path: "/api/v1/input/stream", headers: ["upgrade": "websocket"]), .refused(page: false, wrongKey: false))
        XCTAssertEqual(admission(path: NetworkGate.authorityPath), .admitted, "a device fetches the certificate before it has anything else")
        XCTAssertEqual(admission(method: "POST", path: NetworkGate.authorityPath), .refused(page: false, wrongKey: false))
    }

    func testTheKeyInTheAddressIsKeptInACookieAndLeavesTheAddress() {
        XCTAssertEqual(admission(path: "/", query: [("key", "K7FM2QPX9TD3")], headers: page), .remember(location: "/"))
        XCTAssertEqual(admission(path: "/", query: [("view", "3d"), ("key", "k7fm-2qpx-9td3")], headers: page), .remember(location: "/?view=3d"))
        XCTAssertEqual(admission(path: "/", query: [("key", "nope")], headers: page), .refused(page: true, wrongKey: true))
        // Older browsers name no destination; they still ask for a page.
        XCTAssertEqual(admission(path: "/", query: [("key", "k7fm2qpx9td3")], headers: ["accept": "text/html,application/xhtml+xml"]), .remember(location: "/"))
        // A script's request does not get to set the cookie through the address.
        XCTAssertEqual(admission(path: "/config", query: [("key", "k7fm2qpx9td3")], headers: ["sec-fetch-dest": "empty"]), .refused(page: false, wrongKey: false))

        let remembered = gate.remembering(location: "/").headers()
        let cookie = remembered["Set-Cookie"] ?? ""
        for attribute in ["simtool-key-3200=k7fm2qpx9td3", "Secure", "HttpOnly", "SameSite=Lax", "Path=/"] {
            XCTAssertTrue(cookie.contains(attribute), "\(attribute) missing from \(cookie)")
        }
        XCTAssertEqual(remembered["Location"], "/")
    }

    // The key typed into the key page with spaces arrives as `+`; the page is
    // shown again on this server only, its other items as they came.
    func testTheKeyPageAndTheAddressLeadBackHere() {
        XCTAssertEqual(admission(path: "/", query: [("key", "k7fm+2qpx+9td3")], headers: page), .remember(location: "/"))
        XCTAssertEqual(NetworkGate.location(path: "/\\evil.example", query: []), "/", "a browser reads /\\x as //x, another host")
        XCTAssertEqual(NetworkGate.location(path: "//evil.example", query: []), "/")
        XCTAssertEqual(NetworkGate.location(path: "/", query: [("q", "a%20b"), ("flag", "")]), "/?q=a%20b&flag", "not encoded twice")
        XCTAssertEqual(NetworkGate.location(path: "/assets/x.js", query: []), "/assets/x.js")
    }

    func testAWildcardCertificateCoversOneLabel() {
        let policy = SameOriginPolicy(serverHost: "127.0.0.1", network: NetworkGate(key: "k", names: ["*.corp.example"], port: 3200, offersAuthority: false))
        XCTAssertTrue(policy.isAllowedHost("mac.corp.example:3200"))
        XCTAssertFalse(policy.isAllowedHost("a.mac.corp.example:3200"))
        XCTAssertFalse(policy.isAllowedHost("corp.example:3200"))
        XCTAssertFalse(policy.isAllowedHost("mac.corp.example.evil:3200"))
    }

    func testTheCookieOrABearerTokenAdmits() {
        XCTAssertEqual(admission(path: "/config", headers: ["cookie": "theme=dark; simtool-key-3200=k7fm2qpx9td3"]), .admitted)
        XCTAssertEqual(admission(path: "/config", headers: ["cookie": "simtool-key-3201=k7fm2qpx9td3"]), .refused(page: false, wrongKey: false), "another server's cookie")
        XCTAssertEqual(admission(path: "/", headers: page.merging(["cookie": "simtool-key-3200=renewed"]) { $1 }), .refused(page: true, wrongKey: true))
        XCTAssertEqual(admission(path: "/config", headers: ["authorization": "Bearer k7fm-2qpx-9td3"]), .admitted)
        XCTAssertEqual(admission(path: "/config", headers: ["authorization": "Bearer wrong"]), .refused(page: false, wrongKey: true))
        XCTAssertEqual(admission(path: "/config", headers: ["authorization": "Basic azdmbQ=="]), .refused(page: false, wrongKey: true))
    }

    func testARefusalSaysWhereTheKeyGoes() throws {
        let api = gate.refusal(page: false, wrongKey: false)
        XCTAssertEqual(api.statusCode, 401)
        XCTAssertEqual(api.headers()["WWW-Authenticate"], "Bearer realm=\"SimTool\"")
        let keyPage = gate.refusal(page: true, wrongKey: true)
        XCTAssertEqual(keyPage.statusCode, 401)
        let csp = try XCTUnwrap(keyPage.headers()["Content-Security-Policy"])
        XCTAssertTrue(csp.contains("form-action 'self'"), "the key page's form must post: \(csp)")
        XCTAssertFalse(csp.contains("script-src"), "and it runs no script: \(csp)")
        let html = NetworkPages.keyPage(wrongKey: true, offersAuthority: true)
        XCTAssertTrue(html.contains("name=\"key\""))
        XCTAssertTrue(html.contains("not this server's key"))
        XCTAssertTrue(html.contains(NetworkGate.authorityPath))
        XCTAssertFalse(NetworkPages.keyPage(wrongKey: false, offersAuthority: false).contains(NetworkGate.authorityPath))
    }

    // The network door is HTTPS: its pages' Origin is https, its socket wss,
    // and the Mac's own names are its hosts — a name that merely resolves
    // here still is not.
    func testThePolicyBehindTheNetworkDoor() throws {
        let policy = SameOriginPolicy(serverHost: "127.0.0.1", network: gate)
        let viewer = ["host": "my-mac.local:3200", "origin": "https://my-mac.local:3200", "sec-fetch-site": "same-origin"]
        XCTAssertNil(policy.rejection(method: "GET", path: "/config", headers: viewer, door: .network))
        XCTAssertNil(policy.rejection(method: "GET", path: "/config", headers: ["host": "192.168.1.27:3200", "origin": "https://192.168.1.27:3200"], door: .network))
        XCTAssertNotNil(policy.rejection(method: "GET", path: "/config", headers: ["host": "my-mac.local:3200", "origin": "http://my-mac.local:3200"], door: .network), "an http page is not the network viewer")
        let rebound = try XCTUnwrap(policy.rejection(method: "GET", path: "/config", headers: ["host": "rebind.example:3200", "origin": "https://rebind.example:3200"], door: .network))
        XCTAssertTrue(rebound.contains("https://my-mac.local"), rebound)
        XCTAssertTrue(policy.contentSecurityPolicy(host: "my-mac.local:3200", door: .network).contains("connect-src 'self' wss://my-mac.local:3200"))
        XCTAssertTrue(policy.contentSecurityPolicy(host: "127.0.0.1:3200").contains("connect-src 'self' ws://127.0.0.1:3200"))
        // A page that brings its own policy keeps it.
        let keyPage = policy.secured(gate.refusal(page: true, wrongKey: false), host: "my-mac.local:3200", door: .network)
        XCTAssertEqual(keyPage.headers()["Content-Security-Policy"], NetworkPages.contentSecurityPolicy)
        XCTAssertFalse(SameOriginPolicy(serverHost: "127.0.0.1").isAllowedHost("my-mac.local:3200"), "a server not on the network knows no such name")
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
    }

    private func admission(method: String = "GET", path: String, query: [(String, String)] = [], headers: [String: String] = [:]) -> NetworkGate.Admission {
        gate.admission(method: method, path: path, query: query, headers: headers)
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
        let identity = try await authority.issue(names: ["localhost"], addresses: ["127.0.0.1"] + [nonLoopbackIPv4()].compactMap { $0 })
        anchor = SecCertificateCreateWithData(nil, try authority.certificateDER() as CFData)
        exposure = NetworkExposure(identity: identity, accessKey: "k7fm-2qpx-9td3", localHostName: "test-mac.local")
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
    // plain HTTP on loopback and needs no key.
    func testThisMacKeepsPlainHTTPWithoutTheKey() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let config = try rawHTTP(port: port, "/config")
        XCTAssertEqual(config.status, 200)
        let payload = try JSONDecoder().decode(ServerConfigPayload.self, from: Data(config.body.utf8))
        let network = try XCTUnwrap(payload.network)
        XCTAssertEqual(network.key, "k7fm-2qpx-9td3")
        XCTAssertEqual(network.certificate, NetworkGate.authorityPath)
        XCTAssertTrue(network.keyURL.hasSuffix("?key=k7fm2qpx9td3"), network.keyURL)
        XCTAssertFalse(network.urls.contains { $0.contains("127.0.0.1") || $0.contains("localhost") }, "no other device reaches loopback: \(network.urls)")
        let viewer = try rawHTTP(port: port, "/", headers: ["Origin": "", "Sec-Fetch-Dest": "document"])
        XCTAssertEqual(viewer.status, 200)
        XCTAssertTrue(viewer.headers["content-security-policy"]?.contains("ws://127.0.0.1:\(port)") == true)
        XCTAssertEqual(try rawHTTP(port: port, NetworkGate.authorityPath).status, 200)
        XCTAssertEqual(try rawHTTP(port: port, "/api/v1/network/qr.png").headers["content-type"], "image/png")
    }

    // HTTPS on the same port, from any address: behind the key.
    func testTheNetworkGetsHTTPSBehindTheKey() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let client = TLSClient(anchor: anchor)
        let base = "https://localhost:\(port)"
        let refused = try await client.get(base + "/config")
        XCTAssertEqual(refused.status, 401)
        XCTAssertTrue(refused.body.contains("access key"), refused.body)
        let admitted = try await client.get(base + "/config", headers: ["Authorization": "Bearer k7fm2qpx9td3"])
        XCTAssertEqual(admitted.status, 200)
        XCTAssertNotNil(try JSONDecoder().decode(ServerConfigPayload.self, from: Data(admitted.body.utf8)).network)

        let remembered = try await client.get(base + "/?key=K7FM-2QPX-9TD3", headers: ["Accept": "text/html"])
        XCTAssertEqual(remembered.status, 303)
        XCTAssertEqual(remembered.headers["location"], "/")
        let cookie = try XCTUnwrap(remembered.headers["set-cookie"]?.components(separatedBy: ";").first)
        let viewer = try await client.get(base + "/", headers: ["Accept": "text/html", "Cookie": cookie])
        XCTAssertEqual(viewer.status, 200)
        XCTAssertTrue(viewer.headers["content-security-policy"]?.contains("wss://localhost:\(port)") == true, "\(viewer.headers)")
        let keyPage = try await client.get(base + "/", headers: ["Accept": "text/html"])
        XCTAssertEqual(keyPage.status, 401)
        XCTAssertTrue(keyPage.body.contains("Enter the access key"))
        let certificate = try await client.get(base + NetworkGate.authorityPath)
        XCTAssertEqual(certificate.status, 200, "the certificate needs no key")
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

    func get(_ url: String, headers: [String: String] = [:]) async throws -> (status: Int, headers: [String: String], body: String) {
        var request = URLRequest(url: URL(string: url)!)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        var lowered: [String: String] = [:]
        for (name, value) in http.allHeaderFields { lowered["\(name)".lowercased()] = "\(value)" }
        return (http.statusCode, lowered, String(decoding: data, as: UTF8.self))
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
