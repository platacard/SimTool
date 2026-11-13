import Foundation
import XCTest
@testable import SimToolServer

// What the network door decides from a message's head alone: which requests
// reach the server, and where an answer ends.
final class NetworkDoorFrontTests: XCTestCase {
    private func head(_ text: String) -> HTTPMessageHead {
        HTTPMessageHead.parse(Data((text + "\r\n\r\n").utf8))!
    }

    func testAHeadReads() {
        let request = head("GET /api/v1/status HTTP/1.1\r\nHost: mac:3270\r\nConnection: keep-alive, Upgrade")
        XCTAssertEqual(request.startLine, ["GET", "/api/v1/status", "HTTP/1.1"])
        XCTAssertEqual(request.values("host"), ["mac:3270"])
        XCTAssertEqual(request.tokens("Connection"), ["keep-alive", "upgrade"])
        XCTAssertNil(HTTPMessageHead.parse(Data("\r\n\r\n".utf8)))
        XCTAssertNil(HTTPMessageHead.parse(Data("GET / HTTP/1.1\r\nno colon here\r\n\r\n".utf8)))
    }

    func testWhatReachesTheServer() {
        let limit: Int64 = 1000
        XCTAssertEqual(DoorRequestPlan.plan(head("GET / HTTP/1.1\r\nHost: m"), bodyLimit: limit), .forward(bodyLength: 0, closeAfter: false))
        XCTAssertEqual(DoorRequestPlan.plan(head("POST /x HTTP/1.1\r\nContent-Length: 12"), bodyLimit: limit), .forward(bodyLength: 12, closeAfter: false))
        XCTAssertEqual(DoorRequestPlan.plan(head("GET / HTTP/1.1\r\nConnection: close"), bodyLimit: limit), .forward(bodyLength: 0, closeAfter: true))
        XCTAssertEqual(DoorRequestPlan.plan(head("GET / HTTP/1.0"), bodyLimit: limit), .forward(bodyLength: 0, closeAfter: true))
        XCTAssertEqual(DoorRequestPlan.plan(head("GET /api/v1/input/stream HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: websocket"), bodyLimit: limit), .upgrade)

        for (text, status) in [
            ("POST /x HTTP/1.1\r\nContent-Length: 9223372036854775807", 413),
            ("POST /x HTTP/1.1\r\nContent-Length: 1001", 413),
            ("POST /x HTTP/1.1\r\nContent-Length: 99999999999999999999999", 400),
            ("POST /x HTTP/1.1\r\nContent-Length: -1", 400),
            ("POST /x HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3", 400),
            ("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked", 411),
            ("GET /", 400),
            ("GET / SPDY/3", 400),
        ] {
            guard case let .refuse(code, _, _) = DoorRequestPlan.plan(head(text), bodyLimit: limit) else { return XCTFail(text) }
            XCTAssertEqual(code, status, text)
        }
    }

    func testTheServerIsAskedToCloseOnceItAnswered() {
        let upstream = String(decoding: DoorRequestPlan.upstreamHead(head("GET / HTTP/1.1\r\nHost: m\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5")), as: UTF8.self)
        XCTAssertEqual(upstream, "GET / HTTP/1.1\r\nHost: m\r\nConnection: close\r\n\r\n")
    }

    func testWhereAnAnswerEnds() {
        XCTAssertEqual(DoorResponseFraming.framing(of: head("HTTP/1.1 200 OK\r\nContent-Length: 15"), requestMethod: "GET"), .length(15))
        XCTAssertEqual(DoorResponseFraming.framing(of: head("HTTP/1.1 200 OK\r\nContent-Length: 15"), requestMethod: "HEAD"), .length(0))
        XCTAssertEqual(DoorResponseFraming.framing(of: head("HTTP/1.1 204 No Content"), requestMethod: "POST"), .length(0))
        XCTAssertEqual(DoorResponseFraming.framing(of: head("HTTP/1.1 304 Not Modified"), requestMethod: "GET"), .length(0))
        // A stream, the event stream: no length, the end of the connection ends it.
        let stream = head("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream")
        XCTAssertEqual(DoorResponseFraming.framing(of: stream, requestMethod: "GET"), .untilClose)
        XCTAssertEqual(String(decoding: DoorResponseFraming.untilClose.clientHead(stream), as: UTF8.self),
                       "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(String(decoding: DoorResponseFraming.length(2).clientHead(head("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close")), as: UTF8.self),
                       "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n")
    }
}
