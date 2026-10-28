import Foundation
import XCTest
@testable import SimToolCLI
import SimToolCore

/// `simtool doctor`'s row about the app's network logger: the app pins the
/// SimTool package, the CLI comes from Homebrew or mise, and doctor is where a
/// developer looks when the two have drifted apart.
final class DoctorNetworkLoggerTests: XCTestCase {
    private func ack(_ version: String?, reported: Bool = true) -> MockAcknowledgementPayload {
        MockAcknowledgementPayload(generation: 0, logger: reported ? NetworkLoggerReportPayload(version: version, reportedAt: Date()) : nil)
    }

    func testAMismatchIsAFailedCheckThatNamesBothReleases() {
        let check = Doctor.networkLoggerCheck(.server(ack("0.10.0")), cli: "1.0.0")
        XCTAssertFalse(check.available)
        XCTAssertEqual(check.status, "mismatch")
        XCTAssertEqual(check.detail, "The app links SimToolNetworkLogger 0.10, the CLI is 1.0: pin the app's SimTool package and the CLI to one release.")
    }

    func testOneReleaseMatches() {
        let check = Doctor.networkLoggerCheck(.server(ack("1.0.2")), cli: "1.0.0")
        XCTAssertTrue(check.available)
        XCTAssertEqual(check.status, "matches")
        XCTAssertEqual(check.detail, "SimToolNetworkLogger 1.0.2, the CLI is 1.0.0.")
    }

    func testALoggerFromBeforeVersionReportsIsAMismatchForA1CLI() {
        let check = Doctor.networkLoggerCheck(.server(ack(nil)), cli: "1.0.0")
        XCTAssertFalse(check.available)
        XCTAssertTrue(check.detail.contains("older than 1.0"), check.detail)
    }

    // Without a word from the app there is nothing to compare, and nothing is missing.
    func testNoServerOrNoAppIsNotAFailure() {
        let none = Doctor.networkLoggerCheck(.noServer, cli: "1.0.0")
        XCTAssertTrue(none.available)
        XCTAssertEqual(none.status, "not checked")
        let silent = Doctor.networkLoggerCheck(.server(ack(nil, reported: false)), cli: "1.0.0")
        XCTAssertTrue(silent.available)
        XCTAssertEqual(silent.status, "not heard")
    }
}
