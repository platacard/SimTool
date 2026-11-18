import Foundation
import SimToolClient
import SimToolCore
@testable import SimToolServer
import XCTest

// The app a server serves: `--app`, or a build installed from a URL and
// launched — which the viewer attaches to from then on, and which the server
// launches with its loggers armed to report here.
final class ServedAppTests: XCTestCase {
    func testABuildTakenOnIsServedAndGetsItsLoggersFromTheServer() {
        let served = ServedApp(nil)
        XCTAssertNil(served.current)
        XCTAssertTrue(served.takeOn("com.example.probe"))
        XCTAssertEqual(served.current, "com.example.probe")
        XCTAssertTrue(served.armsLoggers(of: "com.example.probe"))
        XCTAssertFalse(served.armsLoggers(of: "com.example.other"), "only the app it serves")
        XCTAssertFalse(served.takeOn("com.example.probe"), "the same app again is no change")
        XCTAssertTrue(served.takeOn("com.example.next"))
        XCTAssertFalse(served.armsLoggers(of: "com.example.probe"), "the one before is not served any more")
    }

    func testTheAppOfAppIsServedWithItsLoggersFromTheEnvironment() {
        let served = ServedApp("com.example.app")
        XCTAssertEqual(served.current, "com.example.app")
        XCTAssertFalse(served.armsLoggers(of: "com.example.app"), "`serve --app` arms them in the server's environment")
        XCTAssertNil(ServedApp("").current)
        // Installed from a URL and launched, the same app is the server's to arm.
        XCTAssertFalse(served.takeOn("com.example.app"))
        XCTAssertTrue(served.armsLoggers(of: "com.example.app"))
    }

    func testTheViewerLearnsOfTheAppTakenOnAndItsLaunchesReportHere() async throws {
        let port = try freeLoopbackPort()
        let server = makeServer(port: port)
        try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let client = SimToolClient(baseURL: base)
        let config = try await client.config()
        XCTAssertNil(config.logApp, "no --app: nothing attached yet")
        XCTAssertEqual(server.launchEnvironment(of: "com.example.probe", merging: ["FLAG": "1"]), ["FLAG": "1"], "an app the server does not serve gets nothing")

        let stream = try await EventStream.open(base)
        defer { stream.close() }
        let snapshot = try await stream.next()
        XCTAssertEqual(snapshot.name, "snapshot")
        XCTAssertEqual(snapshot.json["app"] as? [String: String], [:], "the snapshot names no app")

        // Taken on before its launch, told to the viewers after it.
        XCTAssertTrue(server.takeOn("com.example.probe"))
        let attached = try await client.config()
        XCTAssertEqual(attached.logApp, "com.example.probe")
        server.announceServedApp()
        let taken = try await stream.next()
        XCTAssertEqual(taken.name, "app")
        XCTAssertEqual(taken.json["app"] as? String, "com.example.probe")

        XCTAssertEqual(server.launchEnvironment(of: "com.example.probe"), [
            "SIMTOOL_NETWORK_LOGGER": "1",
            "SIMTOOL_STATE_LOGGER": "1",
            "SIMTOOL_SERVER_URL": "http://127.0.0.1:\(port)",
        ])
        XCTAssertEqual(server.launchEnvironment(of: "com.example.probe", merging: ["SIMTOOL_SERVER_URL": "http://elsewhere:1", "FLAG": "1"])["SIMTOOL_SERVER_URL"],
                       "http://elsewhere:1", "the launch's own variables win")
        XCTAssertEqual(server.launchEnvironment(of: "com.example.other"), [:])

        // The same app once more is no news; the next is.
        XCTAssertFalse(server.takeOn("com.example.probe"))
        XCTAssertTrue(server.takeOn("com.example.next"))
        server.announceServedApp()
        let next = try await stream.next()
        XCTAssertEqual(next.json["app"] as? String, "com.example.next")

        // A new viewer's snapshot names it.
        let late = try await EventStream.open(base)
        defer { late.close() }
        let lateSnapshot = try await late.next()
        XCTAssertEqual(lateSnapshot.json["app"] as? [String: String], ["app": "com.example.next"])
    }

    func testTheLoggersTurnedOffStayOffForTheAppTakenOn() throws {
        let server = makeServer(port: try freeLoopbackPort(), loggers: AppLoggers(network: false, state: true))
        server.takeOn("com.example.probe")
        XCTAssertEqual(server.launchEnvironment(of: "com.example.probe").keys.sorted(), ["SIMTOOL_SERVER_URL", "SIMTOOL_STATE_LOGGER"])
        let silent = makeServer(port: try freeLoopbackPort(), loggers: AppLoggers(network: false, state: false))
        silent.takeOn("com.example.probe")
        XCTAssertEqual(silent.launchEnvironment(of: "com.example.probe"), [:])
    }

    func testAServerOnEveryInterfaceIsReachedOnLoopback() throws {
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        XCTAssertEqual(StreamServer(config: StreamServerConfig(host: "0.0.0.0", port: 3271, device: device, captureEnabled: false)).appFacingURL, "http://127.0.0.1:3271")
        XCTAssertEqual(StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: 3270, device: device, captureEnabled: false)).appFacingURL, "http://127.0.0.1:3270")
    }

    private func makeServer(port: UInt16, loggers: AppLoggers = AppLoggers()) -> StreamServer {
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("simtool-served-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return StreamServer(config: StreamServerConfig(
            host: "127.0.0.1", port: port, device: device, captureEnabled: false,
            testSessionsRoot: root.appendingPathComponent("test-sessions"), testsRoot: root.appendingPathComponent("tests"),
            appLoggers: loggers
        ))
    }
}
