import Darwin
import Foundation
@testable import SimToolCore
import XCTest

// The network SimTool emulates for the apps it launches on one simulator.
final class SimulatorNetworkConditionTests: XCTestCase {
    private var udid = ""

    override func setUp() {
        udid = "TEST-NETCOND-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: SimulatorNetworkConditioner.directory(deviceUDID: udid))
    }

    func testThePresetsAreNetworkLinkConditionersAndFoundLoosely() throws {
        XCTAssertEqual(NetworkCondition.presets.map(\.title), ["100% Loss", "3G", "DSL", "Edge", "LTE", "Very Bad Network", "Wi-Fi"])
        let threeG = try XCTUnwrap(NetworkCondition.preset(named: "3G"))
        XCTAssertEqual([threeG.downKbps, threeG.upKbps, threeG.downDelayMs, threeG.upDelayMs], [780, 330, 100, 100])
        XCTAssertEqual(NetworkCondition.preset(named: "very bad")?.profile, "very-bad")
        XCTAssertEqual(NetworkCondition.preset(named: "Very Bad Network")?.downLoss, 10)
        XCTAssertEqual(NetworkCondition.preset(named: "100%")?.profile, "loss-100")
        XCTAssertEqual(NetworkCondition.preset(named: "EDGE")?.upDelayMs, 440)
        XCTAssertNil(NetworkCondition.preset(named: "5g"))
    }

    func testTheSummarySaysTheLinkEachWay() {
        XCTAssertEqual(NetworkCondition.preset(named: "3g")?.summary, "3G — ↓780 kbps 100 ms · ↑330 kbps 100 ms")
        XCTAssertEqual(NetworkCondition.preset(named: "lte")?.summary, "LTE — ↓50 Mbps 50 ms · ↑10 Mbps 65 ms")
        XCTAssertEqual(NetworkCondition.preset(named: "very-bad")?.summary, "Very Bad Network — ↓1 Mbps 500 ms 10% loss · ↑1 Mbps 500 ms 10% loss")
        XCTAssertEqual(NetworkCondition.preset(named: "loss-100")?.summary, "100% Loss — nothing gets through")
        XCTAssertEqual(NetworkCondition(profile: "custom", title: "Custom", downDelayMs: 300).summary, "Custom — ↓any rate 300 ms · ↑any rate")
    }

    func testARequestResolvesToAPresetANumberChangedOrACustomLink() throws {
        XCTAssertNil(try NetworkConditionRequest(profile: "off").resolve())
        XCTAssertEqual(try NetworkConditionRequest(profile: "edge").resolve(), NetworkCondition.preset(named: "edge"))
        let adjusted = try XCTUnwrap(try NetworkConditionRequest(profile: "3g", delayMs: 800).resolve())
        XCTAssertEqual(adjusted.profile, "3g+")
        XCTAssertEqual(adjusted.title, "3G (adjusted)")
        XCTAssertEqual([adjusted.downDelayMs, adjusted.upDelayMs, adjusted.downKbps], [800, 800, 780], "delay sets both ways, the rest stays the preset's")
        let custom = try XCTUnwrap(try NetworkConditionRequest(downKbps: 512, upKbps: 128, delayMs: 300, loss: 2).resolve())
        XCTAssertEqual(custom.profile, "custom")
        XCTAssertEqual([custom.downKbps, custom.upKbps, custom.downDelayMs, custom.upDelayMs, custom.downLoss, custom.upLoss], [512, 128, 300, 300, 2, 2])
        XCTAssertEqual(try NetworkConditionRequest(profile: "custom", loss: 250).resolve()?.downLoss, 100, "loss is a percentage")
    }

    func testANonsenseRequestIsRefusedWithWhatWouldDo() {
        XCTAssertThrowsError(try NetworkConditionRequest(profile: "5g").resolve()) { error in
            XCTAssertTrue("\(error)".contains("3g, dsl, edge"), "\(error)")
        }
        XCTAssertThrowsError(try NetworkConditionRequest(profile: "custom").resolve(), "custom with no numbers")
        XCTAssertThrowsError(try NetworkConditionRequest(profile: "edge", delayMs: -5).resolve())
        XCTAssertThrowsError(try NetworkConditionRequest(downKbps: .infinity).resolve())
    }

    // Off, a launch carries nothing; a server starting or stopping turns it off.
    func testALaunchCarriesNothingWhileItIsOff() throws {
        let environment = ["SIMTOOL_SERVER_URL": "http://127.0.0.1:3300"]
        XCTAssertEqual(SimulatorNetworkConditioner.launchEnvironment(deviceUDID: udid, merging: environment), environment)
        XCTAssertEqual(SimToolLaunchEnvironment.forApp(deviceUDID: udid, merging: environment), environment)
        SimulatorNetworkConditioner.off(deviceUDID: udid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SimulatorNetworkConditioner.directory(deviceUDID: udid).path), "off writes nothing where nothing was set")
        XCTAssertNil(SimulatorNetworkConditioner.state(deviceUDID: udid).condition)
        XCTAssertEqual(SimulatorNetworkConditioner.state(deviceUDID: udid).summary, "Off — the network as it is")
    }

    // An app that spoke lately has it; one gone quiet has it while its process
    // runs; an ended one's file goes.
    func testTheAppsThatHaveItAreTheLiveOnes() throws {
        let clients = SimulatorNetworkConditioner.directory(deviceUDID: udid).appendingPathComponent("clients", isDirectory: true)
        try FileManager.default.createDirectory(at: clients, withIntermediateDirectories: true)
        func beat(_ pid: Int, _ bundleId: String, at: Double, connections: Int = 3) throws {
            let text = #"{"bundleId":"\#(bundleId)","pid":\#(pid),"connections":\#(connections),"at":\#(at)}"#
            try Data(text.utf8).write(to: clients.appendingPathComponent("\(pid).json"))
        }
        try beat(10, "com.example.fresh", at: 998)
        try beat(20, "com.example.suspended", at: 900)
        try beat(30, "com.example.ended", at: 900)
        let apps = SimulatorNetworkConditioner.clients(deviceUDID: udid, now: Date(timeIntervalSince1970: 1_000), startOfProcess: { $0 == 20 ? 800 : nil })
        XCTAssertEqual(apps, [
            NetworkConditionClient(bundleId: "com.example.fresh", pid: 10, connections: 3),
            NetworkConditionClient(bundleId: "com.example.suspended", pid: 20, connections: 3),
        ])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: clients.path).sorted(), ["10.json", "20.json"])
    }

    // The condition file is what the library parses: flat numbers and `active`.
    func testTheConditionIsWrittenFlatForTheLibrary() async throws {
        let edge = try XCTUnwrap(NetworkCondition.preset(named: "edge"))
        // Writes without building the library: `set` builds it, and that takes Xcode.
        SimulatorNetworkConditioner.off(deviceUDID: udid)
        let directory = SimulatorNetworkConditioner.directory(deviceUDID: udid)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"active":false}"#.utf8).write(to: directory.appendingPathComponent("condition.json"))
        _ = try await SimulatorNetworkConditioner.set(edge, deviceUDID: udid)
        let text = try String(contentsOf: directory.appendingPathComponent("condition.json"), encoding: .utf8)
        for key in [#""active":true"#, #""downKbps":240"#, #""upDelayMs":440"#, #""downLoss":0"#] {
            XCTAssertTrue(text.contains(key), "\(key) in \(text)")
        }
        XCTAssertEqual(SimulatorNetworkConditioner.condition(deviceUDID: udid), edge)
        SimulatorNetworkConditioner.off(deviceUDID: udid)
        XCTAssertNil(SimulatorNetworkConditioner.condition(deviceUDID: udid))
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("condition.json"), encoding: .utf8).contains(#""active":false"#))
    }

    // The library is C the simulator's SDK must compile: built once per source.
    func testTheLibraryBuildsForTheSimulator() async throws {
        let library = try await SimulatorNetworkConditioner.injectorURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
        XCTAssertTrue(library.lastPathComponent.hasPrefix("simtool-netcond-"))
    }
}
