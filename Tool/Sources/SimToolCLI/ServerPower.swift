import Foundation
import SimToolCore
import SimToolServer

/// Keeps a server's simulator on while someone uses it and off while nobody
/// does — the server itself stays up. Every 15 seconds it renews SimTool's
/// lease on the simulator with the server's last use, or now while a run or a
/// recording is going. Once the lease has gone unused for its timeout it shuts
/// the simulator down — unless another SimTool server is still on it or
/// something outside SimTool uses it — and the server answers on with the
/// simulator off. It starts it again when asked: the viewer's Start, a request
/// that needs the device. A boot SimTool holds — a command's lazy boot,
/// another server's — it takes on by itself; one started outside SimTool —
/// Xcode, `simctl` — only on Start: a server left running for days must not
/// take a person's Xcode run and shut it down under them.
actor ServerPower {
    static let interval: Duration = .seconds(15)
    /// How soon a server with its simulator off sees a boot to take on.
    static let offInterval: Duration = .seconds(5)

    /// What it does to the world, so its decisions are tested without simctl.
    struct Effects: Sendable {
        /// The simulator's `launchd_sim` now: nil when it is not booted.
        var bootPID: @Sendable (String) async -> Int32?
        var isRunning: @Sendable (Int32) -> Bool
        /// Why something outside SimTool uses it right now.
        var externalUse: @Sendable (SimulatorDevice) async -> String?
        /// Lets go of it as its server would stopping: shuts it down unless
        /// another server or something else is on it, or it was used since.
        var release: @Sendable (_ udid: String, _ unusedSince: Date) async -> SimulatorLeaseSweep.Outcome?
        var resolve: @Sendable (String) async throws -> SimulatorDevice
        /// Boots it when it is not, under SimTool's lease.
        var boot: @Sendable (SimulatorDevice, TimeInterval?) async throws -> SimulatorDevice
        /// SimTool holds the boot the server is on, whoever started it.
        var adopt: @Sendable (SimulatorDevice, TimeInterval?) async -> SimulatorLease
        var ensureReaper: @Sendable () -> Void
        /// Says in the session file whether the server is off its simulator.
        var markAsleep: @Sendable (Bool) -> Void
        /// The idle timeout as it reads now: the flag, the environment, the
        /// config; nil for the default. Throws when the config does not read.
        var idleTimeout: @Sendable () throws -> TimeInterval?

        static func live(session: SessionInfo, idleTimeout: @escaping @Sendable () throws -> TimeInterval?) -> Effects {
            Effects(
                bootPID: { await SimulatorProcessSnapshot.take().bootPID(of: $0) },
                isRunning: { SessionInfo.isRunning(pid: $0) },
                externalUse: { await SimulatorProcessSnapshot.take().externalUse(of: $0) },
                release: { await SimulatorLeaseSweep().release(udid: $0, leaving: getpid(), unusedSince: $1) },
                resolve: { try await SimulatorDeviceClient.resolve($0) },
                boot: { try await SimulatorHold.boot($0, idleTimeout: $1) },
                adopt: { await SimulatorHold.adopt($0, idleTimeout: $1) },
                ensureReaper: { LeaseReaper.ensureRunning() },
                markAsleep: { asleep in
                    // Not after the server dropped it, stopping.
                    guard (try? SessionStore.shared.session(id: session.sessionId)) != nil else { return }
                    var session = session
                    session.asleep = asleep
                    try? SessionStore.shared.write(session)
                },
                idleTimeout: idleTimeout
            )
        }
    }

    let server: StreamServer
    let device: SimulatorDevice
    /// Nil for the default; an `idleTimeout:` edited in the config changes it.
    private(set) var idleTimeout: TimeInterval?
    let store: SimulatorLeaseStore
    let effects: Effects
    /// The `launchd_sim` of the boot the server streams.
    private(set) var bootPID: Int32?
    /// While off: a boot only a Start takes on — one the server left to
    /// another SimTool server, one it could not take on, one started outside
    /// SimTool.
    private var passedBoot: Int32?
    private var renewed = Date.distantPast
    /// Shutting it down; a Start waits for that to finish.
    private var settling: Task<Void, Never>?
    private var starting: Task<Void, Error>?

    init(
        server: StreamServer,
        device: SimulatorDevice,
        bootPID: Int32?,
        idleTimeout: TimeInterval?,
        store: SimulatorLeaseStore = .shared,
        effects: Effects
    ) {
        self.server = server
        self.device = device
        self.bootPID = bootPID
        self.idleTimeout = idleTimeout
        self.store = store
        self.effects = effects
    }

    var isOn: Bool {
        server.powerState.state == .on
    }

    /// Looks every few seconds until the server stops.
    func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: isOn ? Self.interval : Self.offInterval)
            await check()
        }
    }

    /// One look: renew the lease, shut the simulator down, or take on a boot.
    func check() async {
        refreshIdleTimeout()
        if isOn {
            await checkOn()
        } else if starting == nil, settling == nil {
            await checkOff()
        }
    }

    /// Starts the simulator, and returns once the server streams it. Asked
    /// again while it boots, it waits for the same boot.
    func start() async throws {
        if isOn { return }
        if let starting { return try await starting.value }
        let task = Task { try await self.performStart() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    /// An `idleTimeout:` edited in the config applies to the running server —
    /// unless `--idle-timeout` or `SIMTOOL_IDLE_TIMEOUT` set it, which win as
    /// they did when it started. A config that does not read keeps the last
    /// value. On, the server's lease takes it; off, the next start does.
    private func refreshIdleTimeout() {
        let fresh: TimeInterval?
        do { fresh = try effects.idleTimeout() } catch { return }
        guard fresh != idleTimeout else { return }
        idleTimeout = fresh
        let timeout = fresh ?? SimulatorIdleTimeout.defaultSeconds
        if isOn { store.setIdleTimeout(udid: device.udid, timeout) }
        DebugLog.write("lease", "\(device.name): idle timeout now \(SimulatorIdleTimeout.describe(timeout))")
    }

    private func checkOn() async {
        if let bootPID, !effects.isRunning(bootPID) {
            // Shut down outside the server: Device Hub, `simctl shutdown`, a crash.
            if store.lease(udid: device.udid)?.bootPID == bootPID { store.remove(udid: device.udid) }
            self.bootPID = nil
            passedBoot = nil
            effects.markAsleep(true)
            server.powerOff(Self.shutDownNotice(device))
            return
        }
        let usage = server.usageState()
        let now = Date()
        if usage.busy {
            store.touch(udid: device.udid, at: now)
        } else if usage.lastUse > renewed {
            store.touch(udid: device.udid, at: usage.lastUse)
            renewed = usage.lastUse
        }
        guard let lease = store.lease(udid: device.udid) else {
            // Let go of by hand, or by a reaper that misread the simulator:
            // this boot is still the server's, so it holds it again.
            store.take(device, booted: false, bootPID: bootPID, idleTimeout: idleTimeout)
            effects.ensureReaper()
            return
        }
        guard lease.isIdle(at: now) else { return }
        if await effects.externalUse(device) != nil {
            store.touch(udid: device.udid, at: now)
            return
        }
        let task = Task { await self.shutDown(unusedSince: lease.lastUsedAt, timeout: lease.effectiveIdleTimeout, lastUse: usage.lastUse) }
        settling = task
        await task.value
        settling = nil
    }

    /// Nobody used it for its timeout: off it goes, the server stays.
    /// `lastUse` is the server's own, as the decision read it.
    private func shutDown(unusedSince: Date, timeout: TimeInterval, lastUse: Date) async {
        let unused = SimulatorIdleTimeout.describe(timeout)
        let held = bootPID
        // Asleep first: a server off its simulator does not keep it up for
        // another one stopping at the same moment.
        effects.markAsleep(true)
        server.powerOff(Self.idleNotice(device, unused: unused))
        // A request that came in as it was decided — the device routes are
        // held back from here on — keeps it on.
        let now = server.usageState()
        if now.busy || now.lastUse > lastUse {
            do {
                try server.powerOn()
                effects.markAsleep(false)
            } catch {
                server.powerOff(Self.failedNotice(device, error))
                bootPID = nil
            }
            return
        }
        bootPID = nil
        let outcome = await effects.release(device.udid, unusedSince)
        switch Self.afterRelease(outcome, usedSince: (store.lease(udid: device.udid)?.lastUsedAt ?? .distantPast) > unusedSince) {
        case .off:
            passedBoot = nil
        case .leftToOthers:
            passedBoot = held
            server.powerOff(Self.leftNotice(device, unused: unused, reason: outcome?.reason))
        case .backOn:
            // Used as it was going: the boot is still the server's.
            bootPID = held
            do {
                try server.powerOn()
                effects.markAsleep(false)
            } catch {
                server.powerOff(Self.failedNotice(device, error))
            }
        }
    }

    /// What happened as the server let go of its simulator.
    enum AfterRelease: Equatable {
        /// It is shut down — or no longer SimTool's, and a boot of it is
        /// taken on as any other.
        case off
        /// It is still up for someone else: another SimTool server on it, or
        /// it would not shut down and the reaper tries again.
        case leftToOthers
        /// Something used it as it was going: the server keeps it.
        case backOn
    }

    static func afterRelease(_ outcome: SimulatorLeaseSweep.Outcome?, usedSince: Bool) -> AfterRelease {
        guard let outcome else { return .leftToOthers }
        switch outcome.action {
        case .shutDown, .stoppedServers, .released:
            return .off
        case .inUse:
            return .backOn
        case .kept:
            return usedSince ? .backOn : .leftToOthers
        }
    }

    /// Off: a boot SimTool holds that started since is taken on; one
    /// started outside SimTool waits for Start, and the page says it is on.
    private func checkOff() async {
        let current = await effects.bootPID(device.udid)
        if let passed = passedBoot, current != passed {
            // That boot is over: the page stops saying it is on.
            passedBoot = nil
            if current == nil { server.powerOff(Self.shutDownNotice(device)) }
        }
        guard let current, current != passedBoot else { return }
        guard let lease = store.lease(udid: device.udid), lease.bootPID == nil || lease.bootPID == current else {
            passedBoot = current
            server.powerOff(Self.outsideNotice(device))
            return
        }
        try? await start()
    }

    private func performStart() async throws {
        await settling?.value
        if isOn { return }
        server.powerStarting(Self.startingNotice(device))
        do {
            let resolved = try await effects.resolve(device.udid)
            let booted = try await effects.boot(resolved, idleTimeout)
            let lease = await effects.adopt(booted, idleTimeout)
            try server.powerOn()
            bootPID = lease.bootPID
            passedBoot = nil
            effects.markAsleep(false)
        } catch {
            // Not tried again by itself on this boot: a Start does.
            passedBoot = await effects.bootPID(device.udid)
            server.powerOff(Self.failedNotice(device, error))
            throw error
        }
    }

    // MARK: - What the viewer says

    static func idleNotice(_ device: SimulatorDevice, unused: String) -> ServerPowerPayload {
        ServerPowerPayload(
            state: .off,
            reason: "idle",
            title: "Shut down after \(unused) unused",
            detail: "SimTool turned \(device.name) off to save power. The server is still up — start the simulator to carry on."
        )
    }

    static func leftNotice(_ device: SimulatorDevice, unused: String, reason: String?) -> ServerPowerPayload {
        ServerPowerPayload(
            state: .off,
            reason: "released",
            title: "Let go after \(unused) unused",
            detail: "\(device.name) stays on: \(reason ?? "something else holds it"). Start to stream it here again."
        )
    }

    static func shutDownNotice(_ device: SimulatorDevice) -> ServerPowerPayload {
        ServerPowerPayload(
            state: .off,
            reason: "shutdown",
            title: "\(device.name) was shut down",
            detail: "Something outside this server shut it down. Start it again — or boot it any other way, and this page shows it."
        )
    }

    static func outsideNotice(_ device: SimulatorDevice) -> ServerPowerPayload {
        ServerPowerPayload(
            state: .off,
            reason: "outside",
            title: "\(device.name) is on outside SimTool",
            detail: "Something else booted it — Xcode, simctl. Start to stream it here; SimTool then shuts it down again once it goes unused."
        )
    }

    static func startingNotice(_ device: SimulatorDevice) -> ServerPowerPayload {
        ServerPowerPayload(
            state: .starting,
            title: "Starting \(device.name)…",
            detail: "Booting the simulator — this takes up to a minute."
        )
    }

    static func failedNotice(_ device: SimulatorDevice, _ error: Error) -> ServerPowerPayload {
        ServerPowerPayload(
            state: .off,
            reason: "failed",
            title: "\(device.name) did not start",
            detail: (error as? SimToolError)?.message ?? error.localizedDescription
        )
    }
}
