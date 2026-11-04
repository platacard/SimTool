import Foundation
import SimToolCore
@testable import SimToolServer
import XCTest

// The app a server brings back when its simulator comes back on.
final class AppRelaunchTrackerTests: XCTestCase {
    private let launch = AppLaunchRecord(bundleId: "com.example.app", arguments: ["-Environment", "mock"], environment: ["FLAG": "1"], pid: 4242)

    func testAnAppRunningWhenSimToolShutTheSimulatorDownComesBackAsItWasLaunched() {
        let tracker = AppRelaunchTracker(defaultApp: nil)
        tracker.launched(launch)
        tracker.wentOff(runningNow: true)
        XCTAssertEqual(tracker.takePending(), launch, "same argv, same variables")
        XCTAssertNil(tracker.takePending(), "once")
    }

    func testAnAppNotRunningThenDoesNotComeBack() {
        let tracker = AppRelaunchTracker(defaultApp: nil)
        tracker.launched(launch)
        tracker.wentOff(runningNow: false)
        XCTAssertNil(tracker.takePending())
    }

    func testShutDownOutsideTheLastLookAtTheProcessDecides() {
        let tracker = AppRelaunchTracker(defaultApp: nil)
        tracker.launched(launch)
        tracker.sample { $0 == 4242 }
        tracker.wentOff(runningNow: nil)
        XCTAssertEqual(tracker.takePending()?.bundleId, "com.example.app", "it was alive at the last look")

        tracker.launched(launch)
        tracker.sample { _ in false }
        tracker.wentOff(runningNow: nil)
        XCTAssertNil(tracker.takePending(), "it had ended before the simulator went")
    }

    func testALaunchWithNoProcessKnownCountsAsRunning() {
        let tracker = AppRelaunchTracker(defaultApp: nil)
        tracker.launched(AppLaunchRecord(bundleId: "com.example.app"))
        tracker.sample { _ in false }
        tracker.wentOff(runningNow: nil)
        XCTAssertEqual(tracker.takePending()?.bundleId, "com.example.app")
    }

    func testAnAppTerminatedThroughSimToolStaysDown() {
        let tracker = AppRelaunchTracker(defaultApp: nil)
        tracker.launched(launch)
        tracker.terminated(bundleId: "com.example.app")
        XCTAssertNil(tracker.candidate)
        tracker.wentOff(runningNow: true)
        XCTAssertNil(tracker.takePending())
        tracker.launched(launch)
        XCTAssertNotNil(tracker.candidate, "a new launch undoes it")
    }

    func testTheServersOwnAppComesBackOnlyWhenTheSimulatorSaidItRan() {
        let tracker = AppRelaunchTracker(defaultApp: "com.example.served")
        tracker.wentOff(runningNow: nil)
        XCTAssertNil(tracker.takePending(), "never launched through SimTool, gone already: unknown")
        tracker.wentOff(runningNow: true)
        XCTAssertEqual(tracker.takePending(), AppLaunchRecord(bundleId: "com.example.served"), "no argv it was not given")
    }

    func testEveryLaunchMovesTheGenerationAndDropsWhatWasPending() {
        let tracker = AppRelaunchTracker(defaultApp: nil)
        tracker.launched(launch)
        tracker.wentOff(runningNow: true)
        let before = tracker.generation
        tracker.launched(AppLaunchRecord(bundleId: "com.example.other"))
        XCTAssertEqual(tracker.generation, before + 1)
        XCTAssertNil(tracker.takePending(), "someone launched an app since: theirs stands")
        XCTAssertEqual(tracker.launch(of: "com.example.other")?.bundleId, "com.example.other")
        XCTAssertNil(tracker.launch(of: "com.example.app"))
    }

    // `simtool app launch` and test runs report their launches here.
    func testTheLaunchedRouteTakesARecordAndRefusesNonsense() async throws {
        let port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }
        for (body, status) in [
            (#"{"bundleId": "com.example.app", "arguments": ["-A"], "environment": {"K": "V"}, "pid": 12}"#, 200),
            (#"{"bundleId": ""}"#, 400),
            (#"{"arguments": []}"#, 400),
        ] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/app/launched")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status, body)
        }
    }
}
