import ArgumentParser
import Foundation
import SimToolCore

struct Ps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ps",
        abstract: "List every SimTool process on this Mac — servers from any simtool binary, their helpers, the reaper, commands — and the orphans.",
        discussion: """
        A server is listed with what runs for it: its HID and fold helpers, the \
        `simctl spawn` that runs a helper inside the simulator, its log streams. \
        An orphan is a helper whose server or command is gone — nothing will \
        stop it. `simtool kill <pid>` stops one process and what runs for it; \
        `simtool kill --orphans` stops every orphan. The viewer shows the same \
        list: click the server's address in its status bar.
        """
    )

    @OptionGroup var common: CommonJSON

    func run() throws {
        let list = SimToolProcessDiscovery.take()
        if common.json {
            try printJSON(list)
        } else if list.processes.isEmpty {
            makeNoora().info("No SimTool process is running.")
        } else {
            makeNoora().table(headers: ["PID", "Process", "Simulator", "Up", "Server", "Binary"], rows: Self.rows(list))
            if list.orphans > 0 {
                makeNoora().warning("\(list.orphans) orphaned: simtool kill --orphans stops them.")
            }
        }
    }

    static func rows(_ list: SimToolProcessList, now: Date = Date()) -> [[String]] {
        list.groups.flatMap { group in
            group.processes.map { process in
                let depth = Self.depth(of: process, in: group.processes)
                let server: String
                switch group.kind {
                case .orphans: server = "orphan"
                case .server: server = Self.port(of: group).map { ":\($0)" } ?? "—"
                case .other: server = ""
                }
                return [
                    "\(process.pid)",
                    String(repeating: "  ", count: depth) + process.name,
                    process.deviceName ?? process.deviceUDID ?? "",
                    process.startedAt.map { SimulatorIdleTimeout.duration(now.timeIntervalSince($0)) } ?? "",
                    server,
                    Self.tilde(process.executable, home: list.home),
                ]
            }
        }
    }

    /// How deep under the group's first process it runs.
    static func depth(of process: SimToolProcess, in members: [SimToolProcess]) -> Int {
        var depth = 0
        var owner = process.owner
        while let pid = owner, let above = members.first(where: { $0.pid == pid }), depth < 8 {
            depth += 1
            owner = above.owner
        }
        return depth
    }

    /// A server group's port: its session's URL, else the `--port` it was started with.
    static func port(of group: SimToolProcessList.Group) -> Int? {
        if let url = group.session.flatMap({ URL(string: $0.url) }), let port = url.port { return port }
        guard let server = group.processes.first, let index = server.arguments.firstIndex(of: "--port"),
              server.arguments.indices.contains(index + 1) else { return nil }
        return Int(server.arguments[index + 1])
    }

    static func tilde(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
