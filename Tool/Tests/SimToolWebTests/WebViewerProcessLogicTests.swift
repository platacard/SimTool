import JavaScriptCore
@testable import SimToolWeb
import XCTest

// The process list: how long a process has run, where it is, how a group is
// headed, what a stop asks first and what it reports.
final class WebViewerProcessLogicTests: XCTestCase {
    private func makeContext(file: StaticString = #filePath, line: UInt = #line) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JS exception: \(exception?.toString() ?? "?")", file: file, line: line)
        }
        context.evaluateScript(WebViewer.asset("js/logic.js"))
        context.evaluateScript("""
        var list = {
          pid: 500, home: "/Users/x", orphans: 1,
          groups: [
            { kind: "orphans", processes: [
              { pid: 103, kind: "helper", name: "simctl spawn · fold helper", orphan: true },
              { pid: 104, kind: "helper", name: "fold helper", owner: 103, orphan: true } ] },
            { kind: "server", session: { url: "http://127.0.0.1:3252", projectRoot: "/Users/x/Workspace/app", device: { name: "iPhone 17" } }, processes: [
              { pid: 500, kind: "server", name: "simtool serve", arguments: ["serve"] },
              { pid: 501, kind: "helper", name: "direct-hid helper", owner: 500 } ] },
            { kind: "server", processes: [
              { pid: 600, kind: "server", name: "simtool serve", arguments: ["serve", "--port", "3300"], deviceUDID: "AAF7EA49-5B67-4042-A2D2-32152E9D10E7", directory: "/tmp/elsewhere" } ] },
            { kind: "other", processes: [
              { pid: 700, kind: "reaper", name: "simtool reap --watch" },
              { pid: 701, kind: "command", name: "simtool test run" },
              { pid: 702, kind: "child", name: "xcodebuild", owner: 701 } ] }
          ]
        };
        function find(pid) { return list.groups.flatMap(function (g) { return g.processes; }).find(function (p) { return p.pid === pid; }); }
        """)
        return context
    }

    private func value(_ context: JSContext, _ expression: String) -> String {
        context.evaluateScript(expression)?.toString() ?? ""
    }

    func testUptimeReadsInTheLargestUnitsThatMatter() throws {
        let context = try makeContext()
        let start = "'2026-10-27T10:00:00Z'"
        let at = { (seconds: Int) in "Date.parse('2026-10-27T10:00:00Z') + \(seconds * 1000)" }
        XCTAssertEqual(value(context, "formatUptime(\(start), \(at(42)))"), "42 s")
        XCTAssertEqual(value(context, "formatUptime(\(start), \(at(12 * 60 + 59)))"), "12 min")
        XCTAssertEqual(value(context, "formatUptime(\(start), \(at(3 * 3600)))"), "3 h")
        XCTAssertEqual(value(context, "formatUptime(\(start), \(at(3 * 3600 + 5 * 60)))"), "3 h 5 min")
        XCTAssertEqual(value(context, "formatUptime(\(start), \(at(2 * 86400 + 4 * 3600 + 59)))"), "2 d 4 h")
        XCTAssertEqual(value(context, "formatUptime(\(start), \(at(-5)))"), "0 s", "a clock a little behind the server's")
        XCTAssertEqual(value(context, "formatUptime(null, 0)"), "")
    }

    func testPathsUnderHomeReadAsAShellWritesThem() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "tildePath('/Users/x/Library/Caches/SimTool/h', '/Users/x')"), "~/Library/Caches/SimTool/h")
        XCTAssertEqual(value(context, "tildePath('/Users/xy/tool', '/Users/x')"), "/Users/xy/tool")
        XCTAssertEqual(value(context, "tildePath('/opt/homebrew/bin/simtool', '/Users/x')"), "/opt/homebrew/bin/simtool")
        XCTAssertEqual(value(context, "tildePath('', '/Users/x')"), "")
    }

    // Under a name: where a SimTool binary runs from, a helper's image with its
    // version — the one a simctl spawn runs, for that — and nothing for a child.
    func testTheLineUnderANameSaysWhereItRunsFrom() throws {
        let context = try makeContext()
        let helpers = "/Users/x/Library/Caches/SimTool/SimulatorHelpers"
        XCTAssertEqual(value(context, "processImageLine({ kind: 'server', executable: '/Users/x/w/SimTool/Tool/.build/debug/simtool' }, '/Users/x')"), "~/w/SimTool/Tool/.build/debug/simtool")
        XCTAssertEqual(value(context, "processImageLine({ kind: 'reaper', executable: '/opt/homebrew/Cellar/simtool/0.13.0/bin/simtool' }, '/Users/x')"), "/opt/homebrew/Cellar/simtool/0.13.0/bin/simtool")
        XCTAssertEqual(value(context, "processImageLine({ kind: 'helper', executable: '\(helpers)/simtool-direct-hid-7-2ec7-arm64' }, '/Users/x')"), "simtool-direct-hid-7-2ec7-arm64")
        XCTAssertEqual(value(context, "processImageLine({ kind: 'helper', executable: '/Library/CoreSimulator/bin/simctl', arguments: ['spawn', 'UDID', '\(helpers)/simtool-fold-1-a1b1-arm64'] }, '/Users/x')"), "simtool-fold-1-a1b1-arm64")
        XCTAssertEqual(value(context, "processImageLine({ kind: 'child', executable: '/Library/CoreSimulator/bin/simctl' }, '/Users/x')"), "")
    }

    func testAGroupIsHeadedByItsPortSimulatorAndProject() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(processGroupHeading(list.groups[1], list))"),
                       #"{"title":"Server :3252","detail":"iPhone 17 · ~/Workspace/app","self":true}"#)
        XCTAssertEqual(value(context, "JSON.stringify(processGroupHeading(list.groups[2], list))"),
                       #"{"title":"Server :3300","detail":"AAF7EA49-5B67-4042-A2D2-32152E9D10E7 · /tmp/elsewhere","self":false}"#,
                       "no session: the --port it was started with, its working directory")
        XCTAssertEqual(value(context, "processGroupHeading(list.groups[0], list).title"), "Orphans")
        XCTAssertEqual(value(context, "processGroupHeading(list.groups[3], list).title"), "Not under a server")
    }

    func testDepthFollowsWhomAProcessRunsFor() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "list.groups[0].processes.map(function (p) { return processDepth(p, list.groups[0].processes); }).join()"), "0,1")
        XCTAssertEqual(value(context, "list.groups[3].processes.map(function (p) { return processDepth(p, list.groups[3].processes); }).join()"), "0,0,1")
    }

    // This page's own server, another server, a command and the reaper ask
    // first; a helper, a child and an orphan stop at once.
    func testAStopAsksOnlyWhereSomeoneMayBeUsingIt() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "processKillQuestion(find(500), list, '3252').title"), "Stop this viewer's server?")
        XCTAssertEqual(value(context, "processKillQuestion(find(500), list, '3252').self"), "true")
        XCTAssertEqual(value(context, "processKillQuestion(find(600), list, '3300').title"), "Stop the server on :3300?")
        XCTAssertEqual(value(context, "processKillQuestion(find(600), list, '3300').self"), "false")
        XCTAssertEqual(value(context, "processKillQuestion(find(701), list).title"), "Stop simtool test run?")
        XCTAssertEqual(value(context, "processKillQuestion(find(700), list).title"), "Stop the reaper?")
        for pid in [103, 104, 501, 702] {
            XCTAssertEqual(value(context, "processKillQuestion(find(\(pid)), list)"), "null", "PID \(pid)")
        }
    }

    func testAStopSaysWhatItDid() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "processKillMessage({ pid: 5, name: 'simtool serve', result: 'stopped', alongside: [6, 7] })"),
                       "Stopped simtool serve (PID 5) and 2 processes running for it")
        XCTAssertEqual(value(context, "processKillMessage({ pid: 8, name: 'fold helper', result: 'killed', alongside: [] })"),
                       "Killed fold helper (PID 8): it did not stop on SIGTERM")
        XCTAssertEqual(value(context, "processKillMessage({ pid: 9, name: 'direct-hid helper', result: 'gone' })"), "direct-hid helper (PID 9) had exited already")
        XCTAssertEqual(value(context, "processKillMessage({ pid: 500, name: 'simtool serve', result: 'stopping' })"), "simtool serve (PID 500) is stopping")
    }

    // Memory and CPU as Activity Monitor writes them: 100% is one core.
    func testMemoryAndCPUReadAsActivityMonitorWritesThem() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "formatMemory(8.2 * 1048576)"), "8.2 MB")
        XCTAssertEqual(value(context, "formatMemory(812 * 1048576)"), "812 MB")
        XCTAssertEqual(value(context, "formatMemory(999.7 * 1048576)"), "0.98 GB")
        XCTAssertEqual(value(context, "formatMemory(1.24 * 1073741824)"), "1.24 GB")
        XCTAssertEqual(value(context, "formatMemory(24 * 1073741824)"), "24.0 GB")
        XCTAssertEqual(value(context, "formatMemory(null)"), "—")
        XCTAssertEqual(value(context, "formatMemoryTotal(8 * 1073741824)"), "8 GB")
        XCTAssertEqual(value(context, "formatCpu(1.35)"), "135%")
        XCTAssertEqual(value(context, "formatCpu(0.045)"), "4.5%")
        XCTAssertEqual(value(context, "formatCpu(0)"), "0.0%")
        XCTAssertEqual(value(context, "formatCpu(null)"), "—", "no second reading yet")
    }

    // The Mac's bars: used and busy, with the simulators' part — every
    // simulator and CoreSimulator's processes on the Mac — never more than the whole.
    func testTheMacsBarsShowTheSimulatorsPartOfWhatIsUsed() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var mac = { cores: 8, cpu: 0.5, memory: 8 * 1073741824, memoryUsed: 6 * 1073741824,
          simulators: [{ usage: { memory: 1073741824, cpu: 1.5 } }, { usage: { memory: 1073741824, cpu: 0.5 } }],
          simulatorServices: { processes: 6, usage: { memory: 1073741824, cpu: 0.5 } } };
        var shares = machineShares(mac);
        """)
        XCTAssertEqual(value(context, "shares.memoryUsed"), "0.75")
        XCTAssertEqual(value(context, "shares.memorySimulators"), "0.375")
        XCTAssertEqual(value(context, "shares.simulatorMemory"), "\(3 << 30)")
        XCTAssertEqual(value(context, "shares.cpuBusy"), "0.5")
        XCTAssertEqual(value(context, "shares.cpuSimulators"), "0.3125")
        XCTAssertEqual(value(context, "shares.simulatorCores"), "2.5")
        // The simulators' footprint can count what the Mac files elsewhere: the bar stays inside what is used.
        XCTAssertEqual(value(context, "machineShares({ cores: 8, cpu: 0.1, memory: 100, memoryUsed: 50, simulators: [{ usage: { memory: 80, cpu: 4 } }] }).memorySimulators"), "0.5")
        XCTAssertEqual(value(context, "machineShares({ cores: 8, cpu: 0.1, memory: 100, memoryUsed: 50, simulators: [{ usage: { memory: 80, cpu: 4 } }] }).cpuSimulators"), "0.1")
        // Before a second reading there is no CPU to show.
        XCTAssertEqual(value(context, "machineShares({ cores: 8, memory: 100, memoryUsed: 50, simulators: [{ usage: { memory: 10 } }] }).cpuBusy"), "null")
        XCTAssertEqual(value(context, "machineShares({ cores: 8, memory: 100, memoryUsed: 50, simulators: [{ usage: { memory: 10 } }] }).simulatorCores"), "null")
    }

    // Which server holds each simulator, and the order they are listed in:
    // this viewer's first, then those SimTool serves, then the rest.
    func testSimulatorsAreListedWithTheirServersThisViewersFirst() throws {
        let context = try makeContext()
        context.evaluateScript("""
        list.groups[1].session.device.udid = "11111111-0000-0000-0000-000000000001";
        var servers = simulatorServers(list);
        var order = orderedSimulators([
          { udid: "33333333-0000-0000-0000-000000000003", name: "CI" },
          { udid: "AAF7EA49-5B67-4042-A2D2-32152E9D10E7", name: "Other" },
          { udid: "11111111-0000-0000-0000-000000000001", name: "Mine" },
          { pid: 9, name: "Unknown" }
        ], servers, "11111111-0000-0000-0000-000000000001");
        """)
        XCTAssertEqual(value(context, "servers['11111111-0000-0000-0000-000000000001'][0].port"), "3252")
        XCTAssertEqual(value(context, "servers['11111111-0000-0000-0000-000000000001'][0].self"), "true")
        XCTAssertEqual(value(context, "servers['AAF7EA49-5B67-4042-A2D2-32152E9D10E7'][0].port"), "3300", "a server without a session goes by its --device")
        XCTAssertEqual(value(context, "servers['AAF7EA49-5B67-4042-A2D2-32152E9D10E7'][0].self"), "false")
        XCTAssertEqual(value(context, "order.map(function (s) { return s.name; }).join()"), "Mine,Other,CI,Unknown")
    }
}
