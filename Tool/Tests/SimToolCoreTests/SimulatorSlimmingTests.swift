import Foundation
@testable import SimToolCore
import XCTest

final class SimulatorSlimmingTests: XCTestCase {
    private let keptByDefault = ["com.apple.apsd", "com.apple.swcd", "com.apple.storekitd", "com.apple.assetsd", "com.apple.assetsd.nebulad", "com.apple.medialibraryd", "com.apple.contactsd", "com.apple.calaccessd"]

    func testByDefaultWhatAppsUnderTestReachForStaysOn() throws {
        let off = try SimulatorSlimming.labelsToTurnOff()
        for label in keptByDefault { XCTAssertFalse(off.contains(label), label) }
        for label in ["com.apple.PosterBoard", "com.apple.chronod", "com.apple.mediaanalysisd", "com.apple.searchd", "com.apple.triald", "com.apple.newsd"] {
            XCTAssertTrue(off.contains(label), label)
        }
        XCTAssertEqual(off.count, SimulatorSlimming.managedLabels.count - 8 - 6, "the pim category's 8 and 6 kept services")
    }

    func testAllTurnsOffTheWholeCatalog() throws {
        XCTAssertEqual(try SimulatorSlimming.labelsToTurnOff(all: true), SimulatorSlimming.managedLabels)
    }

    func testMoreIsKeptByCategoryOrByService() throws {
        let off = try SimulatorSlimming.labelsToTurnOff(keep: ["widgets", "com.apple.triald,searchd"])
        XCTAssertFalse(off.contains("com.apple.chronod"))
        XCTAssertFalse(off.contains("com.apple.PosterBoard"))
        XCTAssertFalse(off.contains("com.apple.triald"))
        XCTAssertFalse(off.contains("com.apple.searchd"))
        XCTAssertTrue(off.contains("com.apple.newsd"))
        // navd is in widgets and connectivity: a kept category keeps it on.
        XCTAssertFalse(off.contains("com.apple.navd"))
        let all = try SimulatorSlimming.labelsToTurnOff(all: true, keep: ["store"])
        XCTAssertFalse(all.contains("com.apple.apsd"))
        XCTAssertTrue(all.contains("com.apple.contactsd"), "--all turns off what the default keeps")
        XCTAssertThrowsError(try SimulatorSlimming.labelsToTurnOff(keep: ["com.apple.SpringBoard"]))
        XCTAssertThrowsError(try SimulatorSlimming.labelsToTurnOff(keep: ["sirri"]))
    }

    // What wedges a simulator is never in the catalog, so never turned off.
    func testWhatWedgesASimulatorIsNeverTurnedOff() {
        XCTAssertTrue(SimulatorSlimming.managedLabels.isDisjoint(with: SimulatorSlimming.neverOff))
        XCTAssertTrue(SimulatorSlimming.neverOff.contains("com.apple.nanoregistryd"))
        XCTAssertTrue(SimulatorSlimming.neverOff.contains("com.apple.sleepd"))
        for category in SimulatorSlimming.categories {
            XCTAssertEqual(Set(category.names).count, category.names.count, category.id)
        }
    }

    func testOnlyRuntimesThatKeepTheListAcrossRebootsAreSlimmed() {
        XCTAssertNil(SimulatorSlimming.refusal(runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"))
        XCTAssertNil(SimulatorSlimming.refusal(runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-5"))
        XCTAssertNil(SimulatorSlimming.refusal(runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"))
        XCTAssertNotNil(SimulatorSlimming.refusal(runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-4"))
        XCTAssertNotNil(SimulatorSlimming.refusal(runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-5"))
        XCTAssertNotNil(SimulatorSlimming.refusal(runtime: "com.apple.CoreSimulator.SimRuntime.watchOS-26-0"))
    }

    func testTheListIsWrittenWholeAndKeepsOtherEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = SimulatorSlimming.overridesURL(udid: "ABC", root: root)
        XCTAssertEqual(url.path, root.path + "/com.apple.CoreSimulator.SimDevice.ABC/disabled.plist")
        XCTAssertEqual(try SimulatorSlimming.readOverrides(at: url), [:])

        try SimulatorSlimming.writeOverrides(off: ["com.apple.chronod", "com.apple.triald"], at: url)
        XCTAssertEqual(try SimulatorSlimming.readOverrides(at: url), ["com.apple.chronod": true, "com.apple.triald": true])
        let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        // Somebody else's entry stays; the catalog's are replaced.
        var list = try SimulatorSlimming.readOverrides(at: url)
        list["com.example.other"] = true
        try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0).write(to: url)
        try SimulatorSlimming.writeOverrides(off: ["com.apple.newsd"], at: url)
        XCTAssertEqual(try SimulatorSlimming.readOverrides(at: url), ["com.apple.newsd": true, "com.example.other": true])

        // Everything back on: only the other entry is left; then nothing, and no file.
        try SimulatorSlimming.writeOverrides(off: [], at: url)
        XCTAssertEqual(try SimulatorSlimming.readOverrides(at: url), ["com.example.other": true])
        try PropertyListSerialization.data(fromPropertyList: ["com.apple.newsd": true], format: .xml, options: 0).write(to: url)
        try SimulatorSlimming.writeOverrides(off: [], at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, [], "no staging file left behind")
    }

    func testWhatTheSimulatorSaysIsOffIsRead() {
        let text = """
        disabled services = {
        \t"com.apple.chronod" => disabled
        \t"com.apple.triald" => enabled
        \t"com.apple.newsd" => true
        }
        login item associations = {
        }
        """
        XCTAssertEqual(SimulatorSlimming.parsePrintDisabled(text), ["com.apple.chronod": true, "com.apple.triald": false, "com.apple.newsd": true])
    }

    func testCategoriesAreOffPartlyOrOn() throws {
        let summary = SimulatorSlimming.summary(off: try SimulatorSlimming.labelsToTurnOff())
        XCTAssertTrue(summary.off.contains("widgets"))
        XCTAssertTrue(summary.partly.contains("store"))
        XCTAssertTrue(summary.partly.contains("photos"))
        XCTAssertTrue(summary.partly.contains("web"))
        XCTAssertEqual(summary.on, ["pim"])
    }
}
