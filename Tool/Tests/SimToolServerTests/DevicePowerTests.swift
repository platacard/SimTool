import Foundation
import XCTest
import SimToolCore
@testable import SimToolServer

// SimTool shuts down a simulator nobody uses and its server stays up: the
// page and its lists go on answering, the viewer is told the simulator is
// off, and a command that needs the device starts it first.
final class DevicePowerTests: XCTestCase {
    func testWhatNeedsTheDevice() {
        XCTAssertTrue(DevicePower.needsDevice(method: "GET", path: "/stream.avcc"))
        XCTAssertTrue(DevicePower.needsDevice(method: "POST", path: "/api/v1/input"))
        XCTAssertTrue(DevicePower.needsDevice(method: "GET", path: "/api/v1/ax/tree"))
        XCTAssertTrue(DevicePower.needsDevice(method: "GET", path: "/api/v1/screenshot"))
        XCTAssertTrue(DevicePower.needsDevice(method: "POST", path: "/api/v1/tests/run"))
        XCTAssertFalse(DevicePower.needsDevice(method: "GET", path: "/api/v1/devices"), "the Mac's simulators")
        XCTAssertFalse(DevicePower.needsDevice(method: "GET", path: "/api/v1/network"), "what was recorded")
        XCTAssertFalse(DevicePower.needsDevice(method: "GET", path: "/api/v1/activity"))
        XCTAssertFalse(DevicePower.needsDevice(method: "GET", path: "/api/v1/recording"))
        XCTAssertFalse(DevicePower.needsDevice(method: "POST", path: "/api/v1/presence"))
        XCTAssertFalse(DevicePower.needsDevice(method: "POST", path: "/api/v1/device/wake"), "starting it")
    }

    func testTheRefusalSaysWhatTheSimulatorIsDoing() {
        XCTAssertEqual(DevicePower.refusal(device: "iPhone", power: ServerPowerPayload(state: .off)), "iPhone is off. Start it again to do this.")
        XCTAssertTrue(DevicePower.refusal(device: "iPhone", power: ServerPowerPayload(state: .starting)).hasPrefix("iPhone is starting"))
    }

    // A video connection the server closes ends its response: the page sees
    // the stream end and asks again, instead of waiting on a silent socket.
    func testAClosedStreamClientEndsItsResponse() {
        let clients = ClientManager()
        let client = clients.addAvccClient()
        let ended = expectation(description: "the response ends")
        client.setWriter({ _ in true }, onClose: { ended.fulfill() })
        clients.closeAll()
        wait(for: [ended], timeout: 1)
    }
}

final class DevicePowerRouteTests: XCTestCase {
    private var server: StreamServer!
    private var port: UInt16 = 0
    private let browser = ["Sec-Fetch-Mode": "cors", "Sec-Fetch-Site": "same-origin"]
    private let off = ServerPowerPayload(
        state: .off,
        reason: "idle",
        title: "Shut down after 15 min unused",
        detail: "SimTool turned iPhone off to save power."
    )

    /// How many times the server was asked to start the simulator.
    private final class Starts: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func note() { lock.withLock { value += 1 } }
    }

    override func setUpWithError() throws {
        port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    func testAServerWithItsSimulatorOffSaysSoAndAnswersOn() throws {
        XCTAssertEqual(server.powerState, .on)
        server.powerOff(off)

        let status = try rawHTTP(port: port, "/api/v1/status", headers: browser)
        XCTAssertEqual(status.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(ServerStatusPayload.self, from: Data(status.body.utf8)).power, off)
        let config = try rawHTTP(port: port, "/config", headers: browser)
        XCTAssertEqual(try JSONDecoder().decode(ServerConfigPayload.self, from: Data(config.body.utf8)).power, off)
        XCTAssertEqual(try rawHTTP(port: port, "/api/v1/activity", headers: browser).status, 200, "the lists answer")
    }

    // The viewer's own requests run by themselves; a simulator a person left
    // off is started by their Start, not by a poll.
    func testTheViewerAskingForTheDeviceIsToldItIsOff() throws {
        let starts = Starts()
        server.onWake { starts.note() }
        server.powerOff(off)

        let tree = try rawHTTP(port: port, "/api/v1/ax/tree", headers: browser)
        XCTAssertEqual(tree.status, 409)
        XCTAssertTrue(tree.body.contains("iPhone is off"), tree.body)
        XCTAssertTrue(tree.body.contains(#""state":"off""#), "the page learns why: \(tree.body)")
        XCTAssertEqual(try rawHTTP(port: port, "/stream.avcc", headers: browser).status, 409)
        XCTAssertEqual(starts.count, 0)
    }

    func testACommandThatNeedsTheDeviceStartsItFirst() throws {
        let starts = Starts()
        server.onWake { [server] in
            starts.note()
            try server?.powerOn()
        }
        server.powerOff(off)

        // A body the route turns down: what matters is that it got there.
        let input = try rawHTTP(port: port, "POST", "/api/v1/input", body: "not json")
        XCTAssertEqual(input.status, 400, input.body)
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(server.powerState, .on)
        _ = try rawHTTP(port: port, "POST", "/api/v1/input", body: "not json")
        XCTAssertEqual(starts.count, 1, "on: nothing to start")
    }

    func testAStartThatFailsSaysWhy() throws {
        server.onWake { throw SimToolError("simctl could not boot it") }
        server.powerOff(off)
        let input = try rawHTTP(port: port, "POST", "/api/v1/input", body: "{}")
        XCTAssertEqual(input.status, 503)
        XCTAssertTrue(input.body.contains("simctl could not boot it"), input.body)
    }

    func testTheViewersStartStartsIt() throws {
        let starts = Starts()
        server.onWake { [server] in
            starts.note()
            try server?.powerOn()
        }
        server.powerOff(off)
        let started = try rawHTTP(port: port, "POST", "/api/v1/device/wake", headers: browser.merging(["Origin": "http://127.0.0.1:\(port)"]) { $1 })
        XCTAssertEqual(started.status, 200, started.body)
        XCTAssertEqual(try JSONDecoder().decode(ServerPowerPayload.self, from: Data(started.body.utf8)), .on)
        XCTAssertEqual(starts.count, 1)
    }

    func testAServerNobodyCanStartSaysSo() throws {
        server.powerOff(off)
        let started = try rawHTTP(port: port, "POST", "/api/v1/device/wake")
        XCTAssertEqual(started.status, 503)
        XCTAssertTrue(started.body.contains("cannot start iPhone"), started.body)
    }
}
