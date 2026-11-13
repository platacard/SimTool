import Foundation
import Swifter
import XCTest
@testable import SimToolServer

// What the policy decides from the headers alone — the browser names the page
// behind every request (Origin, Sec-Fetch-Site) and the host it believes it
// is talking to; a client that is not a browser names neither page.
final class SameOriginPolicyTests: XCTestCase {
    private let policy = SameOriginPolicy(serverHost: "127.0.0.1")

    func testClientsThatAreNotBrowsersGoThrough() {
        // The CLI, curl, the app-side loggers' URLSession: no Origin, no Sec-Fetch-*.
        XCTAssertNil(rejection(headers: ["host": "127.0.0.1:3200"]))
        XCTAssertNil(rejection(headers: [:]), "HTTP/1.0 without a Host")
    }

    func testTheViewerItselfGoesThrough() {
        XCTAssertNil(rejection(headers: ["host": "127.0.0.1:3200", "origin": "http://127.0.0.1:3200", "sec-fetch-site": "same-origin", "sec-fetch-mode": "cors"]))
        XCTAssertNil(rejection(headers: ["host": "localhost:3200", "origin": "http://localhost:3200"]))
        XCTAssertNil(rejection(headers: ["host": "[::1]:3200", "origin": "http://[::1]:3200"]))
        XCTAssertNil(rejection(headers: ["host": "127.0.0.1:3200", "sec-fetch-site": "none", "sec-fetch-mode": "navigate"]), "typed into the address bar")
    }

    func testAnotherOriginIsRefused() throws {
        for origin in ["https://evil.example", "http://127.0.0.1:5173", "http://localhost:3200", "https://127.0.0.1:3200", "null", "chrome-extension://abc"] {
            let reason = try XCTUnwrap(rejection(headers: ["host": "127.0.0.1:3200", "origin": origin]), origin)
            XCTAssertTrue(reason.contains("Origin \(origin)"), reason)
        }
        XCTAssertNotNil(rejection(headers: ["origin": "http://127.0.0.1:3200"]), "an Origin without a Host cannot be matched")
    }

    // A page on rebind.example, whose name now resolves to 127.0.0.1, is
    // same-origin with itself; its Host says which name it used.
    func testANameThatOnlyResolvesHereIsRefused() throws {
        for host in ["rebind.example:3200", "7f000001.rebind.network:3200", "127.0.0.1.nip.io:3200", "evil.example"] {
            let reason = try XCTUnwrap(rejection(headers: ["host": host, "origin": "http://\(host)"]), host)
            XCTAssertTrue(reason.hasPrefix("Host \(host)"), reason)
        }
        XCTAssertNotNil(rejection(headers: ["host": "127.0.0.1:3200 'unsafe-inline'"]), "nothing but a host and port")
        XCTAssertNotNil(rejection(headers: ["host": ":3200"]))
    }

    func testLoopbackNamesAddressesAndTheConfiguredHostAreThisServer() {
        for host in ["127.0.0.1:3200", "localhost:3200", "LocalHost", "[::1]:3200", "0.0.0.0:3200", "192.168.1.20:3200"] {
            XCTAssertTrue(policy.isAllowedHost(host), host)
        }
        // Names that only look local: resolved through DNS, they point wherever the resolver says.
        for host in ["app.localhost:3200", "localhost.:3200", "localhost.evil.example:3200"] {
            XCTAssertFalse(policy.isAllowedHost(host), host)
        }
        XCTAssertTrue(SameOriginPolicy(serverHost: "my-mac.local").isAllowedHost("my-mac.local:3200"))
        XCTAssertFalse(policy.isAllowedHost("my-mac.local:3200"))
    }

    // An <img>, <script> or <video> on another page sends no Origin.
    func testLoadsFromAnotherSiteAreRefused() {
        XCTAssertNotNil(rejection(headers: ["host": "127.0.0.1:3200", "sec-fetch-site": "cross-site", "sec-fetch-mode": "no-cors", "sec-fetch-dest": "image"]))
        // localhost:5173 and 127.0.0.1:3200 are different origins of one site.
        XCTAssertNotNil(rejection(headers: ["host": "127.0.0.1:3200", "sec-fetch-site": "same-site", "sec-fetch-mode": "no-cors", "sec-fetch-dest": "script"]))
        // A form posted from elsewhere is a navigation, but it carries its Origin.
        XCTAssertNotNil(rejection(method: "POST", path: "/api/v1/input", headers: ["host": "127.0.0.1:3200", "origin": "https://evil.example", "sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document"]))
    }

    // A link elsewhere may open the viewer in a tab — and nothing else: not
    // the viewer in a frame (whose clicks the page above would steer), not an
    // API route in a window (`GET /api/v1/mocks?since=` records an ack).
    func testALinkFromAnotherSiteOpensOnlyTheViewerInATab() {
        let link = ["host": "127.0.0.1:3200", "sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document"]
        XCTAssertNil(rejection(path: "/", headers: link))
        XCTAssertNotNil(rejection(path: "/", headers: link.merging(["sec-fetch-dest": "iframe"]) { $1 }))
        XCTAssertNotNil(rejection(path: "/", headers: link.merging(["sec-fetch-dest": "object"]) { $1 }))
        XCTAssertNotNil(rejection(path: "/api/v1/mocks", headers: link))
        XCTAssertNotNil(rejection(path: "/api/v1/screenshot", headers: link.merging(["sec-fetch-site": "same-site"]) { $1 }))
        XCTAssertNil(rejection(path: "/api/v1/mocks", headers: link.merging(["sec-fetch-site": "none"]) { $1 }), "typed or pasted into the address bar")
    }

    func testNoResponseLeavesWithACORSHeader() {
        let route = HttpResponse.raw(200, "OK", [
            "Content-Type": "text/event-stream",
            "Access-Control-Allow-Origin": "*",
            "access-control-allow-headers": "Content-Type",
        ], nil)
        let headers = policy.secured(route, host: "127.0.0.1:3200").headers()
        XCTAssertNil(headers.first { $0.key.lowercased().hasPrefix("access-control-") }, "\(headers)")
        XCTAssertEqual(headers["Content-Type"], "text/event-stream")
        XCTAssertEqual(headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(headers["Cross-Origin-Resource-Policy"], "same-origin")
        XCTAssertNil(headers["Content-Security-Policy"], "only pages carry a CSP")
    }

    func testAPageCarriesTheContentSecurityPolicyAndItsBody() throws {
        let secured = policy.secured(.ok(.html("<p>hi</p>")), host: "127.0.0.1:3200")
        let headers = secured.headers()
        let csp = try XCTUnwrap(headers["Content-Security-Policy"])
        for directive in ["default-src 'none'", "script-src 'self'", "style-src 'self'", "connect-src 'self' ws://127.0.0.1:3200", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'"] {
            XCTAssertTrue(csp.contains(directive), "\(directive) missing from \(csp)")
        }
        XCTAssertFalse(csp.contains("unsafe-eval"))
        XCTAssertEqual(headers["X-Frame-Options"], "DENY", "browsers without frame-ancestors")
        XCTAssertFalse(policy.contentSecurityPolicy(host: "[::1]:3200").contains("ws://["), "an IPv6 host is no CSP source")
        XCTAssertFalse(csp.contains("script-src 'self' 'unsafe-inline'"))
        XCTAssertEqual(headers["Content-Type"], "text/html")
        XCTAssertEqual(headers["Content-Length"], "9")
        XCTAssertEqual(try body(of: secured), "<p>hi</p>")
    }

    func testTheWebSocketHandshakeIsLeftToSwifter() {
        guard case .switchProtocols = policy.secured(.switchProtocols(["Upgrade": "websocket"], { _ in }), host: nil) else {
            return XCTFail("the upgrade must stay an upgrade, or the socket is never handed over")
        }
    }

    func testARefusalSaysWhy() throws {
        let refusal = policy.forbidden("Origin https://evil.example is not this server's viewer")
        XCTAssertEqual(refusal.statusCode, 403)
        XCTAssertEqual(refusal.headers()["Content-Type"], "application/json")
        XCTAssertTrue(try body(of: refusal).contains("evil.example"))
    }

    private func rejection(method: String = "GET", path: String = "/config", headers: [String: String]) -> String? {
        policy.rejection(method: method, path: path, headers: headers)
    }

    private func body(of response: HttpResponse) throws -> String {
        guard case let .raw(_, _, _, writer) = response, let writer else { return "" }
        let sink = Sink()
        try writer(sink)
        return String(decoding: sink.data, as: UTF8.self)
    }

    private final class Sink: HttpResponseBodyWriter {
        var data = Data()
        func write(_ file: String.File) throws {}
        func write(_ data: [UInt8]) throws { self.data.append(contentsOf: data) }
        func write(_ data: ArraySlice<UInt8>) throws { self.data.append(contentsOf: data) }
        func write(_ data: NSData) throws { self.data.append(data as Data) }
        func write(_ data: Data) throws { self.data.append(data) }
    }
}

// `serve --allow-origin`: a site that hands out the simulator may frame the
// viewer, read the status and start the simulator — and nothing else.
final class AllowedOriginPolicyTests: XCTestCase {
    private let site = "https://site.example"
    private lazy var policy = SameOriginPolicy(serverHost: "127.0.0.1", networkNames: ["mac.local"], allowedOrigins: [site])
    private let host = "10.0.0.7:3270"

    func testAnAllowedSiteMayFrameTheViewerAndNoOtherMay() {
        let framed = ["host": host, "sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "iframe"]
        XCTAssertNil(policy.rejection(method: "GET", path: "/", headers: framed, door: .network))
        XCTAssertNotNil(SameOriginPolicy(serverHost: "127.0.0.1").rejection(method: "GET", path: "/", headers: framed, door: .network), "no allowed origin: no frame")
        XCTAssertNotNil(policy.rejection(method: "GET", path: "/api/v1/status", headers: framed, door: .network), "only the page itself in a frame")

        let csp = policy.contentSecurityPolicy(host: host, door: .network)
        XCTAssertTrue(csp.contains("frame-ancestors https://site.example"), csp)
        XCTAssertFalse(csp.contains("frame-ancestors 'none'"), csp)
        XCTAssertTrue(SameOriginPolicy(serverHost: "127.0.0.1").contentSecurityPolicy(host: host).contains("frame-ancestors 'none'"))
    }

    func testAnAllowedSiteReadsTheStatusAndStartsTheSimulatorOnly() throws {
        let page = ["host": host, "origin": site, "sec-fetch-site": "cross-site", "sec-fetch-mode": "cors", "sec-fetch-dest": "empty"]
        for (method, path) in [("GET", "/api/v1/status"), ("POST", "/api/v1/device/wake")] {
            XCTAssertNil(policy.rejection(method: method, path: path, headers: page, door: .network), path)
            XCTAssertEqual(policy.crossOrigin(method: method, path: path, headers: page), site, path)
        }
        for (method, path) in [("GET", "/api/v1/activity"), ("POST", "/api/v1/input"), ("GET", "/config"), ("POST", "/api/v1/status"), ("GET", "/api/v1/device/wake")] {
            XCTAssertNotNil(policy.rejection(method: method, path: path, headers: page, door: .network), "\(method) \(path)")
            XCTAssertNil(policy.crossOrigin(method: method, path: path, headers: page), "\(method) \(path)")
        }
        var other = page
        other["origin"] = "https://evil.example"
        XCTAssertNotNil(policy.rejection(method: "GET", path: "/api/v1/status", headers: other, door: .network))
        XCTAssertNil(policy.crossOrigin(method: "GET", path: "/api/v1/status", headers: other))
    }

    func testTheAnswerNamesTheSiteAndCanBeFramed() {
        guard case let .raw(_, _, headers, _) = policy.secured(.ok(.text("{}")), host: host, door: .network, crossOrigin: site) else { return XCTFail("not raw") }
        XCTAssertEqual(headers?["Access-Control-Allow-Origin"], site)
        XCTAssertEqual(headers?["Vary"], "Origin")
        XCTAssertNil(headers?["X-Frame-Options"], "frame-ancestors says who may frame it")
        guard case let .raw(_, _, plain, _) = SameOriginPolicy(serverHost: "127.0.0.1").secured(.ok(.text("{}")), host: host) else { return XCTFail("not raw") }
        XCTAssertEqual(plain?["X-Frame-Options"], "DENY")
        guard case let .raw(_, _, anyPage, _) = policy.secured(.ok(.text("{}")), host: host, door: .network) else { return XCTFail("not raw") }
        XCTAssertEqual(anyPage?["Vary"], "Origin", "with allowed origins every answer may differ by the page asking")
        XCTAssertNil(plain?["Access-Control-Allow-Origin"])
    }

    func testOriginsAreWrittenAsBrowsersWriteThem() {
        XCTAssertEqual(SameOriginPolicy.normalizedOrigin("https://Site.Example/"), "https://site.example")
        XCTAssertEqual(SameOriginPolicy.normalizedOrigin("https://site.example:443"), "https://site.example")
        XCTAssertEqual(SameOriginPolicy.normalizedOrigin("http://localhost:3100"), "http://localhost:3100")
        for bad in ["site.example", "https://site.example/page", "ftp://site.example", "https://site.example/?a=1", "https://user@site.example", "", "https://a;b.example", "https://a b.example"] {
            XCTAssertNil(SameOriginPolicy.normalizedOrigin(bad), bad)
        }
    }
}

// From the network the server drives the simulator, not the Mac it runs on.
final class MacOnlyRouteTests: XCTestCase {
    func testRoutesThatActOnTheMacAreRefusedFromTheNetworkOnly() {
        let policy = SameOriginPolicy(serverHost: "127.0.0.1", networkNames: ["mac.local"])
        let host = ["host": "10.0.0.7:3270"]
        let json = host.merging(["content-type": "application/json"]) { $1 }
        for (method, path, headers) in [
            ("POST", "/api/v1/processes/123/kill", host), ("POST", "/api/v1/processes/kill-orphans", host), ("DELETE", "/api/v1/processes", host),
            ("POST", "/api/v1/camera/webcam", host), ("POST", "/api/v1/app/reveal", host), ("POST", "/api/v1/app/install", json),
        ] {
            let reason = policy.rejection(method: method, path: path, headers: headers, door: .network)
            XCTAssertTrue(reason?.contains("open on the Mac itself") == true, "\(method) \(path): \(reason ?? "let through")")
            var local = headers
            local["host"] = "127.0.0.1:3270"
            XCTAssertNil(policy.rejection(method: method, path: path, headers: local, door: .local), "\(method) \(path) on this Mac")
        }
        // The process list and what the Mac's memory and CPU go to: read, not acted on.
        XCTAssertNil(policy.rejection(method: "GET", path: "/api/v1/processes", headers: host, door: .network))
        // A build uploaded from the viewer, the simulator's camera, the device: open.
        XCTAssertNil(policy.rejection(method: "POST", path: "/api/v1/app/install", headers: host.merging(["content-type": "application/octet-stream"]) { $1 }, door: .network))
        XCTAssertNil(policy.rejection(method: "POST", path: "/api/v1/camera", headers: host, door: .network))
        XCTAssertNil(policy.rejection(method: "POST", path: "/api/v1/device", headers: host, door: .network))
    }
}
