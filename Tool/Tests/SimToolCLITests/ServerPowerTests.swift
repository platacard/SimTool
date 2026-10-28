import Foundation
import XCTest
@testable import SimToolCLI
@testable import SimToolCore
import SimToolServer

// A server's simulator goes off when nobody uses it and the server stays up:
// it takes on a boot SimTool starts elsewhere, starts it when asked, and says
// why it is off — with simctl and the process table played by `World`.
final class ServerPowerTests: XCTestCase {
    private let device = SimulatorDevice(udid: "AAAA-1111", name: "SimTool-power", runtime: "iOS", state: "Booted", isAvailable: true)
    private var root: URL!
    private var store: SimulatorLeaseStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("simtool-power-\(UUID().uuidString)")
        store = SimulatorLeaseStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The simulator, simctl and the session file as the server sees them.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var _bootPID: Int32?
        private var _running: Set<Int32> = []
        private var _boots = 0
        private var _asleep: [Bool] = []
        private var _released = 0
        var bootDelay: TimeInterval = 0
        var bootFailure: String?
        var release: SimulatorLeaseSweep.Outcome.Action = .shutDown
        var releaseReason: String?
        /// What the flag, the environment and the config say now.
        var timeout: TimeInterval? = 0.2
        var timeoutUnreadable = false

        var bootPID: Int32? {
            get { lock.withLock { _bootPID } }
            set { lock.withLock { _bootPID = newValue; if let newValue { _running.insert(newValue) } } }
        }
        var boots: Int { lock.withLock { _boots } }
        var asleep: [Bool] { lock.withLock { _asleep } }
        var released: Int { lock.withLock { _released } }

        func stop(_ pid: Int32) { lock.withLock { _ = _running.remove(pid); if _bootPID == pid { _bootPID = nil } } }
        func isRunning(_ pid: Int32) -> Bool { lock.withLock { _running.contains(pid) } }
        func booted() { lock.withLock { _boots += 1 } }
        func mark(_ asleep: Bool) { lock.withLock { _asleep.append(asleep) } }
        func noteRelease() { lock.withLock { _released += 1 } }
    }

    private func effects(_ world: World, store: SimulatorLeaseStore) -> ServerPower.Effects {
        ServerPower.Effects(
            bootPID: { _ in world.bootPID },
            isRunning: { world.isRunning($0) },
            externalUse: { _ in nil },
            release: { udid, _ in
                world.noteRelease()
                guard let lease = store.lease(udid: udid) else { return nil }
                if world.release == .shutDown {
                    store.remove(udid: udid)
                    if let pid = world.bootPID { world.stop(pid) }
                }
                return SimulatorLeaseSweep.Outcome(udid: udid, name: lease.name, action: world.release, reason: world.releaseReason, idleSeconds: 0, idleTimeout: 0)
            },
            resolve: { [device] _ in device },
            boot: { device, _ in
                world.booted()
                if world.bootDelay > 0 { try await Task.sleep(for: .seconds(world.bootDelay)) }
                if let failure = world.bootFailure { throw SimToolError(failure) }
                if world.bootPID == nil { world.bootPID = 500 + Int32(world.boots) }
                return device
            },
            adopt: { device, timeout in store.take(device, booted: false, bootPID: world.bootPID, idleTimeout: timeout) },
            ensureReaper: {},
            markAsleep: { world.mark($0) },
            idleTimeout: {
                if world.timeoutUnreadable { throw SimToolError("config.yml: not YAML") }
                return world.timeout
            }
        )
    }

    private func server() -> StreamServer {
        StreamServer(config: StreamServerConfig(port: 1, device: device, captureEnabled: false))
    }

    /// A server on boot 100, its lease unused for longer than its timeout.
    private func idleServer(_ world: World) async throws -> (StreamServer, ServerPower) {
        world.bootPID = 100
        let server = server()
        store.take(device, booted: true, bootPID: 100, idleTimeout: 0.2)
        let power = ServerPower(server: server, device: device, bootPID: 100, idleTimeout: 0.2, store: store, effects: effects(world, store: store))
        try await Task.sleep(for: .milliseconds(300))
        return (server, power)
    }

    func testAnUnusedSimulatorIsShutDownAndTheServerStaysUp() async throws {
        let world = World()
        let (server, power) = try await idleServer(world)
        await power.check()
        XCTAssertEqual(world.released, 1)
        XCTAssertEqual(server.powerState.state, .off)
        XCTAssertEqual(server.powerState.reason, "idle")
        XCTAssertEqual(server.powerState.title, "Shut down after 0 s unused")
        XCTAssertEqual(world.asleep, [true], "the session file says so before it goes")
        XCTAssertNil(store.lease(udid: device.udid))
        let held = await power.bootPID
        XCTAssertNil(held)
    }

    // A command's lazy boot, another server's: SimTool's, so taken on.
    func testABootSimToolStartsElsewhereIsTakenOn() async throws {
        let world = World()
        let (server, power) = try await idleServer(world)
        await power.check()
        await power.check()
        XCTAssertEqual(world.boots, 0, "nothing booted it")

        world.bootPID = 200
        store.take(device, booted: true, bootPID: 200)
        await power.check()
        XCTAssertEqual(server.powerState, .on)
        XCTAssertEqual(world.asleep, [true, false])
        let held = await power.bootPID
        XCTAssertEqual(held, 200)
    }

    // Xcode, `simctl boot`: a server left running for days must not take a
    // person's run and shut it down later. It says the simulator is on, and
    // Start takes it on.
    func testABootOutsideSimToolWaitsForStart() async throws {
        let world = World()
        let (server, power) = try await idleServer(world)
        await power.check()
        world.bootPID = 200
        await power.check()
        await power.check()
        XCTAssertEqual(server.powerState.reason, "outside")
        XCTAssertEqual(server.powerState.title, "SimTool-power is on outside SimTool")
        XCTAssertNil(store.lease(udid: device.udid), "not SimTool's")

        try await power.start()
        XCTAssertEqual(server.powerState, .on)
        XCTAssertEqual(store.lease(udid: device.udid)?.bootPID, 200, "SimTool holds the boot it is on")
    }

    // A request that came in as the shutdown was decided keeps it on: nothing
    // is let go of.
    func testUsedAsItWasDecidedNothingIsLetGo() async throws {
        let world = World()
        world.bootPID = 100
        let port = try freePort()
        let server = StreamServer(config: StreamServerConfig(port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }
        store.take(device, booted: true, bootPID: 100, idleTimeout: 0.2)
        var effects = effects(world, store: store)
        effects.externalUse = { _ in
            // A command's request while `ps` is read.
            _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/v1/activity")!)
            return nil
        }
        let power = ServerPower(server: server, device: device, bootPID: 100, idleTimeout: 0.2, store: store, effects: effects)
        try await Task.sleep(for: .milliseconds(300))
        await power.check()
        XCTAssertEqual(world.released, 0)
        XCTAssertEqual(server.powerState, .on)
        let held = await power.bootPID
        XCTAssertEqual(held, 100)
    }

    // Another server still on the simulator keeps it up; this one lets go and
    // takes it on again only when asked, or once that boot is over.
    func testLeftToAnotherServerItWaitsForThatBootToEnd() async throws {
        let world = World()
        world.release = .kept
        world.releaseReason = "another SimTool server is on it"
        let (server, power) = try await idleServer(world)
        await power.check()
        XCTAssertEqual(server.powerState.reason, "released")
        XCTAssertEqual(server.powerState.detail, "SimTool-power stays on: another SimTool server is on it. Start to stream it here again.")

        await power.check()
        XCTAssertEqual(server.powerState.state, .off, "the boot it let go of")
        XCTAssertEqual(world.boots, 0)

        world.stop(100)
        await power.check()
        XCTAssertEqual(server.powerState.reason, "shutdown", "no longer saying it stays on")

        world.bootPID = 300
        store.take(device, booted: true, bootPID: 300)
        await power.check()
        XCTAssertEqual(server.powerState, .on)
    }

    // Used again as it was going: the boot is still the server's.
    func testUsedAsItWasGoingItStaysOn() async throws {
        let world = World()
        world.release = .inUse
        let (server, power) = try await idleServer(world)
        await power.check()
        XCTAssertEqual(server.powerState, .on)
        XCTAssertEqual(world.asleep, [true, false])
        let held = await power.bootPID
        XCTAssertEqual(held, 100)
    }

    // An `idleTimeout:` edited in the config: the running server takes it, a
    // config that does not read leaves the timeout it had.
    func testAnEditedTimeoutApplies() async throws {
        let world = World()
        world.bootPID = 100
        world.timeout = 600
        let server = server()
        store.take(device, booted: true, bootPID: 100, idleTimeout: 600)
        let power = ServerPower(server: server, device: device, bootPID: 100, idleTimeout: 600, store: store, effects: effects(world, store: store))
        let usedAt = store.lease(udid: device.udid)?.lastUsedAt

        world.timeoutUnreadable = true
        world.timeout = 120
        await power.check()
        XCTAssertEqual(store.lease(udid: device.udid)?.idleTimeout, 600, "a broken config changes nothing")

        world.timeoutUnreadable = false
        await power.check()
        XCTAssertEqual(store.lease(udid: device.udid)?.idleTimeout, 120)
        XCTAssertEqual(store.lease(udid: device.udid)?.lastUsedAt, usedAt, "a new timeout is not use")
        XCTAssertEqual(server.powerState, .on)

        world.timeout = 0.2
        try await Task.sleep(for: .milliseconds(300))
        await power.check()
        XCTAssertEqual(server.powerState.reason, "idle", "it goes by the new one")

        world.timeout = nil
        await power.check()
        let timeout = await power.idleTimeout
        XCTAssertNil(timeout, "the default again")
    }

    func testShutDownOutsideTheServerItGoesOff() async throws {
        let world = World()
        world.bootPID = 100
        let server = server()
        store.take(device, booted: true, bootPID: 100, idleTimeout: 60)
        let power = ServerPower(server: server, device: device, bootPID: 100, idleTimeout: 60, store: store, effects: effects(world, store: store))
        world.stop(100)
        await power.check()
        XCTAssertEqual(server.powerState.reason, "shutdown")
        XCTAssertEqual(server.powerState.title, "SimTool-power was shut down")
        XCTAssertNil(store.lease(udid: device.udid), "that boot is over")
        XCTAssertEqual(world.released, 0, "nothing to shut down")
    }

    func testEveryoneAskingWaitsForTheSameStart() async throws {
        let world = World()
        let (server, power) = try await idleServer(world)
        await power.check()
        world.bootDelay = 0.2
        async let first: Void = power.start()
        async let second: Void = power.start()
        async let third: Void = power.start()
        _ = try await (first, second, third)
        XCTAssertEqual(world.boots, 1)
        XCTAssertEqual(server.powerState, .on)
    }

    // A boot it could not take on is not tried again by itself every few
    // seconds; a Start, or another boot, is.
    func testAStartThatFailsStaysOffUntilTheNextBoot() async throws {
        let world = World()
        let (server, power) = try await idleServer(world)
        await power.check()
        // It booted, and then would not come up.
        world.bootPID = 350
        world.bootFailure = "Failed to boot simulator SimTool-power"
        do {
            try await power.start()
            XCTFail("it did not start")
        } catch {}
        XCTAssertEqual(server.powerState.reason, "failed")
        XCTAssertEqual(server.powerState.detail, "Failed to boot simulator SimTool-power")
        await power.check()
        XCTAssertEqual(world.boots, 1, "not on that boot again by itself")

        world.bootFailure = nil
        world.stop(350)
        world.bootPID = 400
        store.take(device, booted: true, bootPID: 400)
        await power.check()
        XCTAssertEqual(world.boots, 2, "a new boot is taken on")
        XCTAssertEqual(server.powerState, .on)
    }

    private func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return UInt16(bigEndian: address.sin_port)
    }

    func testWhatLettingGoEndsIn() {
        func outcome(_ action: SimulatorLeaseSweep.Outcome.Action) -> SimulatorLeaseSweep.Outcome {
            SimulatorLeaseSweep.Outcome(udid: "A", name: "A", action: action, reason: nil, idleSeconds: 0, idleTimeout: 0)
        }
        XCTAssertEqual(ServerPower.afterRelease(outcome(.shutDown), usedSince: false), .off)
        XCTAssertEqual(ServerPower.afterRelease(outcome(.released), usedSince: false), .off)
        XCTAssertEqual(ServerPower.afterRelease(outcome(.inUse), usedSince: false), .backOn)
        XCTAssertEqual(ServerPower.afterRelease(outcome(.kept), usedSince: true), .backOn)
        XCTAssertEqual(ServerPower.afterRelease(outcome(.kept), usedSince: false), .leftToOthers)
        XCTAssertEqual(ServerPower.afterRelease(nil, usedSince: false), .leftToOthers)
    }
}
