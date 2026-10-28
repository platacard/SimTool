import Foundation
import SimToolNetworkLogger
import XCTest
@testable import SimToolCore

final class NetworkLoggerCompatibilityTests: XCTestCase {
    // One tag ships the CLI and the libraries an app links: one number for both.
    func testTheCLIAndTheLoggerAreOneRelease() {
        XCTAssertEqual(SimToolVersion.base, SimToolNetworkLogger.version)
    }

    func testPatchReleasesMatchAndAnotherMinorOrMajorDoesNot() {
        XCTAssertNil(NetworkLoggerCompatibility.warning(reported: "1.0.3", cli: "1.0.0"))
        XCTAssertNil(NetworkLoggerCompatibility.warning(reported: "1.0.0", cli: "1.0.0-dev"), "a build from source is still its release")
        XCTAssertEqual(
            NetworkLoggerCompatibility.warning(reported: "1.0.0", cli: "1.1.0"),
            "The app links SimToolNetworkLogger 1.0, the CLI is 1.1: pin the app's SimTool package and the CLI to one release."
        )
        XCTAssertNotNil(NetworkLoggerCompatibility.warning(reported: "2.0.0", cli: "1.0.0"))
    }

    // Loggers before 1.0 report no version, so a 1.0 CLI knows one that says
    // nothing is older; a CLI before 1.0 cannot tell it from its own.
    func testALoggerThatReportsNothingPredatesTheFirstReportingRelease() {
        XCTAssertEqual(
            NetworkLoggerCompatibility.warning(reported: nil, cli: "1.0.0"),
            "The app links a SimToolNetworkLogger older than 1.0, the CLI is 1.0: update the app's SimTool package to 1.0."
        )
        XCTAssertNil(NetworkLoggerCompatibility.warning(reported: nil, cli: "0.13.0"))
    }

    func testAVersionThatIsNotOneSaysNothing() {
        XCTAssertNil(NetworkLoggerCompatibility.warning(reported: "main", cli: "1.0.0"))
        XCTAssertNil(NetworkLoggerCompatibility.warning(reported: "1.0.0", cli: "dev"))
        XCTAssertEqual(NetworkLoggerCompatibility.release(of: "1.1-beta.1"), .init(major: 1, minor: 1))
    }

    func testThePeerReportsAChangeOnlyWhenTheReleaseChanges() {
        let peer = NetworkLoggerPeer()
        XCTAssertNil(peer.lastReport)
        XCTAssertNotNil(peer.heard(version: "1.0.0", cli: "1.1.0")?.warning, "the first report is news")
        XCTAssertNil(peer.heard(version: "1.0.0", cli: "1.1.0"), "every poll repeats it")
        XCTAssertNotNil(peer.lastReport?.warning)
        XCTAssertNotNil(peer.heard(version: "1.1.0", cli: "1.1.0"), "the app was rebuilt against the CLI's release")
        XCTAssertEqual(peer.lastReport?.version, "1.1.0")
        XCTAssertNil(peer.lastReport?.warning)
    }
}
