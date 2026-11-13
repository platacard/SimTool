import Darwin
import Foundation
@testable import SimToolCore
import XCTest

// What the Mac's memory and CPU go to: each simulator as its launchd_sim and
// everything under it, CoreSimulator's own processes on the Mac apart, SimTool's
// processes one by one — CPU always measured between two readings.
final class ResourceMonitorTests: XCTestCase {
    static let udid = "AAF7EA49-5B67-4042-A2D2-32152E9D10E7"
    static let otherUDID = "23A4D356-616F-4EE5-AB48-82535AA64DEA"
    static let devices = "/Users/x/Library/Developer/CoreSimulator/Devices/"
    static let framework = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/"
    static let boot = Date(timeIntervalSince1970: 1_800_000_000)

    /// A made-up Mac whose clock and CPU times move only when told to.
    final class Machine: @unchecked Sendable {
        struct Process {
            var ppid: Int32
            var name: String
            var executable: String?
            var arguments: [String]? = nil
            var startedAt: Date?
            var memory: UInt64
            /// Cores it keeps busy.
            var rate: Double = 0
            var cpuTime: UInt64 = 0
        }

        private let lock = NSLock()
        private var processes: [Int32: Process] = [:]
        private var clock: TimeInterval = 1000
        private var wall = ResourceMonitorTests.boot.addingTimeInterval(3600)
        private var ticks: [UInt32] = [1000, 1000, 1000, 0]
        /// The share of the whole Mac busy, for its ticks.
        var busy: Double = 0.25
        /// The kernel moves its tick counters in batches: for a while they may not move.
        var ticking = true
        var host = ResourceProbe.Host(name: "mini", cores: 8, ticks: [], load: 3.5, memory: 8 << 30, memoryUsed: 5 << 30, swapUsed: 1 << 29, pressure: .warning)
        private(set) var pauses = 0
        var devices: [String: ResourceProbe.Device] = [:]

        func add(_ pid: Int32, _ process: Process) { lock.withLock { processes[pid] = process } }
        func remove(_ pid: Int32) { lock.withLock { _ = processes.removeValue(forKey: pid) } }
        func set(_ pid: Int32, rate: Double) { lock.withLock { processes[pid]?.rate = rate } }
        func setTicks(_ value: [UInt32]) { lock.withLock { ticks = value } }

        /// Time passes: every process burns its rate, the Mac its ticks
        /// (100 a second a core).
        func advance(_ seconds: TimeInterval) {
            lock.withLock { step(seconds) }
        }

        /// The clock moves on to `target` unless it is there already: requests
        /// waiting together wake at the same moment, and a reading in between
        /// sees no time jump under it.
        func advance(to target: TimeInterval) {
            lock.withLock { if target > clock { step(target - clock) } }
        }

        private func step(_ seconds: TimeInterval) {
            clock += seconds
            wall = wall.addingTimeInterval(seconds)
            for pid in processes.keys { processes[pid]!.cpuTime += UInt64(processes[pid]!.rate * seconds * 1_000_000_000) }
            guard ticking else { return }
            let all = 100 * seconds * Double(host.cores)
            ticks[0] = ticks[0] &+ UInt32(all * busy * 0.6)
            ticks[1] = ticks[1] &+ UInt32(all * busy * 0.4)
            ticks[2] = ticks[2] &+ UInt32(all * (1 - busy))
        }

        var probe: ResourceProbe {
            ResourceProbe(
                processes: { self.lock.withLock { self.processes.map { ResourceProbe.Process(pid: $0.key, ppid: $0.value.ppid, name: $0.value.name, startedAt: $0.value.startedAt) } } },
                executable: { pid in self.lock.withLock { self.processes[pid]?.executable } },
                arguments: { pid in self.lock.withLock { self.processes[pid]?.arguments } },
                cost: { pid in self.lock.withLock { self.processes[pid].map { ResourceProbe.Cost(cpuTime: $0.cpuTime, memory: $0.memory) } } },
                host: { self.lock.withLock { var host = self.host; host.ticks = self.ticks; return host } },
                device: { directory in self.lock.withLock { self.devices[directory] } },
                uptime: { self.lock.withLock { self.clock } },
                now: { self.lock.withLock { self.wall } },
                pause: { duration in
                    let target = self.lock.withLock {
                        self.pauses += 1
                        return self.clock + Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                    }
                    // Another request may come in while this one waits.
                    await Task.yield()
                    self.advance(to: target)
                }
            )
        }
    }

    /// One simulator (launchd_sim 100: SpringBoard, an app with an extension
    /// under it), another one, CoreSimulator's render server and service,
    /// `simctl` run by someone, and an unrelated process.
    static func machine() -> Machine {
        let machine = Machine()
        machine.add(100, .init(ppid: 1, name: "launchd_sim", arguments: ["launchd_sim", devices + udid + "/data/var/run/launchd_bootstrap.plist"], startedAt: boot, memory: 10 << 20))
        machine.add(101, .init(ppid: 100, name: "SpringBoard", startedAt: boot, memory: 200 << 20, rate: 0.1))
        machine.add(102, .init(ppid: 100, name: "MyApp", startedAt: boot, memory: 400 << 20, rate: 0.5))
        machine.add(103, .init(ppid: 102, name: "MyAppWidget", startedAt: boot, memory: 30 << 20, rate: 0.2))
        machine.add(110, .init(ppid: 1, name: "launchd_sim", arguments: ["launchd_sim", devices + otherUDID + "/data/var/run/launchd_bootstrap.plist"], startedAt: boot, memory: 10 << 20))
        machine.add(111, .init(ppid: 110, name: "SpringBoard", startedAt: boot, memory: 100 << 20))
        machine.add(200, .init(ppid: 1, name: "SimRenderServer", executable: framework + "Resources/SimRenderingServices.simdeviceio/Contents/XPCServices/SimRenderServer.xpc/Contents/MacOS/SimRenderServer", startedAt: boot, memory: 300 << 20, rate: 0.4))
        machine.add(201, .init(ppid: 1, name: "com.apple.CoreSi", executable: framework + "XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService", startedAt: boot, memory: 10 << 20))
        machine.add(202, .init(ppid: 1, name: "simctl", executable: framework + "Resources/bin/simctl", startedAt: boot, memory: 5 << 20, rate: 1))
        machine.add(300, .init(ppid: 1, name: "Safari", executable: "/Applications/Safari.app/Contents/MacOS/Safari", startedAt: boot, memory: 900 << 20, rate: 1))
        machine.devices[devices + udid] = .init(name: "iPhone 17", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4")
        return machine
    }

    static let emptyList = SimToolProcessList(groups: [], pid: 1)

    func testASimulatorIsItsLaunchdSimAndEverythingUnderIt() async throws {
        let machine = Self.machine()
        let monitor = ResourceMonitor(probe: machine.probe)
        let reading1 = await monitor.annotate(Self.emptyList)

        let resources = try XCTUnwrap(reading1.machine)

        XCTAssertEqual(resources.simulators.map(\.pid), [110, 100], "by name; a simulator without a device.plist goes by its UDID")
        let phone = try XCTUnwrap(resources.simulators.first { $0.pid == 100 })
        XCTAssertEqual(phone.udid, Self.udid)
        XCTAssertEqual(phone.name, "iPhone 17")
        XCTAssertEqual(phone.runtime, "com.apple.CoreSimulator.SimRuntime.iOS-26-4")
        XCTAssertEqual(phone.bootedAt, Self.boot)
        XCTAssertEqual(phone.processes, 4, "the extension under the app counts too")
        XCTAssertEqual(phone.usage.memory, (10 + 200 + 400 + 30) << 20)
        XCTAssertEqual(try XCTUnwrap(phone.usage.cpu), 0.8, accuracy: 0.001)
        let other = try XCTUnwrap(resources.simulators.first { $0.pid == 110 })
        XCTAssertEqual(other.udid, Self.otherUDID)
        XCTAssertNil(other.name)
        XCTAssertEqual(other.processes, 2)

        let services = try XCTUnwrap(resources.simulatorServices)
        XCTAssertEqual(services.processes, 2, "the render server and the service — not simctl, not Safari")
        XCTAssertEqual(services.usage.memory, 310 << 20)
        XCTAssertEqual(try XCTUnwrap(services.usage.cpu), 0.4, accuracy: 0.001)
    }

    func testAKnownNameStandsInForAMissingDevicePlist() async throws {
        let machine = Self.machine()
        let monitor = ResourceMonitor(probe: machine.probe)
        let session = SessionInfo(
            sessionId: "s", pid: 500,
            device: SimulatorDevice(udid: Self.otherUDID.lowercased(), name: "SimTool Remote 2", runtime: "iOS 26.4", state: "Booted", isAvailable: true),
            url: "http://127.0.0.1:3270", api: "http://127.0.0.1:3270/api/v1", startedAt: Self.boot
        )
        let list = SimToolProcessList(groups: [.init(kind: .server, session: session, processes: [])], pid: 500)
        let reading2 = await monitor.annotate(list)

        let resources = try XCTUnwrap(reading2.machine)
        XCTAssertEqual(resources.simulators.first { $0.pid == 110 }?.name, "SimTool Remote 2")
    }

    func testTheMacsOwnFigures() async throws {
        let machine = Self.machine()
        let monitor = ResourceMonitor(probe: machine.probe)
        let reading3 = await monitor.annotate(Self.emptyList)

        let resources = try XCTUnwrap(reading3.machine)
        XCTAssertEqual(resources.name, "mini")
        XCTAssertEqual(resources.cores, 8)
        XCTAssertEqual(resources.memory, 8 << 30)
        XCTAssertEqual(resources.memoryUsed, 5 << 30)
        XCTAssertEqual(resources.swapUsed, 1 << 29)
        XCTAssertEqual(resources.pressure, .warning)
        XCTAssertEqual(resources.load, 3.5)
        XCTAssertEqual(try XCTUnwrap(resources.cpu), 0.25, accuracy: 0.01)
    }

    // The kernel's tick counters are 32 bits: a Mac up for weeks wraps them.
    func testTheMacsCPUSurvivesItsCountersWrapping() async throws {
        let machine = Self.machine()
        machine.setTicks([UInt32.max - 50, UInt32.max - 50, UInt32.max - 50, 0])
        machine.busy = 0.5
        let monitor = ResourceMonitor(probe: machine.probe)
        let reading4 = await monitor.annotate(Self.emptyList)

        let resources = try XCTUnwrap(reading4.machine)
        XCTAssertEqual(try XCTUnwrap(resources.cpu), 0.5, accuracy: 0.02)
    }

    // Counters that did not move in a short span give no figure rather than
    // 0 %; the Mac is measured over a second or more once a viewer polls.
    func testTheMacsCPUWaitsForItsCountersToMove() async throws {
        let machine = Self.machine()
        machine.ticking = false
        let monitor = ResourceMonitor(probe: machine.probe)
        let first = await monitor.annotate(Self.emptyList)
        XCTAssertNil(first.machine?.cpu)
        XCTAssertNotNil(first.machine?.simulators.first?.usage.cpu, "the processes' own CPU time does not wait")

        machine.ticking = true
        machine.busy = 0.5
        machine.advance(2)
        let second = await monitor.annotate(Self.emptyList)
        XCTAssertEqual(try XCTUnwrap(second.machine?.cpu), 0.5, accuracy: 0.02, "measured against the first reading's counters")
        machine.advance(2)
        let third = await monitor.annotate(Self.emptyList)
        XCTAssertEqual(try XCTUnwrap(third.machine?.cpu), 0.5, accuracy: 0.02)
    }

    func testSimToolsProcessesCarryWhatEachCosts() async throws {
        let machine = Self.machine()
        machine.add(500, .init(ppid: 1, name: "simtool", executable: "/opt/homebrew/bin/simtool", startedAt: Self.boot, memory: 40 << 20, rate: 0.15))
        let list = SimToolProcessList(groups: [.init(kind: .server, processes: [
            SimToolProcess(pid: 500, ppid: 1, kind: .server, name: "simtool serve", executable: "/opt/homebrew/bin/simtool"),
            SimToolProcess(pid: 999, ppid: 500, kind: .child, name: "gone", executable: "/usr/bin/log", owner: 500),
        ])], pid: 500)
        let monitor = ResourceMonitor(probe: machine.probe)
        let processes = await monitor.annotate(list).processes
        let server = try XCTUnwrap(processes.first?.usage)
        XCTAssertEqual(server.memory, 40 << 20)
        XCTAssertEqual(try XCTUnwrap(server.cpu), 0.15, accuracy: 0.001)
        XCTAssertNil(processes.last?.usage, "a process that is gone costs nothing it could say")
    }

    // CPU is a rate: the first reading looks twice, the next ones compare with
    // the last, and one after a long pause looks twice again.
    func testTheFirstReadingInAWhileLooksTwice() async throws {
        let machine = Self.machine()
        let monitor = ResourceMonitor(probe: machine.probe)
        _ = await monitor.annotate(Self.emptyList)
        XCTAssertEqual(machine.pauses, 1)

        machine.set(102, rate: 2)
        machine.advance(2)
        let reading5 = await monitor.annotate(Self.emptyList)

        let next = try XCTUnwrap(reading5.machine)
        XCTAssertEqual(machine.pauses, 1, "two seconds later the last reading is the comparison")
        XCTAssertEqual(try XCTUnwrap(next.simulators.first { $0.pid == 100 }?.usage.cpu), 2.3, accuracy: 0.001)

        machine.advance(ResourceMonitor.stale + 1)
        _ = await monitor.annotate(Self.emptyList)
        XCTAssertEqual(machine.pauses, 2)
    }

    // Two viewers asking at once — or a poll beside a click — both get CPU
    // measured over a quarter of a second at least, not over the moment between them.
    func testRequestsAtOnceEachMeasureCPUOverAQuarterSecond() async throws {
        let machine = Self.machine()
        let monitor = ResourceMonitor(probe: machine.probe)
        for _ in 0..<5 {
            async let first = monitor.annotate(Self.emptyList)
            async let second = monitor.annotate(Self.emptyList)
            async let third = monitor.annotate(Self.emptyList)
            for reading in await [first, second, third] {
                let resources = try XCTUnwrap(reading.machine)
                XCTAssertEqual(try XCTUnwrap(resources.simulators.first { $0.pid == 100 }?.usage.cpu), 0.8, accuracy: 0.001)
                XCTAssertEqual(try XCTUnwrap(resources.cpu), 0.25, accuracy: 0.02)
            }
        }
    }

    // A clock that does not move cannot hold a request forever: it reads as it is.
    func testAStoppedClockDoesNotHoldARequest() async throws {
        let probe = ResourceProbe(
            processes: { [] }, executable: { _ in nil }, arguments: { _ in nil }, cost: { _ in nil },
            host: { .init(name: "mini", cores: 8, ticks: [1, 1, 1, 0], load: 0, memory: 1, memoryUsed: 1, swapUsed: 0, pressure: .normal) },
            device: { _ in nil }, uptime: { 1000 }, pause: { _ in }
        )
        let reading = await ResourceMonitor(probe: probe).annotate(Self.emptyList)
        XCTAssertNotNil(reading.machine)
        XCTAssertNil(reading.machine?.cpu)
    }

    // A process that started since the last reading spent all its time in
    // between; one that took a PID with an earlier start than the reading
    // knew is not compared with the process that had it.
    func testNewProcessesCountFromTheirStart() async throws {
        let machine = Self.machine()
        let monitor = ResourceMonitor(probe: machine.probe)
        _ = await monitor.annotate(Self.emptyList)

        machine.remove(103)
        machine.advance(0.5)
        machine.add(103, .init(ppid: 102, name: "MyAppWidget", startedAt: Self.boot.addingTimeInterval(3600 + ResourceMonitor.shortest + 0.5), memory: 1 << 20, rate: 1))
        machine.add(101, .init(ppid: 100, name: "SpringBoard", startedAt: Self.boot.addingTimeInterval(10), memory: 1 << 20, rate: 3))
        machine.advance(0.5)
        let reading6 = await monitor.annotate(Self.emptyList)

        let resources = try XCTUnwrap(reading6.machine)
        // The app 0.5 a second; the new widget half a second of CPU; the other SpringBoard nothing it could be compared with.
        XCTAssertEqual(try XCTUnwrap(resources.simulators.first { $0.pid == 100 }?.usage.cpu), 1.0, accuracy: 0.001)
    }

    func testASimulatorsDeviceIsReadFromItsBootstrapPath() {
        XCTAssertEqual(ResourceMonitor.device(arguments: ["launchd_sim", Self.devices + Self.udid + "/data/var/run/launchd_bootstrap.plist"]).udid, Self.udid)
        XCTAssertEqual(ResourceMonitor.device(arguments: ["launchd_sim", Self.devices + Self.udid + "/data/var/run/launchd_bootstrap.plist"]).directory, Self.devices + Self.udid)
        // A test run's clone lives elsewhere.
        let clone = "/Users/x/Library/Developer/XCTestDevices/" + Self.otherUDID.lowercased()
        XCTAssertEqual(ResourceMonitor.device(arguments: ["launchd_sim", clone + "/data/var/run/launchd_bootstrap.plist"]).udid, Self.otherUDID)
        XCTAssertNil(ResourceMonitor.device(arguments: ["launchd_sim"]).udid)
        XCTAssertNil(ResourceMonitor.device(arguments: ["launchd_sim", "/tmp/elsewhere/data/x.plist"]).udid)
    }

    func testCoreSimulatorsServicesAreTheFrameworksAndSimulatorApp() {
        XCTAssertTrue(ResourceMonitor.isSimulatorService(Self.framework + "Resources/SimRenderingServices.simdeviceio/Contents/XPCServices/SimMetalHost.xpc/Contents/MacOS/SimMetalHost"))
        XCTAssertTrue(ResourceMonitor.isSimulatorService("/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"))
        XCTAssertFalse(ResourceMonitor.isSimulatorService(Self.framework + "Resources/bin/simctl"))
        XCTAssertFalse(ResourceMonitor.isSimulatorService("/usr/bin/log"))
    }

    // The Mac this runs on reads as a Mac: its memory, cores and a CPU share.
    func testTheLiveMacReadsAsAMac() async throws {
        let monitor = ResourceMonitor()
        let ownPID = getpid()
        let list = SimToolProcessList(groups: [.init(kind: .other, processes: [
            SimToolProcess(pid: ownPID, ppid: getppid(), kind: .command, name: "xctest", executable: CommandLine.arguments[0]),
        ])], pid: ownPID)
        _ = await monitor.annotate(list)
        // As a viewer polls: the Mac's counters move in batches, a second shows them moving.
        try await Task.sleep(for: .seconds(1))
        let annotated = await monitor.annotate(list)
        let resources = try XCTUnwrap(annotated.machine)
        XCTAssertEqual(resources.memory, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(resources.cores, 0)
        XCTAssertGreaterThan(resources.memoryUsed, 0)
        XCTAssertLessThanOrEqual(resources.memoryUsed, resources.memory)
        let cpu = try XCTUnwrap(resources.cpu)
        XCTAssertTrue((0...1.0001).contains(cpu), "\(cpu)")
        XCTAssertFalse(resources.name.isEmpty)
        let own = try XCTUnwrap(annotated.processes.first?.usage)
        XCTAssertGreaterThan(own.memory, 1 << 20)
        XCTAssertNotNil(own.cpu)
    }
}
