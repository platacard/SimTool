import SimToolCore
import XCTest

final class StreamSettingsTests: XCTestCase {
    func testTheStandardStreamIsSixtyFramesASecond() {
        XCTAssertEqual(StreamSettings.standard, StreamSettings(fps: 60, bitrate: 6_000_000, maxDimension: 1280))
        XCTAssertEqual(StreamSettings.standard.summary, "60 fps, 6 Mbit/s, 1280 px")
    }

    func testBitratesAreReadAsPeopleWriteThem() {
        XCTAssertEqual(StreamSettings.parseBitrate("6M"), 6_000_000)
        XCTAssertEqual(StreamSettings.parseBitrate("1.5M"), 1_500_000)
        XCTAssertEqual(StreamSettings.parseBitrate("800k"), 800_000)
        XCTAssertEqual(StreamSettings.parseBitrate("800K"), 800_000)
        XCTAssertEqual(StreamSettings.parseBitrate("6000000"), 6_000_000)
        for wrong in ["", "M", "-1M", "6 Mbit", "abc", "1e9", "0", "6MB"] {
            XCTAssertNil(StreamSettings.parseBitrate(wrong), wrong)
        }
    }

    func testBitratesAreWrittenShort() {
        XCTAssertEqual(StreamSettings.describeBitrate(6_000_000), "6 Mbit/s")
        XCTAssertEqual(StreamSettings.describeBitrate(1_500_000), "1.5 Mbit/s")
        XCTAssertEqual(StreamSettings.describeBitrate(800_000), "800 kbit/s")
    }

    // A viewer's own settings come on the stream's URL: each optional, each
    // brought into range, anything but a whole number ignored.
    func testAViewerMayAskForItsOwnSettings() {
        let server = StreamSettings.standard
        XCTAssertEqual(server.overridden(fps: "30", kbps: "3000", px: "960"), StreamSettings(fps: 30, bitrate: 3_000_000, maxDimension: 960))
        XCTAssertEqual(server.overridden(fps: nil, kbps: nil, px: nil), server)
        XCTAssertEqual(server.overridden(fps: "15", kbps: nil, px: nil), StreamSettings(fps: 15, bitrate: 6_000_000, maxDimension: 1280))
        XCTAssertEqual(server.overridden(fps: "0", kbps: "1", px: "100000"), StreamSettings(fps: 1, bitrate: 100_000, maxDimension: 4096))
        XCTAssertEqual(server.overridden(fps: "120", kbps: "abc", px: "7.5"), StreamSettings(fps: 60, bitrate: 6_000_000, maxDimension: 1280))
    }
}
