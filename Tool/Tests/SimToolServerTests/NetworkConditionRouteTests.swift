import Foundation
import SimToolCore
import SimToolServer
import XCTest

// /api/v1/network/condition: what is emulated, and changing it as one activity.
final class NetworkConditionRouteTests: XCTestCase {
    func testTheRouteAnswersTheStateRefusesNonsenseAndTurnsItOff() async throws {
        let port = try freeLoopbackPort()
        let udid = "TEST-NETCOND-ROUTE-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: SimulatorNetworkConditioner.directory(deviceUDID: udid)) }
        let device = SimulatorDevice(udid: udid, name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)/api/v1/network/condition"

        let (data, _) = try await URLSession.shared.data(from: URL(string: base)!)
        let state = try JSON.decoder.decode(NetworkConditionState.self, from: data)
        XCTAssertNil(state.condition)
        XCTAssertEqual(state.presets.count, NetworkCondition.presets.count)
        XCTAssertTrue(state.scope.contains("not the Mac"))

        func send(_ method: String, _ body: String?) async throws -> (Int, String) {
            var request = URLRequest(url: URL(string: base)!)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.map { Data($0.utf8) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        let refused = try await send("POST", #"{"profile": "5g"}"#)
        XCTAssertEqual(refused.0, 400)
        XCTAssertTrue(refused.1.contains("Unknown network profile"), refused.1)
        let off = try await send("DELETE", nil)
        XCTAssertEqual(off.0, 200, off.1)

        let (feedData, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/v1/activity")!)
        let feed = try JSON.decoder.decode(DeviceActivityPayload.self, from: feedData)
        XCTAssertEqual(feed.entries.map(\.kind), ["network-condition"], "a nonsense request never got as far as an activity")
        XCTAssertEqual(feed.entries.first?.title, "Network: as it is")
        XCTAssertEqual(feed.entries.first?.status, .done)
    }
}
