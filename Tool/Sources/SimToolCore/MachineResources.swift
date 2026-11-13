import Darwin
import Foundation

/// What a process, or a group of them, costs the Mac.
public struct ResourceUsage: Codable, Equatable, Sendable {
    /// Memory as Activity Monitor's Memory column counts it — the physical
    /// footprint, compressed and graphics memory included — in bytes.
    public var memory: UInt64
    /// CPU since the previous reading, in cores: 1 is one core kept busy,
    /// 100 % in Activity Monitor. Nil when there is no reading to compare with.
    public var cpu: Double?

    public init(memory: UInt64, cpu: Double?) {
        self.memory = memory
        self.cpu = cpu
    }
}

/// A booted simulator: its launchd_sim and everything that runs under it —
/// SpringBoard, the system's daemons, the app under test.
public struct SimulatorResources: Codable, Equatable, Sendable {
    /// Nil when its launchd_sim's arguments could not be read.
    public var udid: String?
    public var name: String?
    /// Its runtime's identifier: `com.apple.CoreSimulator.SimRuntime.iOS-26-4`.
    public var runtime: String?
    /// Its launchd_sim.
    public var pid: Int32
    public var bootedAt: Date?
    /// How many processes run in it, launchd_sim included.
    public var processes: Int
    public var usage: ResourceUsage

    public init(udid: String?, name: String?, runtime: String?, pid: Int32, bootedAt: Date?, processes: Int, usage: ResourceUsage) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.pid = pid
        self.bootedAt = bootedAt
        self.processes = processes
        self.usage = usage
    }
}

/// CoreSimulator's processes on the Mac itself, outside any simulator: the
/// render server and Metal hosts that draw every simulator's screen, the
/// service, the disk image daemon, Simulator.app when it is open. Every
/// simulator shares them, so none is counted to one.
public struct SimulatorServicesResources: Codable, Equatable, Sendable {
    public var processes: Int
    public var usage: ResourceUsage

    public init(processes: Int, usage: ResourceUsage) {
        self.processes = processes
        self.usage = usage
    }
}

/// The Mac a server runs on — its memory and CPU — and what its simulators
/// take of them.
public struct MachineResources: Codable, Equatable, Sendable {
    /// The kernel's memory pressure, as Activity Monitor's graph colours it.
    public enum Pressure: String, Codable, Sendable {
        case normal, warning, critical
    }

    /// Its host name, without `.local`.
    public var name: String
    /// Logical CPU cores.
    public var cores: Int
    /// The share of all its cores busy since the previous reading, 0…1.
    public var cpu: Double?
    /// The one-minute load average.
    public var load: Double
    /// Installed memory, in bytes.
    public var memory: UInt64
    /// What Activity Monitor calls Memory Used: apps, wired and compressed.
    public var memoryUsed: UInt64
    public var swapUsed: UInt64
    public var pressure: Pressure
    /// Every simulator booted as this user, by name.
    public var simulators: [SimulatorResources]
    /// Nil when no CoreSimulator process runs.
    public var simulatorServices: SimulatorServicesResources?

    public init(
        name: String,
        cores: Int,
        cpu: Double?,
        load: Double,
        memory: UInt64,
        memoryUsed: UInt64,
        swapUsed: UInt64,
        pressure: Pressure,
        simulators: [SimulatorResources],
        simulatorServices: SimulatorServicesResources?
    ) {
        self.name = name
        self.cores = cores
        self.cpu = cpu
        self.load = load
        self.memory = memory
        self.memoryUsed = memoryUsed
        self.swapUsed = swapUsed
        self.pressure = pressure
        self.simulators = simulators
        self.simulatorServices = simulatorServices
    }
}

/// The kernel's side of a reading. Every read is a closure, so the arithmetic
/// of `ResourceMonitor` is tested on made-up machines.
public struct ResourceProbe: Sendable {
    public struct Process: Equatable, Sendable {
        public var pid: Int32
        public var ppid: Int32
        /// The kernel's short name: the image's, cut to 16 characters.
        public var name: String
        public var startedAt: Date?

        public init(pid: Int32, ppid: Int32, name: String, startedAt: Date? = nil) {
            self.pid = pid
            self.ppid = ppid
            self.name = name
            self.startedAt = startedAt
        }
    }

    public struct Cost: Equatable, Sendable {
        /// User and system CPU time since it started, in nanoseconds.
        public var cpuTime: UInt64
        /// Its physical footprint, in bytes.
        public var memory: UInt64

        public init(cpuTime: UInt64, memory: UInt64) {
            self.cpuTime = cpuTime
            self.memory = memory
        }
    }

    public struct Host: Equatable, Sendable {
        public var name: String
        public var cores: Int
        /// The CPU ticks of all cores since boot — user, system, idle, nice —
        /// as the kernel counts them: 32 bits each, wrapping.
        public var ticks: [UInt32]
        public var load: Double
        public var memory: UInt64
        public var memoryUsed: UInt64
        public var swapUsed: UInt64
        public var pressure: MachineResources.Pressure

        public init(name: String, cores: Int, ticks: [UInt32], load: Double, memory: UInt64, memoryUsed: UInt64, swapUsed: UInt64, pressure: MachineResources.Pressure) {
            self.name = name
            self.cores = cores
            self.ticks = ticks
            self.load = load
            self.memory = memory
            self.memoryUsed = memoryUsed
            self.swapUsed = swapUsed
            self.pressure = pressure
        }
    }

    /// What a simulator's `device.plist` says of it.
    public struct Device: Equatable, Sendable {
        public var name: String?
        public var runtime: String?

        public init(name: String?, runtime: String?) {
            self.name = name
            self.runtime = runtime
        }
    }

    /// This user's processes.
    public var processes: @Sendable () -> [Process]
    public var executable: @Sendable (Int32) -> String?
    /// argv, argv[0] included.
    public var arguments: @Sendable (Int32) -> [String]?
    /// Nil for a process that is gone or not this user's.
    public var cost: @Sendable (Int32) -> Cost?
    public var host: @Sendable () -> Host
    /// A simulator's device directory → its `device.plist`.
    public var device: @Sendable (String) -> Device?
    /// A clock that does not jump: seconds since boot.
    public var uptime: @Sendable () -> TimeInterval
    public var now: @Sendable () -> Date
    public var pause: @Sendable (Duration) async -> Void

    public init(
        processes: @escaping @Sendable () -> [Process],
        executable: @escaping @Sendable (Int32) -> String?,
        arguments: @escaping @Sendable (Int32) -> [String]?,
        cost: @escaping @Sendable (Int32) -> Cost?,
        host: @escaping @Sendable () -> Host,
        device: @escaping @Sendable (String) -> Device?,
        uptime: @escaping @Sendable () -> TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.processes = processes
        self.executable = executable
        self.arguments = arguments
        self.cost = cost
        self.host = host
        self.device = device
        self.uptime = uptime
        self.now = now
        self.pause = pause
    }

    /// The Mac this runs on.
    public static let live = ResourceProbe(
        processes: { ProcessTable.kernelTable().map { Process(pid: $0.pid, ppid: $0.ppid, name: $0.name, startedAt: $0.startedAt) } },
        executable: { ProcessTable.executablePath($0) },
        arguments: { ProcessTable.arguments($0) },
        cost: { KernelResources.cost(of: $0) },
        host: { KernelResources.host() },
        device: { KernelResources.device(in: $0) },
        uptime: { ProcessInfo.processInfo.systemUptime }
    )
}

/// What the Mac's processes, its simulators and the Mac itself cost, read
/// each time a viewer's process list asks. CPU is a rate: it is measured
/// between this reading and the one before, never over less than `shortest`
/// — the first reading in a while takes a second look before it answers, and
/// a request right after another's (two viewers, a poll beside a click) waits
/// out the rest.
public actor ResourceMonitor {
    private struct Reading {
        var uptime: TimeInterval
        var wall: Date
        /// CPU time by PID, with the start that tells a reused PID apart.
        var cpu: [Int32: (startedAt: Date?, time: UInt64)]
    }

    private let probe: ResourceProbe
    private var previous: Reading?
    /// The Mac's tick counters the Mac's CPU is measured against.
    private var ticks: (uptime: TimeInterval, values: [UInt32])?

    /// A reading older than this says little about now: the next one looks twice.
    static let stale: TimeInterval = 10
    /// The shortest span CPU is measured over: over a few milliseconds it is noise.
    static let shortest: TimeInterval = 0.25
    /// How long the Mac's own tick counters are compared over before they are
    /// read anew: the kernel moves them in batches — over a quarter of a
    /// second they may not move at all, or move twice.
    static let machineSpan: TimeInterval = 1

    public init(probe: ResourceProbe = .live) {
        self.probe = probe
    }

    /// The list with what each of its processes costs, and the Mac's figures
    /// with every simulator booted on it.
    public func annotate(_ list: SimToolProcessList) async -> SimToolProcessList {
        if previous.map({ probe.uptime() - $0.uptime > Self.stale }) ?? true {
            _ = measure(list)
        }
        // Another request may have read while this one waited: the check is
        // made again after every wait — a few times, then it reads as it is.
        for _ in 0..<8 {
            guard let previous else { break }
            let age = probe.uptime() - previous.uptime
            guard age < Self.shortest else { break }
            await probe.pause(.nanoseconds(Int64((Self.shortest - age) * 1_000_000_000) + 1_000_000))
        }
        return measure(list)
    }

    private func measure(_ list: SimToolProcessList) -> SimToolProcessList {
        let uptime = probe.uptime()
        let wall = probe.now()
        let table = probe.processes()
        let started = Dictionary(table.map { ($0.pid, $0.startedAt) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [Int32]] = [:]
        for process in table where process.pid != process.ppid { children[process.ppid, default: []].append(process.pid) }

        // Each simulator: its launchd_sim and everything under it.
        var inside: Set<Int32> = []
        var simulators: [(launchd: ResourceProbe.Process, udid: String?, directory: String?, members: [Int32])] = []
        for launchd in table where launchd.name == "launchd_sim" && !inside.contains(launchd.pid) {
            let (udid, directory) = Self.device(arguments: probe.arguments(launchd.pid) ?? [])
            var members = [launchd.pid]
            inside.insert(launchd.pid)
            var frontier = [launchd.pid]
            while !frontier.isEmpty {
                let next = frontier.flatMap { children[$0] ?? [] }.filter { inside.insert($0).inserted }
                members += next
                frontier = next
            }
            simulators.append((launchd, udid, directory, members))
        }
        // CoreSimulator on the Mac: launchd starts its services.
        let services = table.filter { process in
            process.ppid == 1 && !inside.contains(process.pid) && probe.executable(process.pid).map(Self.isSimulatorService) == true
        }.map(\.pid)

        let measured = Set(list.processes.map(\.pid)).union(inside).union(services)
        var costs: [Int32: ResourceProbe.Cost] = [:]
        for pid in measured { costs[pid] = probe.cost(pid) }
        let host = probe.host()

        let interval = previous.map { uptime - $0.uptime } ?? 0
        let comparable = previous != nil && interval >= Self.shortest
        func cpu(_ pid: Int32) -> Double? {
            guard comparable, let previous, let cost = costs[pid] else { return nil }
            let before: UInt64
            if let earlier = previous.cpu[pid], earlier.startedAt == started[pid] ?? nil {
                before = earlier.time
            } else if let start = started[pid] ?? nil, start >= previous.wall {
                // Started since the last reading: all its time is new.
                before = 0
            } else {
                return nil
            }
            return Double(cost.cpuTime >= before ? cost.cpuTime - before : 0) / (interval * 1_000_000_000)
        }
        func usage(_ pids: [Int32]) -> ResourceUsage {
            ResourceUsage(
                memory: pids.reduce(0) { $0 + (costs[$1]?.memory ?? 0) },
                cpu: comparable ? pids.reduce(0) { $0 + (cpu($1) ?? 0) } : nil
            )
        }

        var known: [String: String] = [:]
        for group in list.groups {
            if let session = group.session { known[session.device.udid.uppercased()] = session.device.name }
            for process in group.processes {
                if let udid = process.deviceUDID, let name = process.deviceName { known[udid.uppercased()] = name }
            }
        }
        let booted = simulators.map { simulator -> SimulatorResources in
            let device = simulator.directory.flatMap(probe.device)
            return SimulatorResources(
                udid: simulator.udid,
                name: device?.name ?? simulator.udid.flatMap { known[$0.uppercased()] },
                runtime: device?.runtime,
                pid: simulator.launchd.pid,
                bootedAt: simulator.launchd.startedAt,
                processes: simulator.members.count,
                usage: usage(simulator.members)
            )
        }.sorted { first, second in
            let one = (first.name ?? first.udid ?? "").localizedLowercase, other = (second.name ?? second.udid ?? "").localizedLowercase
            return one == other ? first.pid < second.pid : one < other
        }

        // Counters that did not move say nothing: no figure rather than 0 %.
        var machineCPU: Double?
        if let ticks, ticks.values.count == 4, host.ticks.count == 4, uptime - ticks.uptime >= Self.shortest {
            let delta = zip(host.ticks, ticks.values).map { UInt64($0 &- $1) }
            let busy = delta[0] + delta[1] + delta[3]
            let total = busy + delta[2]
            if total > 0 { machineCPU = Double(busy) / Double(total) }
        }
        if host.ticks.count == 4, ticks.map({ uptime - $0.uptime >= Self.machineSpan || $0.values.count != 4 }) ?? true {
            ticks = (uptime, host.ticks)
        }

        var result = list
        for group in result.groups.indices {
            for index in result.groups[group].processes.indices {
                let pid = result.groups[group].processes[index].pid
                guard let cost = costs[pid] else { continue }
                result.groups[group].processes[index].usage = ResourceUsage(memory: cost.memory, cpu: cpu(pid))
            }
        }
        result.machine = MachineResources(
            name: host.name,
            cores: host.cores,
            cpu: machineCPU,
            load: host.load,
            memory: host.memory,
            memoryUsed: host.memoryUsed,
            swapUsed: host.swapUsed,
            pressure: host.pressure,
            simulators: booted,
            simulatorServices: services.isEmpty ? nil : SimulatorServicesResources(processes: services.count, usage: usage(services))
        )

        if previous == nil || interval >= Self.shortest {
            var times: [Int32: (startedAt: Date?, time: UInt64)] = [:]
            for (pid, cost) in costs { times[pid] = (started[pid] ?? nil, cost.cpuTime) }
            previous = Reading(uptime: uptime, wall: wall, cpu: times)
        }
        return result
    }

    /// A launchd_sim's device: its UDID and directory, from the bootstrap
    /// path it is started with (`…/Devices/<UDID>/data/var/run/…`) — under
    /// CoreSimulator's devices or a test run's clones alike.
    static func device(arguments: [String]) -> (udid: String?, directory: String?) {
        for argument in arguments.dropFirst() {
            guard argument.hasPrefix("/"), let data = argument.range(of: "/data/") else { continue }
            let directory = String(argument[..<data.lowerBound])
            let last = (directory as NSString).lastPathComponent
            return (UUID(uuidString: last) != nil ? last.uppercased() : nil, directory)
        }
        return (nil, nil)
    }

    /// A process CoreSimulator runs on the Mac for its simulators — not
    /// `simctl`, which is whoever asks for something.
    static func isSimulatorService(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard name != "simctl", name != "launchd_sim" else { return false }
        return path.contains("/CoreSimulator.framework/") || path.hasSuffix("/Simulator.app/Contents/MacOS/Simulator")
    }
}

/// The live readings behind `ResourceProbe.live`.
enum KernelResources {
    private static let hostPort = mach_host_self()

    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(max(info.denom, 1)))
    }()

    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        return host_page_size(hostPort, &size) == KERN_SUCCESS && size > 0 ? UInt64(size) : 16384
    }()

    private static let hostName: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "This Mac" }
        let name = String(cString: buffer)
        return name.hasSuffix(".local") ? String(name.dropLast(".local".count)) : name
    }()

    static func cost(of pid: Int32) -> ResourceProbe.Cost? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // Mach time units: nanoseconds on Intel, 24 MHz ticks on Apple silicon.
        let ticks = Double(info.ri_user_time) + Double(info.ri_system_time)
        return ResourceProbe.Cost(cpuTime: UInt64(ticks * timebase.numer / timebase.denom), memory: info.ri_phys_footprint)
    }

    static func host() -> ResourceProbe.Host {
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) < 1 { load[0] = 0 }

        var cpu = host_cpu_load_info()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let cpuRead = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) { host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &cpuCount) }
        } == KERN_SUCCESS
        let ticks = cpuRead ? [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3] : []

        var stats = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let vmRead = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(hostPort, HOST_VM_INFO64, $0, &vmCount) }
        } == KERN_SUCCESS
        // Activity Monitor's Memory Used: app memory (anonymous pages that
        // cannot be purged), wired, and what the compressor holds.
        let anonymous = UInt64(stats.internal_page_count)
        let app = anonymous - min(UInt64(stats.purgeable_count), anonymous)
        let used = vmRead ? (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize : 0

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        let pressure: MachineResources.Pressure
        switch sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 ? level : 1 {
        case 4...: pressure = .critical
        case 2...: pressure = .warning
        default: pressure = .normal
        }

        return ResourceProbe.Host(
            name: hostName,
            cores: ProcessInfo.processInfo.activeProcessorCount,
            ticks: ticks,
            load: load[0],
            memory: ProcessInfo.processInfo.physicalMemory,
            memoryUsed: used,
            swapUsed: swapUsed,
            pressure: pressure
        )
    }

    static func device(in directory: String) -> ResourceProbe.Device? {
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("device.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return ResourceProbe.Device(name: plist["name"] as? String, runtime: plist["runtime"] as? String)
    }
}
