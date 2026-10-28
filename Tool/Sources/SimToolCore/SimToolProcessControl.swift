import Darwin
import Foundation

/// Stopping SimTool's processes — from the viewer's process list, `simtool
/// kill <pid>` and `kill --orphans`. A PID is stopped only when the discovery,
/// run again at that moment, says it is SimTool's: never an arbitrary process,
/// nor one that took a SimTool process's PID after it exited. Every effect is
/// injectable, so the rules are tested without signalling anything.
public struct SimToolProcessControl: Sendable {
    public struct Outcome: Codable, Equatable, Sendable {
        public enum Result: String, Codable, Sendable {
            /// It exited on SIGTERM — a server after its own shutdown.
            case stopped
            /// It did not, and was SIGKILLed.
            case killed
            /// It had exited already.
            case gone
            /// The server asked to stop itself: it does, right after it answers.
            case stopping
        }

        public var pid: Int32
        public var name: String
        public var kind: SimToolProcess.Kind
        public var result: Result
        /// Its helpers and children, gone with it.
        public var alongside: [Int32]

        public init(pid: Int32, name: String, kind: SimToolProcess.Kind, result: Result, alongside: [Int32] = []) {
            self.pid = pid
            self.name = name
            self.kind = kind
            self.result = result
            self.alongside = alongside
        }
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        /// Not a process the discovery calls SimTool's.
        case notSimTool(Int32)
        /// The process asking — a server's own PID — without a confirmation.
        case ownProcess(Int32)

        public var errorDescription: String? {
            switch self {
            case let .notSimTool(pid):
                return "PID \(pid) is not a SimTool process. SimTool stops only its own servers, helpers and commands — see simtool ps."
            case let .ownProcess(pid):
                return "PID \(pid) is the server this request went to. Confirm to stop it: its viewers lose the device until a server starts again."
            }
        }
    }

    /// The SimTool processes now.
    public var list: @Sendable () -> SimToolProcessList
    /// Stops a server through its session: SIGTERM so it shuts its simulator
    /// down itself, SIGKILL and letting go of that simulator here when it will
    /// not. True when it stopped by itself.
    public var stopSession: @Sendable (SessionInfo) async -> Bool
    /// The process asking for a stop is to stop itself: after it answers.
    public var stopSelf: @Sendable () -> Void
    public var signal: @Sendable (Int32, Int32) -> Void
    public var isRunning: @Sendable (Int32) -> Bool
    /// When the process with this PID started: a PID that started at another
    /// moment is another process.
    public var startTime: @Sendable (Int32) -> Date?
    public var pause: @Sendable (Duration) async -> Void
    public var ownPID: Int32
    /// How long a helper, child or command has to exit on SIGTERM before
    /// SIGKILL. A server or the reaper — shutting simulators down on the way
    /// out — gets `shutdownGrace`.
    public var grace: Duration
    public var shutdownGrace: Duration

    public init(
        list: @escaping @Sendable () -> SimToolProcessList = { SimToolProcessDiscovery.take() },
        stopSession: @escaping @Sendable (SessionInfo) async -> Bool = SimToolProcessControl.stopSessionServer,
        stopSelf: @escaping @Sendable () -> Void = SimToolProcessControl.terminateSelfSoon,
        signal: @escaping @Sendable (Int32, Int32) -> Void = { _ = Darwin.kill($0, $1) },
        isRunning: @escaping @Sendable (Int32) -> Bool = { SessionInfo.isRunning(pid: $0) },
        startTime: @escaping @Sendable (Int32) -> Date? = { SessionInfo.startTime(pid: $0) },
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        ownPID: Int32 = getpid(),
        grace: Duration = .seconds(3),
        shutdownGrace: Duration = .seconds(6)
    ) {
        self.list = list
        self.stopSession = stopSession
        self.stopSelf = stopSelf
        self.signal = signal
        self.isRunning = isRunning
        self.startTime = startTime
        self.pause = pause
        self.ownPID = ownPID
        self.grace = grace
        self.shutdownGrace = shutdownGrace
    }

    /// Stops the SimTool process `pid` and what runs for it: a server through
    /// its session, so its simulator shuts down with it; anything else on
    /// SIGTERM, then SIGKILL. Its helpers and children that outlive it go too.
    /// The process asking stops only on `confirmingOwnProcess`, and then by
    /// itself, after it answers.
    public func kill(pid: Int32, confirmingOwnProcess: Bool = false) async throws -> Outcome {
        let processes = list()
        guard let target = processes.process(pid: pid) else { throw Refusal.notSimTool(pid) }
        if pid == ownPID {
            guard confirmingOwnProcess else { throw Refusal.ownProcess(pid) }
            stopSelf()
            return Outcome(pid: pid, name: target.name, kind: target.kind, result: .stopping)
        }
        return await stop(target, in: processes)
    }

    /// Stops every orphan: helpers whose server or command is gone.
    public func killOrphans() async -> [Outcome] {
        let processes = list()
        return await withTaskGroup(of: Outcome.self) { group in
            for orphan in processes.orphanRoots where orphan.pid != ownPID {
                group.addTask { await stop(orphan, in: processes) }
            }
            var outcomes: [Outcome] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes.sorted { $0.pid < $1.pid }
        }
    }

    private func stop(_ target: SimToolProcess, in processes: SimToolProcessList) async -> Outcome {
        let descendants = processes.descendants(of: target.pid).filter { $0.pid != ownPID }
        let result: Outcome.Result
        if target.kind == .server, let session = processes.session(id: target.sessionId) {
            guard isSame(target) else { return Outcome(pid: target.pid, name: target.name, kind: target.kind, result: .gone) }
            result = await stopSession(session) ? .stopped : .killed
        } else {
            result = await terminate(target, within: [.server, .reaper].contains(target.kind) ? shutdownGrace : grace)
        }
        // Helpers read their orders from the process that started them and
        // exit when it is gone: a moment for that, then they are stopped too.
        var alongside: [Int32] = []
        for _ in 0..<10 where descendants.contains(where: isSame) {
            await pause(.milliseconds(100))
        }
        for descendant in descendants {
            if isSame(descendant) { _ = await terminate(descendant, within: grace) }
            if !isSame(descendant) { alongside.append(descendant.pid) }
        }
        return Outcome(pid: target.pid, name: target.name, kind: target.kind, result: result, alongside: alongside)
    }

    /// SIGTERM, and SIGKILL when it has not exited within `grace`.
    private func terminate(_ process: SimToolProcess, within grace: Duration) async -> Outcome.Result {
        guard isSame(process) else { return .gone }
        signal(process.pid, SIGTERM)
        if await exits(process.pid, within: grace) { return .stopped }
        signal(process.pid, SIGKILL)
        _ = await exits(process.pid, within: .seconds(1))
        return .killed
    }

    private func exits(_ pid: Int32, within duration: Duration) async -> Bool {
        let step = Duration.milliseconds(100)
        var waited = Duration.zero
        while isRunning(pid) {
            guard waited < duration else { return false }
            await pause(step)
            waited += step
        }
        return true
    }

    /// The process listed is still the one running under its PID.
    private func isSame(_ process: SimToolProcess) -> Bool {
        guard isRunning(process.pid) else { return false }
        guard let listed = process.startedAt, let now = startTime(process.pid) else { return true }
        return abs(listed.timeIntervalSince(now)) < 0.001
    }

    /// A session's server stopped from a process that is not a CLI: the
    /// session store's SIGTERM-then-SIGKILL, and the simulator let go of here
    /// when the server could not do it itself.
    public static let stopSessionServer: @Sendable (SessionInfo) async -> Bool = { session in
        if await SessionStore.shared.terminate(session) { return true }
        let last = (try? SessionStore.shared.session(id: session.sessionId)) ?? session
        _ = await SimulatorLeaseSweep().release(stopped: last)
        return false
    }

    /// SIGTERM to this process a moment from now: the answer goes out first,
    /// then the process runs its own shutdown.
    public static let terminateSelfSoon: @Sendable () -> Void = {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
            _ = Darwin.kill(getpid(), SIGTERM)
        }
    }
}

/// What a stop did, as the server and `simtool kill --json` answer it.
public struct ProcessKillPayload: Codable, Equatable, Sendable {
    public var outcomes: [SimToolProcessControl.Outcome]
    public init(outcomes: [SimToolProcessControl.Outcome]) { self.outcomes = outcomes }
}
