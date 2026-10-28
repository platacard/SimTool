import Foundation
import XCTest
import SimToolClient
import SimToolCore
import SimToolStateLogger
import SimToolServer

/// The evidence a run writes is the run's own: what the server heard before
/// the run started — an earlier run, an earlier process of the app — stays out
/// of it.
final class TestRunEvidenceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-run-evidence-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStateTheServerHeardBeforeTheRunIsNotInItsEvidence() async throws {
        let port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(
            host: "127.0.0.1", port: port, device: device, captureEnabled: false, testSessionsRoot: root
        ))
        try server.start()
        defer { server.stop() }
        let client = SimToolClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)

        // The app as it was before the run: another process, its own models.
        _ = try await client.ingestStateLoggerEvents(StateLoggerBatchPayload(events: [event("CartModel#0"), event("LoginModel#0")], pid: 100))

        // No app to launch on a device that is not there: the state comes in by itself.
        let executor = TestRunExecutor(client: client, options: TestRunOptions(video: false, evidence: .failure))
        executor.onSessionStarted = { _ in
            Task { _ = try? await client.ingestStateLoggerEvents(StateLoggerBatchPayload(events: [event("CartModel#0")], pid: 200)) }
        }
        let result = await executor.run(TestDefinition(name: "state window", steps: [TestStep(action: .pause(1))]))

        let session = try XCTUnwrap(result.session)
        let file = root.appendingPathComponent(session.id).appendingPathComponent("state.jsonl")
        let events = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(StateLoggerEvent.self, from: Data($0.utf8)) }
        XCTAssertEqual(events.map(\.modelId), ["CartModel#0"])
        XCTAssertEqual(events.map(\.pid), [200], "only what the app reported while the run went on")
    }
}

private func event(_ modelId: String) -> StateLoggerEvent {
    StateLoggerEvent(
        modelId: modelId,
        name: String(modelId.prefix { $0 != "#" }),
        seq: 0,
        timestamp: Date().timeIntervalSince1970,
        snapshot: .object(["ready": .bool(true)])
    )
}
