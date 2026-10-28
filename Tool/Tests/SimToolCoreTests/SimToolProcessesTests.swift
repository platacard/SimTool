import Darwin
import Foundation
@testable import SimToolCore
import XCTest

// The process list: which processes are SimTool's, whom each runs for, which
// leaked — and that only those are ever stopped.
final class SimToolProcessDiscoveryTests: XCTestCase {
    static let helpers = "/Users/x/Library/Caches/SimTool/SimulatorHelpers"
    static let hid = helpers + "/simtool-direct-hid-7-2ec7d869e3ed-arm64"
    static let fold = helpers + "/simtool-fold-1-a1b194642b79-arm64"
    static let simctl = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
    static let udid = "AAF7EA49-5B67-4042-A2D2-32152E9D10E7"
    static let otherUDID = "23A4D356-616F-4EE5-AB48-82535AA64DEA"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func record(_ pid: Int32, _ ppid: Int32, _ executable: String, _ arguments: [String] = [], at offset: TimeInterval = 0, directory: String? = nil) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: ppid, executable: executable, arguments: [executable] + arguments, startedAt: start.addingTimeInterval(offset), directory: directory)
    }

    static func session(pid: Int32, udid: String = udid, port: Int = 3252, at offset: TimeInterval = 1) -> SessionInfo {
        SessionInfo(
            sessionId: "S-\(pid)",
            pid: pid,
            device: SimulatorDevice(udid: udid, name: "iPhone \(pid)", runtime: "iOS", state: "Booted", isAvailable: true),
            url: "http://127.0.0.1:\(port)",
            api: "http://127.0.0.1:\(port)/api/v1",
            startedAt: start.addingTimeInterval(offset),
            projectRoot: "/Users/x/Workspace/app"
        )
    }

    /// A machine as it looks with a server on a foldable: its HID helper, its
    /// log stream, the `simctl spawn` of the fold helper and the helper inside
    /// the simulator, under the simulator's launchd_sim.
    static let foldableServer: [ProcessRecord] = [
        record(100, 1, "/Users/x/SimTool/.build/debug/simtool", ["serve", "--port", "3252", "--device", udid]),
        record(101, 100, hid, [udid], at: 5),
        record(102, 100, simctl, ["spawn", udid, "log", "stream", "--level", "info"], at: 3),
        record(103, 100, simctl, ["spawn", udid, fold], at: 4),
        record(90, 1, "/Library/Developer/CoreSimulator/Volumes/iOS/RuntimeRoot/sbin/launchd_sim", ["/Users/x/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"], at: -10),
        record(104, 90, fold, [], at: 4, directory: "/Users/x/Library/Developer/CoreSimulator/Devices/\(udid)/data"),
    ]

    func list(_ records: [ProcessRecord], sessions: [SessionInfo] = [], ownPID: Int32 = 100, now: Date = start.addingTimeInterval(3_600)) -> SimToolProcessList {
        SimToolProcessDiscovery.list(records: records, sessions: sessions, helpersDirectory: Self.helpers, ownPID: ownPID, home: "/Users/x", now: now)
    }

    func testAServerIsListedWithEverythingItRunsInsideAndOutsideItsSimulator() throws {
        let list = list(Self.foldableServer, sessions: [Self.session(pid: 100)])

        XCTAssertEqual(list.groups.map(\.kind), [.server])
        let group = try XCTUnwrap(list.groups.first)
        XCTAssertEqual(group.session?.sessionId, "S-100")
        XCTAssertEqual(group.processes.map(\.pid), [100, 102, 103, 104, 101], "the server, then what runs for it by start, a spawned helper under its simctl spawn")
        XCTAssertEqual(group.processes.map(\.kind), [.server, .child, .helper, .helper, .helper])
        XCTAssertEqual(group.processes.map(\.name), ["simtool serve", "simctl spawn log stream", "simctl spawn · fold helper", "fold helper", "direct-hid helper"])
        XCTAssertEqual(list.process(pid: 104)?.owner, 103, "the helper inside the simulator runs for its simctl spawn")
        XCTAssertEqual(list.process(pid: 104)?.deviceUDID, Self.udid, "read from its launchd_sim")
        XCTAssertEqual(list.process(pid: 101)?.owner, 100)
        XCTAssertEqual(Set(group.processes.compactMap(\.sessionId)), ["S-100"])
        XCTAssertEqual(group.processes.map(\.deviceName), Array(repeating: "iPhone 100", count: 5), "the session names the simulator for all of them")
        XCTAssertFalse(list.processes.contains(where: \.orphan))
        XCTAssertNil(list.process(pid: 90), "a simulator's launchd_sim is not SimTool's")
        XCTAssertEqual(list.descendants(of: 100).map(\.pid).sorted(), [101, 102, 103, 104])
    }

    // A SIGKILLed server leaves its helpers behind: reparented to launchd, or a
    // simctl spawn whose helper still runs in the simulator. Nothing stops them.
    func testHelpersWhoseServerIsGoneAreOrphans() throws {
        let leftBehind = Self.foldableServer
            .filter { $0.pid != 100 && $0.pid != 102 }
            .map { record -> ProcessRecord in
                var record = record
                if record.ppid == 100 { record.ppid = 1 }
                return record
            }
        let list = list(leftBehind)

        XCTAssertEqual(list.groups.map(\.kind), [.orphans])
        XCTAssertEqual(list.orphans, 3)
        XCTAssertEqual(Set(list.processes.filter(\.orphan).map(\.pid)), [101, 103, 104])
        XCTAssertEqual(list.orphanRoots.map(\.pid).sorted(), [101, 103], "the spawned helper goes with its simctl spawn")
        XCTAssertEqual(list.process(pid: 104)?.note, "The simctl spawn it runs under has lost its server.")
        XCTAssertNil(list.process(pid: 101)?.sessionId)

        let withoutSpawn = self.list(leftBehind.filter { $0.pid != 103 })
        XCTAssertEqual(withoutSpawn.process(pid: 104)?.orphan, true, "a helper in the simulator with no simctl spawn left")
        XCTAssertEqual(withoutSpawn.process(pid: 104)?.note, "Its server or command is gone, and nothing will stop it.")
    }

    // A helper a command started runs for that command, not as an orphan, and
    // the command, the reaper and their helpers sit outside every server.
    func testCommandsAndTheReaperAreListedApartFromTheServers() throws {
        let records = [
            Self.record(200, 50, "/opt/homebrew/Cellar/simtool/0.13.0/bin/simtool", ["app", "launch", "--device", Self.otherUDID, "--scheme", "App"]),
            Self.record(201, 200, Self.hid, [Self.otherUDID], at: 2),
            Self.record(202, 200, "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", ["-scheme", "App", "build"], at: 1),
            Self.record(300, 1, "/tmp/build/debug/simtool", ["reap", "--watch"], at: -60),
            Self.record(50, 1, "/bin/zsh", ["-c", "simtool app launch"], at: -100),
        ]
        let list = list(records, ownPID: 999)

        XCTAssertEqual(list.groups.map(\.kind), [.other])
        XCTAssertEqual(list.groups[0].processes.map(\.pid), [300, 200, 202, 201])
        XCTAssertEqual(list.process(pid: 300)?.kind, .reaper)
        XCTAssertEqual(list.process(pid: 200)?.name, "simtool app launch")
        XCTAssertEqual(list.process(pid: 200)?.deviceUDID, Self.otherUDID)
        XCTAssertEqual(list.process(pid: 201)?.owner, 200)
        XCTAssertEqual(list.process(pid: 201)?.orphan, false)
        XCTAssertEqual(list.process(pid: 202)?.kind, .child)
        XCTAssertEqual(list.process(pid: 202)?.name, "xcodebuild")
        XCTAssertNil(list.process(pid: 50), "the shell that ran it is not SimTool's")
    }

    // Servers from any binary: this one first, then the newest. One the
    // registry does not know is still a server — with a word about it.
    func testEveryServerIsAGroupThisOneFirst() throws {
        let records = [
            Self.record(400, 1, "/opt/homebrew/Cellar/simtool/0.13.0/bin/simtool", ["serve", "--port", "3204"], at: 0),
            Self.record(401, 1, "/Users/x/a/SimTool/Tool/.build/release/simtool", ["serve", "--port", "3214"], at: 100),
            Self.record(402, 1, "/Users/x/b/SimTool/Tool/.build/debug/simtool", ["run"], at: 200),
            Self.record(403, 1, "/Users/x/c/SimTool/Tool/.build/debug/simtool", ["serve", "--port", "3300", "--device", Self.otherUDID], at: 300),
        ]
        let sessions = [Self.session(pid: 400, port: 3204, at: 1), Self.session(pid: 401, port: 3214, at: 101), Self.session(pid: 402, port: 3220, at: 201)]
        let list = list(records, sessions: sessions, ownPID: 401)

        XCTAssertEqual(list.groups.map { $0.processes.first?.pid }, [401, 403, 402, 400])
        XCTAssertEqual(list.groups.map(\.session?.sessionId), ["S-401", nil, "S-402", "S-400"])
        XCTAssertEqual(list.process(pid: 402)?.name, "simtool run", "a run hosting a viewer is a server when its session says so")
        XCTAssertEqual(list.process(pid: 400)?.directory, "/Users/x/Workspace/app")
        XCTAssertEqual(list.process(pid: 403)?.deviceUDID, Self.otherUDID)
        XCTAssertEqual(list.process(pid: 403)?.note, "Not in SimTool's session registry: simtool sessions and simtool kill do not see it.")
        XCTAssertNil(list.process(pid: 401)?.note)
    }

    // A session file outlives its server; a PID taken by a process that
    // started later is not that server.
    func testASessionCountsOnlyForTheProcessThatWroteIt() {
        let records = [Self.record(500, 1, "/usr/local/bin/simtool", ["test", "run", "smoke.yaml"], at: 600)]
        let list = list(records, sessions: [Self.session(pid: 500, at: 1)], ownPID: 1)
        XCTAssertEqual(list.process(pid: 500)?.kind, .command)
        XCTAssertNil(list.process(pid: 500)?.sessionId)
        XCTAssertEqual(list.process(pid: 500)?.name, "simtool test run")
    }

    // Only SimTool's own images: a helper-looking name elsewhere, a simctl
    // spawn of anything else, a binary that merely contains "simtool".
    func testOnlySimToolsOwnImagesAreListed() {
        let records = [
            Self.record(600, 1, "/tmp/simtool-direct-hid-7-abc-arm64", [Self.udid]),
            Self.record(601, 1, Self.simctl, ["spawn", Self.udid, "log", "stream"]),
            Self.record(602, 1, "/usr/local/bin/simtoolkit", ["serve"]),
            Self.record(603, 1, Self.helpers + "/notes.txt"),
            Self.record(604, 1, "/usr/bin/python3", ["-c", "print('simtool serve')"]),
        ]
        XCTAssertTrue(list(records, ownPID: 1).processes.isEmpty)
    }

    func testTheCommandAskingIsNotInItsOwnList() {
        let records = [Self.record(700, 1, "/opt/homebrew/bin/simtool", ["ps", "--json"])]
        XCTAssertTrue(list(records, ownPID: 700).processes.isEmpty)
        XCTAssertEqual(list(records, ownPID: 1).process(pid: 700)?.name, "simtool ps")
    }

    func testHelperNamesAreTheWordsBeforeTheVersion() {
        XCTAssertEqual(SimToolProcessDiscovery.helperName(Self.hid), "direct-hid helper")
        XCTAssertEqual(SimToolProcessDiscovery.helperName(Self.fold), "fold helper")
        XCTAssertEqual(SimToolProcessDiscovery.helperName(Self.helpers + "/simtool-accessibility-3-9f8e7d6c5b4a-arm64"), "accessibility helper")
    }

    // The table comes from the kernel, not from `ps`: a process named like a
    // SimTool helper is read with its real path, its argv as it got it — a
    // space inside an argument stays inside — its parent and when it started.
    func testTheProcessTableReadsThisUsersProcessesFromTheKernel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simtool table \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("simtool-table-test")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: image)
        let named = Process()
        named.executableURL = image
        named.arguments = ["30", "two words"]
        named.currentDirectoryURL = directory
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try named.run()
        try other.run()
        defer {
            named.terminate()
            other.terminate()
        }
        let before = Date()
        let table = ProcessTable.current()

        let record = try XCTUnwrap(table.first { $0.pid == named.processIdentifier })
        XCTAssertEqual(URL(fileURLWithPath: record.executable).resolvingSymlinksInPath(), image.resolvingSymlinksInPath())
        XCTAssertEqual(record.arguments, [image.path, "30", "two words"])
        XCTAssertEqual(record.ppid, getpid())
        XCTAssertEqual(record.directory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }, directory.resolvingSymlinksInPath())
        XCTAssertLessThan(abs(try XCTUnwrap(record.startedAt).timeIntervalSince(before)), 30)
        XCTAssertEqual(record.startedAt, SessionInfo.startTime(pid: named.processIdentifier), "the moment the kill check compares with")
        XCTAssertFalse(table.contains { $0.pid == other.processIdentifier }, "a process neither SimTool's nor started by one is not read")
    }
}

final class SimToolProcessControlTests: XCTestCase {
    /// Signals sent, and which PIDs are still running: a process exits on the
    /// signals in `exitsOn`, or never.
    final class Machine: @unchecked Sendable {
        private let lock = NSLock()
        private var running: Set<Int32>
        private var exitsOn: [Int32: Int32]
        private(set) var sent: [(Int32, Int32)] = []
        private(set) var stoppedSessions: [String] = []
        private(set) var selfStops = 0

        init(running: Set<Int32>, exitsOn: [Int32: Int32] = [:]) {
            self.running = running
            self.exitsOn = exitsOn
        }

        func signal(_ pid: Int32, _ signal: Int32) {
            lock.withLock {
                sent.append((pid, signal))
                if signal == SIGKILL || exitsOn[pid] == signal { running.remove(pid) }
            }
        }

        func isRunning(_ pid: Int32) -> Bool { lock.withLock { running.contains(pid) } }
        func exit(_ pid: Int32) { _ = lock.withLock { running.remove(pid) } }
        func noteSession(_ id: String) { lock.withLock { stoppedSessions.append(id) } }
        func noteSelfStop() { lock.withLock { selfStops += 1 } }
        var signals: [String] { lock.withLock { sent.map { "\($0.0):\($0.1 == SIGTERM ? "TERM" : $0.1 == SIGKILL ? "KILL" : "\($0.1)")" } } }
    }

    func control(_ list: SimToolProcessList, _ machine: Machine, ownPID: Int32 = 1_000, sessionExits: Bool = true) -> SimToolProcessControl {
        SimToolProcessControl(
            list: { list },
            stopSession: { session in
                machine.noteSession(session.sessionId)
                machine.exit(session.pid)
                return sessionExits
            },
            stopSelf: { machine.noteSelfStop() },
            signal: { machine.signal($0, $1) },
            isRunning: { machine.isRunning($0) },
            startTime: { _ in SimToolProcessDiscoveryTests.start },
            pause: { _ in },
            ownPID: ownPID
        )
    }

    func discovered(_ records: [ProcessRecord], sessions: [SessionInfo] = [], ownPID: Int32 = 1_000) -> SimToolProcessList {
        SimToolProcessDiscovery.list(records: records.map { record in
            var record = record
            record.startedAt = SimToolProcessDiscoveryTests.start
            return record
        }, sessions: sessions, helpersDirectory: SimToolProcessDiscoveryTests.helpers, ownPID: ownPID)
    }

    // The allow-list: a PID the discovery does not call SimTool's is refused,
    // and nothing is signalled.
    func testAPidThatIsNotSimToolsIsRefused() async {
        let list = discovered(SimToolProcessDiscoveryTests.foldableServer)
        let machine = Machine(running: [90, 100, 101, 102, 103, 104, 4242])
        for pid: Int32 in [4242, 90, 1, 0, -1] {
            do {
                _ = try await control(list, machine).kill(pid: pid)
                XCTFail("PID \(pid) was not refused")
            } catch {
                XCTAssertEqual(error as? SimToolProcessControl.Refusal, .notSimTool(pid))
            }
        }
        XCTAssertTrue(machine.signals.isEmpty)
        XCTAssertTrue(machine.stoppedSessions.isEmpty)
    }

    // A server stops through its session — so it shuts its simulator down —
    // and what ran for it and outlived it is stopped after.
    func testAServerStopsThroughItsSessionAndTakesItsHelpers() async throws {
        let session = SimToolProcessDiscoveryTests.session(pid: 100, at: 0)
        let list = discovered(SimToolProcessDiscoveryTests.foldableServer, sessions: [session])
        let machine = Machine(running: [90, 100, 101, 102, 103, 104], exitsOn: [101: SIGTERM, 102: SIGTERM, 103: SIGTERM])
        let outcome = try await control(list, machine).kill(pid: 100)

        XCTAssertEqual(machine.stoppedSessions, ["S-100"])
        XCTAssertEqual(outcome.result, .stopped)
        XCTAssertEqual(outcome.alongside.sorted(), [101, 102, 103, 104])
        XCTAssertEqual(machine.signals, ["101:TERM", "102:TERM", "103:TERM", "104:TERM", "104:KILL"], "nearest first; the helper in the simulator would not go on SIGTERM")
        XCTAssertFalse(machine.signals.contains { $0.hasPrefix("90:") }, "the simulator's launchd_sim is never touched")
    }

    func testAServerThatHadToBeKilledSaysSo() async throws {
        let session = SimToolProcessDiscoveryTests.session(pid: 100, at: 0)
        let list = discovered([SimToolProcessDiscoveryTests.foldableServer[0]], sessions: [session])
        let outcome = try await control(list, Machine(running: [100]), sessionExits: false).kill(pid: 100)
        XCTAssertEqual(outcome.result, .killed)
    }

    // An orphan gets SIGTERM, then SIGKILL; one that exits on SIGTERM is left at that.
    func testAnOrphanGetsSigtermThenSigkill() async throws {
        let records = [SimToolProcessDiscoveryTests.record(101, 1, SimToolProcessDiscoveryTests.hid, [SimToolProcessDiscoveryTests.udid])]
        let list = discovered(records)
        XCTAssertEqual(list.process(pid: 101)?.orphan, true)

        let stubborn = Machine(running: [101])
        let killed = try await control(list, stubborn).kill(pid: 101)
        XCTAssertEqual(killed.result, .killed)
        XCTAssertEqual(stubborn.signals, ["101:TERM", "101:KILL"])

        let polite = Machine(running: [101], exitsOn: [101: SIGTERM])
        let stopped = try await control(list, polite).kill(pid: 101)
        XCTAssertEqual(stopped.result, .stopped)
        XCTAssertEqual(polite.signals, ["101:TERM"])

        let gone = Machine(running: [])
        let already = try await control(list, gone).kill(pid: 101)
        XCTAssertEqual(already.result, .gone)
        XCTAssertTrue(gone.signals.isEmpty, "a PID no longer running is not signalled: it may be someone else's next")
    }

    // A PID that now belongs to a process started at another moment is not the
    // one listed: nothing is sent to it.
    func testAPidReusedSinceTheListIsNotSignalled() async throws {
        let list = discovered([SimToolProcessDiscoveryTests.record(101, 1, SimToolProcessDiscoveryTests.hid)])
        let machine = Machine(running: [101])
        var reused = control(list, machine)
        reused.startTime = { _ in SimToolProcessDiscoveryTests.start.addingTimeInterval(30) }
        let outcome = try await reused.kill(pid: 101)
        XCTAssertEqual(outcome.result, .gone)
        XCTAssertTrue(machine.signals.isEmpty)
    }

    // The server asking stops itself only when confirmed — after it answers.
    func testTheProcessAskingStopsOnlyWhenConfirmed() async throws {
        let session = SimToolProcessDiscoveryTests.session(pid: 100, at: 0)
        let list = discovered(SimToolProcessDiscoveryTests.foldableServer, sessions: [session], ownPID: 100)
        let machine = Machine(running: [100, 101])
        do {
            _ = try await control(list, machine, ownPID: 100).kill(pid: 100)
            XCTFail("the own server was stopped without a confirmation")
        } catch {
            XCTAssertEqual(error as? SimToolProcessControl.Refusal, .ownProcess(100))
        }
        XCTAssertEqual(machine.selfStops, 0)

        let outcome = try await control(list, machine, ownPID: 100).kill(pid: 100, confirmingOwnProcess: true)
        XCTAssertEqual(outcome.result, .stopping)
        XCTAssertEqual(machine.selfStops, 1)
        XCTAssertTrue(machine.signals.isEmpty, "it stops itself; nothing is signalled from inside the request")
        XCTAssertTrue(machine.stoppedSessions.isEmpty)
    }

    // Kill all orphans: each orphan once — a spawned helper with its simctl
    // spawn — and nothing that has a server.
    func testKillingTheOrphansLeavesEverythingElse() async throws {
        let session = SimToolProcessDiscoveryTests.session(pid: 400, udid: SimToolProcessDiscoveryTests.otherUDID, at: 0)
        let records = SimToolProcessDiscoveryTests.foldableServer.filter { $0.pid != 100 && $0.pid != 102 }.map { record -> ProcessRecord in
            var record = record
            if record.ppid == 100 { record.ppid = 1 }
            return record
        } + [
            SimToolProcessDiscoveryTests.record(400, 1, "/opt/homebrew/bin/simtool", ["serve"]),
            SimToolProcessDiscoveryTests.record(401, 400, SimToolProcessDiscoveryTests.hid, [SimToolProcessDiscoveryTests.otherUDID]),
        ]
        let list = discovered(records, sessions: [session])
        let machine = Machine(running: [90, 101, 103, 104, 400, 401], exitsOn: [101: SIGTERM, 103: SIGTERM, 104: SIGTERM])
        let outcomes = await control(list, machine).killOrphans()

        XCTAssertEqual(outcomes.map(\.pid), [101, 103])
        XCTAssertEqual(outcomes.first { $0.pid == 103 }?.alongside, [104])
        XCTAssertEqual(Set(machine.signals), ["101:TERM", "103:TERM", "104:TERM"])
        XCTAssertTrue(machine.isRunning(400) && machine.isRunning(401))
        XCTAssertTrue(machine.stoppedSessions.isEmpty)
    }

    func testRefusalsSayWhatSimToolStops() {
        XCTAssertEqual(
            SimToolProcessControl.Refusal.notSimTool(42).localizedDescription,
            "PID 42 is not a SimTool process. SimTool stops only its own servers, helpers and commands — see simtool ps."
        )
        XCTAssertTrue(SimToolProcessControl.Refusal.ownProcess(7).localizedDescription.hasPrefix("PID 7 is the server this request went to. Confirm"))
    }
}
