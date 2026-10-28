import Darwin
import Foundation
import SimToolCore
import SimToolServer
import XCTest

// /api/v1/processes: the process list as the viewer reads it, and stopping a
// process from it — only a SimTool process, and the server itself only when
// the request confirms it.
final class ProcessRouteTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var running: Set<Int32>
        private(set) var signals: [String] = []
        private(set) var selfStops = 0

        init(running: Set<Int32>) { self.running = running }

        func signal(_ pid: Int32, _ signal: Int32) {
            lock.withLock {
                signals.append("\(pid):\(signal == SIGTERM ? "TERM" : "KILL")")
                running.remove(pid)
            }
        }

        func isRunning(_ pid: Int32) -> Bool { lock.withLock { running.contains(pid) } }
        func stopSelf() { lock.withLock { selfStops += 1 } }
        var sent: [String] { lock.withLock { signals } }
        var stops: Int { lock.withLock { selfStops } }
    }

    static let ownPID: Int32 = 500
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static var list: SimToolProcessList {
        let helper = "/Users/x/Library/Caches/SimTool/SimulatorHelpers/simtool-direct-hid-7-2ec7d869e3ed-arm64"
        let udid = "AAF7EA49-5B67-4042-A2D2-32152E9D10E7"
        return SimToolProcessDiscovery.list(
            records: [
                ProcessRecord(pid: ownPID, ppid: 1, executable: "/opt/homebrew/bin/simtool", arguments: ["simtool", "serve", "--port", "3200"], startedAt: start),
                ProcessRecord(pid: 501, ppid: ownPID, executable: helper, arguments: [helper, udid], startedAt: start),
                ProcessRecord(pid: 777, ppid: 1, executable: helper, arguments: [helper, udid], startedAt: start),
            ],
            sessions: [],
            helpersDirectory: "/Users/x/Library/Caches/SimTool/SimulatorHelpers",
            ownPID: ownPID,
            home: "/Users/x"
        )
    }

    func startServer(_ recorder: Recorder) throws -> (StreamServer, UInt16) {
        let port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let list = Self.list
        let control = SimToolProcessControl(
            list: { list },
            stopSession: { _ in true },
            stopSelf: { recorder.stopSelf() },
            signal: { recorder.signal($0, $1) },
            isRunning: { recorder.isRunning($0) },
            startTime: { _ in Self.start },
            pause: { _ in },
            ownPID: Self.ownPID
        )
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false), processes: control)
        try server.start()
        return (server, port)
    }

    func post(_ port: UInt16, _ path: String, body: String? = nil) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    func testTheListNamesTheServerAskingAndItsOrphans() async throws {
        let (server, port) = try startServer(Recorder(running: []))
        defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/v1/processes")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let list = try JSON.decoder.decode(SimToolProcessList.self, from: data)
        XCTAssertEqual(list.pid, Self.ownPID)
        XCTAssertEqual(list.orphans, 1)
        XCTAssertEqual(list.groups.map(\.kind), [.orphans, .server])
        XCTAssertEqual(list.groups[1].processes.map(\.pid), [Self.ownPID, 501])
        XCTAssertEqual(list.home, "/Users/x")
    }

    // A PID the discovery does not call SimTool's is refused, with the reason.
    func testAKillOfAnythingElseIsRefused() async throws {
        let recorder = Recorder(running: [1, 4242])
        let (server, port) = try startServer(recorder)
        defer { server.stop() }
        for path in ["/api/v1/processes/4242/kill", "/api/v1/processes/1/kill"] {
            let (status, body) = try await post(port, path)
            XCTAssertEqual(status, 403, path)
            XCTAssertTrue(body.contains("is not a SimTool process"), body)
        }
        let (status, _) = try await post(port, "/api/v1/processes/abc/kill")
        XCTAssertEqual(status, 400)
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    func testAnOrphanIsStoppedAndTheOrphansAllAtOnce() async throws {
        let recorder = Recorder(running: [Self.ownPID, 501, 777])
        let (server, port) = try startServer(recorder)
        defer { server.stop() }
        let (status, body) = try await post(port, "/api/v1/processes/777/kill")
        XCTAssertEqual(status, 200, body)
        let payload = try JSON.decoder.decode(ProcessKillPayload.self, from: Data(body.utf8))
        XCTAssertEqual(payload.outcomes.map(\.result), [.stopped])
        XCTAssertEqual(recorder.sent, ["777:TERM"])

        let again = Recorder(running: [Self.ownPID, 501, 777])
        let (other, otherPort) = try startServer(again)
        defer { other.stop() }
        let (allStatus, allBody) = try await post(otherPort, "/api/v1/processes/kill-orphans")
        XCTAssertEqual(allStatus, 200, allBody)
        XCTAssertEqual(try JSON.decoder.decode(ProcessKillPayload.self, from: Data(allBody.utf8)).outcomes.map(\.pid), [777])
        XCTAssertEqual(again.sent, ["777:TERM"], "the server's own helper is not an orphan")
    }

    // The server the request went to stops only on a confirmation, and then
    // by itself after it answered.
    func testTheServerStopsItselfOnlyWhenConfirmed() async throws {
        let recorder = Recorder(running: [Self.ownPID, 501])
        let (server, port) = try startServer(recorder)
        defer { server.stop() }
        let (refused, refusal) = try await post(port, "/api/v1/processes/\(Self.ownPID)/kill")
        XCTAssertEqual(refused, 409)
        XCTAssertTrue(refusal.contains("Confirm to stop it"), refusal)
        XCTAssertEqual(recorder.stops, 0)

        let (status, body) = try await post(port, "/api/v1/processes/\(Self.ownPID)/kill", body: #"{"confirm": true}"#)
        XCTAssertEqual(status, 200, body)
        XCTAssertEqual(try JSON.decoder.decode(ProcessKillPayload.self, from: Data(body.utf8)).outcomes.first?.result, .stopping)
        XCTAssertEqual(recorder.stops, 1)
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    // Another page may not stop anything: the same-origin rules hold here too.
    func testAnotherOriginCannotStopAProcess() throws {
        let recorder = Recorder(running: [777])
        let (server, port) = try startServer(recorder)
        defer { server.stop() }
        let response = try rawHTTP(port: port, "POST", "/api/v1/processes/777/kill", headers: ["Origin": "http://attacker.localhost"])
        XCTAssertEqual(response.status, 403)
        XCTAssertTrue(recorder.sent.isEmpty)
    }
}
