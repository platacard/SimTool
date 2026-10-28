import Foundation
import XCTest
@testable import SimToolNetworkLogger

/// The logger as an app embeds it: calls and streams of any protocol.
final class NetworkLoggerSDKTests: XCTestCase {
    // MARK: Any protocol

    func testAProtocolIsAnyNameAndRoundTripsAsItIs() throws {
        XCTAssertEqual(NetworkLoggerProtocol(" WebSocket "), .websocket)
        let event = NetworkLoggerEvent(networkProtocol: "mqtt", durationMilliseconds: 0, request: NetworkLoggerRequest())
        let decoded = try NetworkLoggerJSON.decoder.decode(NetworkLoggerEvent.self, from: NetworkLoggerJSON.data(event))
        XCTAssertEqual(decoded.networkProtocol.rawValue, "mqtt")
        XCTAssertTrue(try NetworkLoggerJSON.string(event).contains(#""protocol":"mqtt""#))
    }

    // What a logger before 1.0 sends still reads, with no stream and no new fields.
    func testAnEventFromBefore1Decodes() throws {
        let json = #"""
        {"id":"a","timestamp":"2026-01-01T00:00:00.000Z","protocol":"grpc","durationMilliseconds":5,
         "request":{"headers":{},"metadata":{},"path":"/Echo/Echo"},"response":{"headers":{},"metadata":{},"grpcStatusCode":"0"},
         "rawMetadata":{},"mocked":false}
        """#
        let event = try NetworkLoggerJSON.decoder.decode(NetworkLoggerEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.networkProtocol, .grpc)
        XCTAssertNil(event.stream)
        XCTAssertNil(event.response?.status)
        XCTAssertNil(event.request.bodyPreviewEncoding)
    }

    // MARK: Calls

    func testACallOfAnyProtocolIsReportedWithItsAnswer() async throws {
        let (logger, sink) = makeLogger()
        let call = logger.startCall(
            "graphql",
            method: "query Profile",
            url: URL(string: "https://api.example.test/graphql?access_token=abc&v=2")!,
            headers: ["Authorization": "Bearer abc", "X-Trace": "t1"],
            body: .text(#"{"query":"{ me { id } }"}"#)
        )
        let event = call.finish(status: "OK", metadata: ["cost": "3"], body: .text(#"{"data":{"me":{"id":1}}}"#))
        await logger.flush()

        XCTAssertEqual(event.id, call.id)
        XCTAssertEqual(event.networkProtocol.rawValue, "graphql")
        XCTAssertEqual(event.request.method, "query Profile")
        XCTAssertEqual(event.request.url, "https://api.example.test/graphql?access_token=<redacted>&v=2")
        XCTAssertEqual(event.request.host, "api.example.test")
        XCTAssertEqual(event.request.path, "/graphql")
        XCTAssertEqual(event.request.headers, ["Authorization": "<redacted>", "X-Trace": "t1"])
        XCTAssertEqual(event.request.bodyPreview, #"{"query":"{ me { id } }"}"#)
        XCTAssertEqual(event.request.bodyByteCount, 25)
        XCTAssertEqual(event.response?.status, "OK")
        XCTAssertEqual(event.response?.metadata, ["cost": "3"])
        XCTAssertNil(event.stream)
        XCTAssertGreaterThanOrEqual(event.durationMilliseconds, 0)
        let delivered = await sink.snapshot()
        XCTAssertEqual(delivered, [event])
    }

    func testACallThatFailedBeforeAnAnswerHasNoResponse() async {
        let (logger, _) = makeLogger()
        let event = logger.startCall("tcp", target: "10.0.0.1:9000")
            .finish(error: NetworkLoggerError(code: 61, message: "Connection refused"))

        XCTAssertNil(event.response)
        XCTAssertEqual(event.error, NetworkLoggerError(code: 61, message: "Connection refused"))
        XCTAssertEqual(event.request.path, "10.0.0.1:9000")
        XCTAssertEqual(event.displayRequest, "10.0.0.1:9000")
    }

    func testAnHTTPCallFromTheAppsOwnLayerReadsLikeACapturedOne() {
        let (logger, _) = makeLogger()
        var request = URLRequest(url: URL(string: "https://api.example.test/v1/items")!)
        request.httpMethod = "POST"
        request.setValue("secret", forHTTPHeaderField: "X-Api-Key")
        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"])

        let event = logger.startHTTPCall(request, body: Data("{}".utf8))
            .finish(response: response, body: Data(#"{"id":7}"#.utf8), error: nil)

        XCTAssertEqual(event.networkProtocol, .http)
        XCTAssertEqual(event.request.method, "POST")
        XCTAssertEqual(event.request.headers["X-Api-Key"], "<redacted>")
        XCTAssertEqual(event.request.bodyPreview, "{}")
        XCTAssertEqual(event.response?.statusCode, 201)
        XCTAssertEqual(event.response?.bodyPreview, #"{"id":7}"#)
        XCTAssertEqual(event.displayStatus, "201")
    }

    // MARK: Streams

    func testAStreamSessionReportsItsEventsInOrderWithOneSessionId() async throws {
        let (logger, sink) = makeLogger()
        let session = logger.startStream(
            .websocket,
            url: URL(string: "wss://chat.example.test/connection/websocket?token=abc")!,
            subprotocol: "chat-v2",
            headers: ["Authorization": "Bearer abc", "Origin": "app"]
        )
        session.connecting()
        session.connected(metadata: ["client": "c1", "session-token": "s"])
        session.subscribing("chat:1")
        session.subscribed("chat:1")
        session.sent(.text(#"{"type":"typing"}"#), channel: "chat:1", kind: "publish")
        session.received(.data(Data([0xFF, 0x00, 0x01])), channel: "chat:1", metadata: ["offset": "12"])
        session.disconnected(code: 1000, reason: "bye")
        await logger.flush()

        let events = await sink.snapshot()
        XCTAssertEqual(events.compactMap(\.stream?.kind.rawValue), ["connecting", "connected", "subscribing", "subscribed", "publish", "message", "disconnected"])
        XCTAssertEqual(events.compactMap(\.stream?.sequence), Array(0...6))
        XCTAssertEqual(Set(events.compactMap(\.stream?.sessionId)), [session.id])
        XCTAssertTrue(events.allSatisfy { $0.networkProtocol == .websocket && $0.stream?.subprotocol == "chat-v2" })
        XCTAssertTrue(events.allSatisfy { $0.request.url == "wss://chat.example.test/connection/websocket?token=<redacted>" })
        // The handshake's headers ride with the handshake only.
        XCTAssertEqual(events.map { $0.request.headers.isEmpty }, [false, false, true, true, true, true, true])
        XCTAssertEqual(events[0].request.headers["Authorization"], "<redacted>")
        XCTAssertEqual(events[1].stream?.metadata, ["client": "c1", "session-token": "<redacted>"])

        let sent = try XCTUnwrap(events[4].stream)
        XCTAssertEqual(sent.direction, .outgoing)
        XCTAssertEqual(sent.channel, "chat:1")
        XCTAssertEqual(sent.payloadPreview, #"{"type":"typing"}"#)
        XCTAssertNil(sent.payloadEncoding)
        let received = try XCTUnwrap(events[5].stream)
        XCTAssertEqual(received.direction, .incoming)
        XCTAssertEqual(received.payloadPreview, "/wAB")
        XCTAssertEqual(received.payloadEncoding, "base64")
        XCTAssertEqual(received.payloadByteCount, 3)
        XCTAssertEqual(events[6].stream?.code, 1000)
        XCTAssertEqual(events[6].stream?.reason, "bye")
        XCTAssertGreaterThanOrEqual(events[6].durationMilliseconds, 0)
        XCTAssertEqual(events[4].displayRequest, "↑ publish chat:1")
        XCTAssertEqual(events[0].displayRequest, "connecting wss://chat.example.test/connection/websocket?token=<redacted>")
        XCTAssertEqual(events[6].displayStatus, "1000 bye")
    }

    func testAFailedConnectionCarriesItsErrorAndHowLongItWasUp() async throws {
        let (logger, _) = makeLogger()
        let session = logger.startStream("sse", url: URL(string: "https://example.test/events")!)
        session.connected()
        try await Task.sleep(nanoseconds: 20_000_000)
        let failed = session.failed(URLError(.networkConnectionLost))

        XCTAssertEqual(failed.stream?.kind, .error)
        XCTAssertEqual(failed.error?.code, URLError.Code.networkConnectionLost.rawValue)
        XCTAssertGreaterThanOrEqual(failed.durationMilliseconds, 15)
        XCTAssertEqual(session.connecting().durationMilliseconds, 0)
    }

    func testAWebSocketTaskNamesItsSessionAndItsMessages() throws {
        let (logger, _) = makeLogger()
        var request = URLRequest(url: URL(string: "wss://example.test/socket")!)
        request.setValue("graphql-transport-ws", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        let session = logger.startStream(webSocket: task)

        XCTAssertEqual(session.networkProtocol, .websocket)
        XCTAssertEqual(session.subprotocol, "graphql-transport-ws")
        XCTAssertEqual(session.sent(webSocket: .string("ping")).stream?.payloadPreview, "ping")
        XCTAssertEqual(session.received(webSocket: .data(Data("pong".utf8))).stream?.payloadByteCount, 4)
        let closed = session.disconnected(closeCode: .goingAway, reason: Data("restart".utf8))
        XCTAssertEqual(closed.stream?.code, 1001)
        XCTAssertEqual(closed.stream?.reason, "restart")
        XCTAssertEqual(closed.request.url, "wss://example.test/socket")
    }

    func testAGRPCStreamIsASessionOfItsMethod() {
        let (logger, _) = makeLogger()
        let session = logger.startGRPCStream(service: "chat.v1.Chat", method: "Follow", authority: "grpc.example.test", requestMetadata: ["authorization": "x"])
        let event = session.received(.rendered("text: \"hi\"", byteCount: 4))

        XCTAssertEqual(event.networkProtocol, .grpc)
        XCTAssertEqual(event.request.path, "/chat.v1.Chat/Follow")
        XCTAssertEqual(event.request.metadata, ["authorization": "<redacted>"])
        XCTAssertEqual(event.stream?.payloadPreview, "text: \"hi\"")
        XCTAssertEqual(event.stream?.payloadByteCount, 4)
    }

    func testPreviewsFollowTheConfiguration() {
        let (logger, _) = makeLogger(captureBodyPreviews: false)
        let event = logger.startStream("mqtt", target: "broker:1883").sent(.text("hello"), channel: "a/b")

        XCTAssertNil(event.stream?.payloadPreview)
        XCTAssertEqual(event.stream?.payloadByteCount, 5)
    }

    // MARK: Delivery

    func testBatchesNeverPutACallAServerBefore1ReadsBesideOneItCannot() {
        let http = event("h", .http)
        let grpc = event("g", .grpc)
        let custom = event("c", "mqtt")
        var frame = event("f", .grpc)
        frame.stream = NetworkLoggerStream(sessionId: "s", kind: .message)

        let batches = SimToolNetworkLogger.batches([http, grpc, custom, frame, http, http, http], size: 2)
        XCTAssertEqual(batches.map { $0.map(\.id) }, [["h", "g"], ["c", "f"], ["h", "h"], ["h"]])
    }

    func testEmittedEventsReachTheSinksInOrder() async {
        let (logger, sink) = makeLogger()
        for index in 0..<120 { logger.emit(event("e\(index)", .http)) }
        await logger.flush()
        let delivered = await sink.snapshot()
        XCTAssertEqual(delivered.map(\.id), (0..<120).map { "e\($0)" })
    }

    // A server reads a batch event by event: one from a newer logger it cannot
    // read is skipped and counted, and the rest are kept.
    func testABatchDecodesEventByEvent() throws {
        let json = #"""
        {"source":"ios-app","pid":7,"loggerVersion":"1.1.0","events":[
          {"id":"good","timestamp":"2026-01-01T00:00:00.000Z","protocol":"http","durationMilliseconds":1,"request":{"headers":{},"metadata":{}}},
          {"id":"unreadable","protocol":"http"},
          {"id":"frame","timestamp":"2026-01-01T00:00:01.000Z","protocol":"websocket","durationMilliseconds":0,"request":{"headers":{},"metadata":{}},
           "stream":{"sessionId":"s","kind":"reaction","direction":"sideways","metadata":{}}}
        ]}
        """#
        let (batch, rejected) = try NetworkLoggerBatchPayload.decodingEachEvent(from: Data(json.utf8))
        XCTAssertEqual(batch.events.map(\.id), ["good", "frame"])
        XCTAssertEqual(rejected, 1)
        XCTAssertEqual(batch.pid, 7)
        XCTAssertEqual(batch.loggerVersion, "1.1.0")
        XCTAssertEqual(batch.events[1].stream?.kind.rawValue, "reaction")
        XCTAssertNil(batch.events[1].stream?.direction)
        XCTAssertThrowsError(try NetworkLoggerBatchPayload.decodingEachEvent(from: Data(#"{"source":"x"}"#.utf8)))
    }

    // MARK: Storage

    func testStreamEventsAreKeptApartFromCallsAndReadBackInOrder() {
        let store = NetworkLoggerEventStore(capacity: 2, streamCapacity: 3)
        var frames: [NetworkLoggerEvent] = []
        for index in 0..<5 {
            var frame = event("f\(index)", .websocket, at: "2026-01-01T00:00:0\(index).500Z")
            frame.stream = NetworkLoggerStream(sessionId: index < 3 ? "a" : "b", kind: .message, direction: .incoming)
            frames.append(frame)
        }
        store.ingest([event("c0", .http, at: "2026-01-01T00:00:00.000Z")] + frames + [event("c1", .http, at: "2026-01-01T00:00:03.000Z"), event("c2", .grpc, at: "2026-01-01T00:00:09.000Z")])

        XCTAssertEqual(store.query().events.map(\.id), ["f2", "c1", "f3", "f4", "c2"])
        XCTAssertEqual(store.query(filter: NetworkLoggerEventFilter(session: "b")).events.map(\.id), ["f3", "f4"])
        XCTAssertEqual(store.query(filter: NetworkLoggerEventFilter(networkProtocol: .websocket, limit: 1)).events.map(\.id), ["f4"])
    }

    // MARK: Redaction

    func testAPreviewCutInsideACharacterStaysText() {
        let text = "añb"   // ñ is two bytes
        XCTAssertEqual(NetworkLoggerRedactor.encodedPreview(data: Data(text.utf8), maxBytes: 2)?.text, "a")
        XCTAssertNil(NetworkLoggerRedactor.encodedPreview(data: Data(text.utf8), maxBytes: 2)?.encoding)
        XCTAssertEqual(NetworkLoggerRedactor.encodedPreview(data: Data([0xC3, 0x28]), maxBytes: 10)?.encoding, "base64")
    }

    func testOnlySensitiveQueryValuesAreRedacted() {
        let url = URL(string: "wss://example.test/ws?api_key=k&user=7&password=p&flag")!
        XCTAssertEqual(NetworkLoggerRedactor.redacted(url: url), "wss://example.test/ws?api_key=<redacted>&user=7&password=<redacted>&flag")
        XCTAssertEqual(NetworkLoggerRedactor.redacted(url: URL(string: "https://example.test/a?b=1")!), "https://example.test/a?b=1")
    }

    // MARK: Helpers

    private func makeLogger(captureBodyPreviews: Bool = true) -> (SimToolNetworkLogger, CollectingSink) {
        let sink = CollectingSink()
        let logger = SimToolNetworkLogger(
            configuration: NetworkLoggerConfiguration(appBundleID: "com.example.app", fileSinkEnabled: false, captureBodyPreviews: captureBodyPreviews),
            sinks: [sink]
        )
        return (logger, sink)
    }

    private func event(_ id: String, _ networkProtocol: NetworkLoggerProtocol, at timestamp: String = "2026-01-01T00:00:00.000Z") -> NetworkLoggerEvent {
        NetworkLoggerEvent(id: id, timestamp: timestamp, networkProtocol: networkProtocol, durationMilliseconds: 1, request: NetworkLoggerRequest())
    }
}

private actor CollectingSink: NetworkLoggerSink {
    private var events: [NetworkLoggerEvent] = []

    func record(_ events: [NetworkLoggerEvent]) async {
        self.events.append(contentsOf: events)
    }

    func snapshot() -> [NetworkLoggerEvent] { events }
}
