import Foundation
import SimToolCore
@testable import SimToolServer
import XCTest

// SimTool's own log: a server keeps what it says about itself and shows it
// in the viewer's Logs tab, apart from the app's lines.
final class SimToolOwnLogTests: XCTestCase {
    func testASinkGetsEveryLineWithItsLevelUntilItIsRemoved() {
        let lock = NSLock()
        var seen: [DebugLog.Line] = []
        let id = DebugLog.addSink { line in lock.withLock { if line.tag == "own-log-test" { seen.append(line) } } }
        DebugLog.write("own-log-test", "a detail")
        DebugLog.info("own-log-test", "something done")
        DebugLog.error("own-log-test", "something failed")
        DebugLog.removeSink(id)
        DebugLog.error("own-log-test", "after removal")
        XCTAssertEqual(lock.withLock { seen.map(\.level) }, [.debug, .info, .error])
        XCTAssertEqual(lock.withLock { seen.map(\.message) }, ["a detail", "something done", "something failed"])
        XCTAssertEqual(DebugLog.Level.error.rawValue, "Error", "the viewer's level names")
    }

    func testTheServerKeepsItsOwnLinesApartFromTheApps() async throws {
        let port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        let base = URL(string: "http://127.0.0.1:\(port)/api/v1/logs/")!
        DebugLog.error("own-log-test", "the relaunch failed")
        var own: LogCaptureEntriesPayload?
        for _ in 0..<50 {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("simtool"))
            own = try JSON.decoder.decode(LogCaptureEntriesPayload.self, from: data)
            if own?.entries.contains(where: { $0.message == "the relaunch failed" }) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let line = try XCTUnwrap(own?.entries.first { $0.message == "the relaunch failed" })
        XCTAssertEqual(line.source, .simtool)
        XCTAssertEqual(line.level, "Error")
        XCTAssertEqual(line.subsystem, "own-log-test")
        XCTAssertEqual(line.process, "simtool")
        let (appData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("capture"))
        let app = try JSON.decoder.decode(LogCaptureEntriesPayload.self, from: appData)
        XCTAssertFalse(app.entries.contains { $0.source == .simtool }, "the app's lines stay the app's: `simtool logs` reads them")

        server.stop()
        let cursor = try XCTUnwrap(own?.cursor)
        DebugLog.error("own-log-test", "after the server stopped")
        try await Task.sleep(for: .milliseconds(100))
        let after = server.ownLogLines(since: cursor)
        XCTAssertTrue(after.isEmpty, "a stopped server no longer listens")
    }
}
