import Darwin
import Foundation

/// A process of SimTool's running on this Mac: a server, the reaper, a
/// command, a helper SimTool compiled into its cache, or a process one of
/// them started. Found by `SimToolProcessDiscovery` — from any `simtool`
/// binary, a Homebrew install and a checkout's debug build alike.
public struct SimToolProcess: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// `simtool serve`, or a `simtool run` the session registry names.
        case server
        /// `simtool reap --watch`.
        case reaper
        /// Any other `simtool` command: `app launch`, `test run`, `input tap`…
        case command
        /// A helper from SimTool's cache, or the `simctl spawn` that runs one
        /// inside a simulator.
        case helper
        /// A process a server, command or the reaper started:
        /// `simctl spawn … log stream`, `xcodebuild`…
        case child
    }

    public var id: Int32 { pid }
    public var pid: Int32
    /// The parent as the kernel has it — 1 for a detached server, and for a
    /// helper whose server is gone.
    public var ppid: Int32
    public var kind: Kind
    /// What it is, in a few words: `simtool serve`, `direct-hid helper`.
    public var name: String
    /// The running image, symlinks resolved.
    public var executable: String
    /// The arguments it was started with, without the executable.
    public var arguments: [String]
    public var startedAt: Date?
    /// Its working directory, when it could be read.
    public var directory: String?
    /// The simulator it works on, when its arguments or its boot name one.
    public var deviceUDID: String?
    public var deviceName: String?
    /// The SimTool process it runs for: a helper's server or command, a
    /// helper's `simctl spawn`, a child's parent. Nil for a server, a command
    /// or the reaper, and for an orphan.
    public var owner: Int32?
    /// The session of the server it belongs to.
    public var sessionId: String?
    /// A helper whose server or command is gone: nothing will stop it.
    public var orphan: Bool
    /// What else is worth knowing about it, in a sentence.
    public var note: String?

    public init(
        pid: Int32,
        ppid: Int32,
        kind: Kind,
        name: String,
        executable: String,
        arguments: [String] = [],
        startedAt: Date? = nil,
        directory: String? = nil,
        deviceUDID: String? = nil,
        deviceName: String? = nil,
        owner: Int32? = nil,
        sessionId: String? = nil,
        orphan: Bool = false,
        note: String? = nil
    ) {
        self.pid = pid
        self.ppid = ppid
        self.kind = kind
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.startedAt = startedAt
        self.directory = directory
        self.deviceUDID = deviceUDID
        self.deviceName = deviceName
        self.owner = owner
        self.sessionId = sessionId
        self.orphan = orphan
        self.note = note
    }
}

/// Every SimTool process on this Mac, grouped the way a person reads them:
/// the orphans first — what leaked — then each server with what it runs,
/// then the reaper and the commands.
public struct SimToolProcessList: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case orphans, server, other
        }

        public var kind: Kind
        /// The server's session, when the registry has it.
        public var session: SessionInfo?
        /// The group's processes in tree order: a server, then what runs for it.
        public var processes: [SimToolProcess]

        public init(kind: Kind, session: SessionInfo? = nil, processes: [SimToolProcess]) {
            self.kind = kind
            self.session = session
            self.processes = processes
        }
    }

    public var groups: [Group]
    /// The process that made the list: a server marks its own row with it.
    public var pid: Int32
    /// The home directory, so a reader can shorten paths under it.
    public var home: String
    public var takenAt: Date
    public var orphans: Int

    public init(groups: [Group], pid: Int32, home: String = NSHomeDirectory(), takenAt: Date = Date()) {
        self.groups = groups
        self.pid = pid
        self.home = home
        self.takenAt = takenAt
        orphans = groups.reduce(0) { $0 + $1.processes.filter(\.orphan).count }
    }

    public var processes: [SimToolProcess] { groups.flatMap(\.processes) }

    public func process(pid: Int32) -> SimToolProcess? {
        processes.first { $0.pid == pid }
    }

    public func session(id: String?) -> SessionInfo? {
        guard let id else { return nil }
        return groups.lazy.compactMap(\.session).first { $0.sessionId == id }
    }

    /// What runs for `pid`, nearest first: its helpers and children, and theirs.
    public func descendants(of pid: Int32) -> [SimToolProcess] {
        var result: [SimToolProcess] = []
        var frontier = [pid]
        while !frontier.isEmpty {
            let next = processes.filter { process in
                process.owner.map(frontier.contains) == true && !result.contains { $0.pid == process.pid }
            }
            result += next
            frontier = next.map(\.pid)
        }
        return result
    }

    /// The orphans nothing else in the list stops: an orphaned `simctl spawn`
    /// takes the helper it runs with it.
    public var orphanRoots: [SimToolProcess] {
        let orphans = processes.filter(\.orphan)
        return orphans.filter { orphan in !orphans.contains { $0.pid == orphan.owner } }
    }
}

/// A process as the kernel lists it, read once per pass.
public struct ProcessRecord: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    /// The running image, symlinks resolved; empty when it could not be read.
    public var executable: String
    /// argv, argv[0] included.
    public var arguments: [String]
    public var startedAt: Date?
    public var directory: String?

    public init(pid: Int32, ppid: Int32, executable: String, arguments: [String] = [], startedAt: Date? = nil, directory: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.executable = executable
        self.arguments = arguments
        self.startedAt = startedAt
        self.directory = directory
    }

    var imageName: String { (executable as NSString).lastPathComponent }
}

/// The processes of this user the discovery needs, straight from the kernel —
/// no `ps` to start and parse, so a viewer can ask every two seconds: every
/// `simtool…` image, `simctl` and `launchd_sim` (whose arguments name a
/// helper's simulator), and the children of `simtool` processes.
public enum ProcessTable {
    public static func current() -> [ProcessRecord] {
        let table = kernelTable()
        let simtool = Set(table.filter { $0.name.hasPrefix("simtool") }.map(\.pid))
        return table.compactMap { entry in
            guard entry.name.hasPrefix("simtool") || entry.name == "simctl" || entry.name == "launchd_sim" || simtool.contains(entry.ppid),
                  let executable = executablePath(entry.pid) else { return nil }
            return ProcessRecord(
                pid: entry.pid,
                ppid: entry.ppid,
                executable: executable,
                arguments: arguments(entry.pid) ?? [],
                startedAt: entry.startedAt,
                directory: workingDirectory(entry.pid)
            )
        }
    }

    private struct Entry {
        var pid: Int32
        var ppid: Int32
        /// The kernel's short name: the image's, cut to 16 characters.
        var name: String
        var startedAt: Date?
    }

    /// Every process of this user, in one `sysctl`.
    private static func kernelTable() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        // Room for the processes that start between the two calls.
        size += size / 4
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).map { info in
            let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let start = info.kp_proc.p_un.__p_starttime
            return Entry(
                pid: info.kp_proc.p_pid,
                ppid: info.kp_eproc.e_ppid,
                name: name,
                startedAt: start.tv_sec > 0 ? Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000) : nil
            )
        }
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// argv as the process got it — no guessing where a path with spaces ends.
    /// `KERN_PROCARGS2` is argc, the executable's path, padding, then argv.
    private static func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    private static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }
}

/// Which processes are SimTool's, what each is and whom it runs for. Pure, so
/// every rule is unit-tested; `take()` feeds it the live machine.
public enum SimToolProcessDiscovery {
    /// Where SimTool compiles the helpers it runs: the HID and fold helpers,
    /// the accessibility reader.
    public static var helpersDirectory: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("SimTool/SimulatorHelpers", isDirectory: true).path
    }

    /// The SimTool processes running now, as this user.
    public static func take(ownPID: Int32 = getpid()) -> SimToolProcessList {
        var names: [String: String] = [:]
        for lease in SimulatorLeaseStore.shared.list() { names[lease.udid.uppercased()] = lease.name }
        return list(
            records: ProcessTable.current(),
            sessions: (try? SessionStore.shared.list()) ?? [],
            deviceNames: names,
            helpersDirectory: helpersDirectory,
            ownPID: ownPID
        )
    }

    /// - Parameters:
    ///   - records: this user's processes, as `ProcessTable` reads them.
    ///   - sessions: the session registry; a session counts only while its
    ///     PID is the process that wrote it.
    ///   - deviceNames: simulator names by UDID, for the processes that name
    ///     one; the sessions' own devices are known without it.
    ///   - ownPID: the process asking — a server marks its own row with it.
    public static func list(
        records: [ProcessRecord],
        sessions: [SessionInfo],
        deviceNames: [String: String] = [:],
        helpersDirectory: String,
        ownPID: Int32,
        home: String = NSHomeDirectory(),
        now: Date = Date()
    ) -> SimToolProcessList {
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let helpers = (helpersDirectory as NSString).standardizingPath + "/"
        func isHelperImage(_ path: String) -> Bool {
            (path as NSString).standardizingPath.hasPrefix(helpers) && (path as NSString).lastPathComponent.hasPrefix("simtool-")
        }
        func isSimTool(_ record: ProcessRecord) -> Bool { record.imageName == "simtool" }
        func session(of record: ProcessRecord) -> SessionInfo? {
            sessions.first { session in
                // `startedAt` is written to the second; the server started before it.
                session.pid == record.pid && (record.startedAt.map { $0 <= session.startedAt.addingTimeInterval(2) } ?? true)
            }
        }
        var names = Dictionary(deviceNames.map { ($0.key.uppercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        for session in sessions { names[session.device.udid.uppercased()] = session.device.name }
        func name(of udid: String?) -> String? { udid.flatMap { names[$0.uppercased()] } }

        // What each record is, before who it runs for.
        var found: [Int32: SimToolProcess] = [:]
        var spawnedHelper: [Int32: String] = [:]
        for record in records {
            let arguments = Array(record.arguments.dropFirst())
            let base = SimToolProcess(
                pid: record.pid,
                ppid: record.ppid,
                kind: .command,
                name: "",
                executable: record.executable,
                arguments: arguments,
                startedAt: record.startedAt,
                directory: record.directory
            )
            if isSimTool(record) {
                var process = base
                let subcommand = arguments.first ?? ""
                if let session = session(of: record) {
                    process.kind = .server
                    process.name = "simtool " + (subcommand.isEmpty || subcommand.hasPrefix("-") ? "serve" : subcommand)
                    process.sessionId = session.sessionId
                    process.deviceUDID = session.device.udid
                    process.deviceName = session.device.name
                    process.directory = session.projectRoot ?? record.directory
                } else if subcommand == "serve" {
                    process.kind = .server
                    process.name = "simtool serve"
                    process.deviceUDID = option("--device", "-d", in: arguments)
                    process.deviceName = name(of: process.deviceUDID)
                    if record.startedAt.map({ now.timeIntervalSince($0) > 15 }) ?? true {
                        process.note = "Not in SimTool's session registry: simtool sessions and simtool kill do not see it."
                    }
                } else if subcommand == "reap", arguments.contains("--watch") {
                    process.kind = .reaper
                    process.name = "simtool reap --watch"
                    process.note = "Shuts down the simulators SimTool holds once nothing uses them."
                } else {
                    // The command asking — `simtool ps` — is not news to itself.
                    guard record.pid != ownPID else { continue }
                    process.kind = .command
                    process.name = (["simtool"] + words(arguments, limit: 2)).joined(separator: " ")
                    process.deviceUDID = option("--device", "-d", in: arguments)
                    process.deviceName = name(of: process.deviceUDID)
                }
                found[record.pid] = process
            } else if isHelperImage(record.executable) {
                var process = base
                process.kind = .helper
                process.name = helperName(record.executable)
                process.deviceUDID = arguments.first(where: isUDID)
                found[record.pid] = process
            } else if record.imageName == "simctl", let spawn = arguments.firstIndex(of: "spawn"),
                      let helper = arguments[(spawn + 1)...].first(where: isHelperImage) {
                var process = base
                process.kind = .helper
                process.name = "simctl spawn · " + helperName(helper)
                process.deviceUDID = arguments[(spawn + 1)...].first { !$0.hasPrefix("-") }
                spawnedHelper[record.pid] = (helper as NSString).standardizingPath
                found[record.pid] = process
            }
        }
        // A process a server, command or the reaper started.
        for record in records where found[record.pid] == nil && record.imageName != "launchd_sim" {
            guard let parent = found[record.ppid], [.server, .command, .reaper].contains(parent.kind) else { continue }
            let arguments = Array(record.arguments.dropFirst())
            found[record.pid] = SimToolProcess(
                pid: record.pid,
                ppid: record.ppid,
                kind: .child,
                name: ([record.imageName] + words(arguments, limit: 3)).joined(separator: " "),
                executable: record.executable,
                arguments: arguments,
                startedAt: record.startedAt,
                directory: record.directory,
                deviceUDID: arguments.first(where: isUDID),
                owner: record.ppid
            )
        }

        // Who each helper runs for. One in the Mac's own process tree runs for
        // the nearest server or command above it; one inside a simulator has
        // that simulator's launchd_sim for a parent, and runs for the
        // `simctl spawn` of the same helper on the same simulator.
        func runner(above pid: Int32) -> Int32? {
            var seen: Set<Int32> = []
            var current = byPID[pid]?.ppid
            while let candidate = current, candidate > 1, seen.insert(candidate).inserted {
                if let process = found[candidate], [.server, .command, .reaper].contains(process.kind) { return candidate }
                current = byPID[candidate]?.ppid
            }
            return nil
        }
        func bootUDID(of record: ProcessRecord) -> String? {
            guard let parent = byPID[record.ppid], parent.imageName == "launchd_sim" else { return nil }
            return (parent.arguments + [record.directory ?? ""]).lazy.compactMap(devicesUDID).first
        }
        for pid in found.keys.sorted() {
            guard var process = found[pid], process.kind == .helper else { continue }
            if spawnedHelper[pid] != nil {
                process.owner = runner(above: pid)
            } else if let record = byPID[pid], let udid = bootUDID(of: record) {
                process.deviceUDID = udid
                let path = (record.executable as NSString).standardizingPath
                process.owner = spawnedHelper.first { spawner, helper in
                    helper == path && found[spawner]?.deviceUDID?.uppercased() == udid.uppercased()
                }?.key
            } else {
                process.owner = runner(above: pid)
            }
            found[pid] = process
        }
        // An orphan: a helper with nothing above it to stop it — no runner, or
        // a `simctl spawn` that is an orphan itself.
        func isOrphan(_ pid: Int32, depth: Int = 0) -> Bool {
            guard let process = found[pid], process.kind == .helper, depth < 8 else { return false }
            guard let owner = process.owner, let above = found[owner] else { return true }
            return above.kind == .helper ? isOrphan(owner, depth: depth + 1) : false
        }
        for pid in found.keys {
            guard isOrphan(pid), var process = found[pid] else { continue }
            process.orphan = true
            process.note = process.owner == nil
                ? "Its server or command is gone, and nothing will stop it."
                : "The simctl spawn it runs under has lost its server."
            found[pid] = process
        }
        // The session each process works for, and the simulator's name.
        func root(of pid: Int32) -> Int32 {
            var current = pid
            var depth = 0
            while let owner = found[current]?.owner, owner != current, depth < 8 {
                current = owner
                depth += 1
            }
            return current
        }
        for pid in found.keys {
            guard var process = found[pid] else { continue }
            let top = found[root(of: pid)]
            if process.sessionId == nil, !process.orphan, top?.kind == .server { process.sessionId = top?.sessionId }
            if process.deviceUDID == nil, !process.orphan, top?.kind == .server { process.deviceUDID = top?.deviceUDID }
            if process.deviceName == nil { process.deviceName = name(of: process.deviceUDID) }
            found[pid] = process
        }

        // Groups: what leaked, then each server — this one first, then the
        // newest — then everything else.
        func tree(from roots: [SimToolProcess], within members: [SimToolProcess]) -> [SimToolProcess] {
            var ordered: [SimToolProcess] = []
            func visit(_ process: SimToolProcess, depth: Int) {
                guard depth < 8, !ordered.contains(where: { $0.pid == process.pid }) else { return }
                ordered.append(process)
                for child in members.filter({ $0.owner == process.pid }).sorted(by: earlier) { visit(child, depth: depth + 1) }
            }
            for root in roots.sorted(by: earlier) { visit(root, depth: 0) }
            return ordered
        }
        let all = Array(found.values)
        var groups: [SimToolProcessList.Group] = []
        let orphans = all.filter(\.orphan)
        if !orphans.isEmpty {
            let roots = orphans.filter { orphan in !orphans.contains { $0.pid == orphan.owner } }
            groups.append(.init(kind: .orphans, processes: tree(from: roots, within: orphans)))
        }
        let servers = all.filter { $0.kind == .server }.sorted { first, second in
            if (first.pid == ownPID) != (second.pid == ownPID) { return first.pid == ownPID }
            return (first.startedAt ?? .distantPast) > (second.startedAt ?? .distantPast)
        }
        var placed = Set(orphans.map(\.pid))
        for server in servers {
            let members = all.filter { !$0.orphan && root(of: $0.pid) == server.pid }
            placed.formUnion(members.map(\.pid))
            groups.append(.init(kind: .server, session: sessions.first { $0.sessionId == server.sessionId }, processes: tree(from: [server], within: members)))
        }
        let rest = all.filter { !placed.contains($0.pid) }
        if !rest.isEmpty {
            let roots = rest.filter { process in process.owner.map { owner in !rest.contains { $0.pid == owner } } ?? true }
            groups.append(.init(kind: .other, processes: tree(from: roots, within: rest)))
        }
        return SimToolProcessList(groups: groups, pid: ownPID, home: home, takenAt: now)
    }

    private static func earlier(_ first: SimToolProcess, _ second: SimToolProcess) -> Bool {
        ((first.startedAt ?? .distantPast), first.pid) < ((second.startedAt ?? .distantPast), second.pid)
    }

    /// `simtool-direct-hid-7-2ec7d869e3ed-arm64` → `direct-hid helper`: the
    /// words before the version.
    static func helperName(_ path: String) -> String {
        let parts = (path as NSString).lastPathComponent.dropFirst("simtool-".count).split(separator: "-")
        let words = parts.prefix { !$0.allSatisfy(\.isNumber) }
        return (words.isEmpty ? "SimTool" : words.joined(separator: "-")) + " helper"
    }

    /// The words of a command line that say what it does: no options, paths
    /// or UDIDs — `app launch`, `spawn log stream`.
    static func words(_ arguments: [String], limit: Int) -> [String] {
        var result: [String] = []
        for argument in arguments {
            if argument.hasPrefix("-") || argument == "--" { break }
            guard !argument.contains("/"), !isUDID(argument), !argument.isEmpty else { continue }
            result.append(argument)
            if result.count == limit { break }
        }
        return result
    }

    static func option(_ long: String, _ short: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == long || argument == short { return arguments.indices.contains(index + 1) ? arguments[index + 1] : nil }
            if argument.hasPrefix(long + "=") { return String(argument.dropFirst(long.count + 1)) }
        }
        return nil
    }

    static func isUDID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }

    /// The UDID in a path under CoreSimulator's `Devices/<UDID>/`.
    static func devicesUDID(_ path: String) -> String? {
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(of: "Devices"), components.indices.contains(index + 1) else { return nil }
        let candidate = String(components[index + 1])
        return isUDID(candidate) ? candidate : nil
    }
}
