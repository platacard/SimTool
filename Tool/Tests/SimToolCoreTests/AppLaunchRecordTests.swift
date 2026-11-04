import SimToolCore
import XCTest

final class AppLaunchRecordTests: XCTestCase {
    func testThePidComesFromSimctlsAnswer() {
        XCTAssertEqual(AppLaunchRecord.pid(fromLaunchOutput: "com.example.app: 20714\n"), 20714)
        XCTAssertEqual(AppLaunchRecord.pid(fromLaunchOutput: "warning: something\ncom.example.app: 7"), 7)
        XCTAssertNil(AppLaunchRecord.pid(fromLaunchOutput: ""))
        XCTAssertNil(AppLaunchRecord.pid(fromLaunchOutput: "An error was encountered: no"))
    }

    func testAnAppRunsWhileItsLaunchdLabelHasAPid() {
        let list = """
        PID\tStatus\tLabel
        35330\t0\tUIKitApplication:com.example.app[b371][rb-legacy]
        -\t0\tUIKitApplication:com.example.gone[40cf][rb-legacy]
        27631\t0\tUIKitApplication:com.example.app.widget[c463][rb-legacy]
        """
        XCTAssertTrue(SimulatorAppProcess.isRunning(bundleId: "com.example.app", launchctlList: list))
        XCTAssertFalse(SimulatorAppProcess.isRunning(bundleId: "com.example.gone", launchctlList: list), "ended: its label stays with no pid")
        XCTAssertFalse(SimulatorAppProcess.isRunning(bundleId: "com.example", launchctlList: list), "a prefix of another app is not it")
    }
}
