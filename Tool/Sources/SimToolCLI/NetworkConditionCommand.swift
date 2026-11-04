import ArgumentParser
import Foundation
import SimToolClient
import SimToolCore

/// `simtool network condition`: Network Link Conditioner for the apps SimTool
/// launches on one simulator.
struct NetworkConditionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "condition",
        abstract: "Emulate a bad network — 3G, Edge, Very Bad Network, 100% Loss or your own numbers — for the apps SimTool launches on a simulator.",
        discussion: """
        Network Link Conditioner's profiles, for the app on this simulator only: \
        the delay each way, the bandwidth of the link, lost packets — at 100% \
        loss nothing gets through until it times out. It reaches the apps SimTool \
        launches on this simulator (`simtool app launch`, the viewer's Launch, \
        test runs) and nothing else: not the Mac, not another simulator, not this \
        one's system services, and SimTool's own loggers keep reporting. An app \
        launched while it was off gets it at its next launch through SimTool \
        (`--relaunch` does that now); an app that has it takes every change at \
        once, Off included. A server watching the device turns it off when it \
        stops.

          simtool network condition                 # what is emulated, and which apps have it
          simtool network condition list            # the profiles
          simtool network condition 3g --relaunch   # 3G, and the app launched again to take it
          simtool network condition edge
          simtool network condition very-bad
          simtool network condition 100%            # 100% Loss
          simtool network condition custom --down 512 --up 128 --delay 300 --loss 2
          simtool network condition 3g --delay 800  # a profile with one number changed
          simtool network condition off
        """
    )

    @Argument(help: "A profile (3g, dsl, edge, lte, very-bad, wifi, 100%), custom, off, or list. Nothing: show it.") var profile: String?
    @Option(help: "Downlink, kilobits per second (0: no limit).") var down: Double?
    @Option(help: "Uplink, kilobits per second (0: no limit).") var up: Double?
    @Option(help: "Delay each way, milliseconds.") var delay: Double?
    @Option(name: .customLong("down-delay"), help: "Delay of what arrives, milliseconds.") var downDelay: Double?
    @Option(name: .customLong("up-delay"), help: "Delay of what leaves, milliseconds.") var upDelay: Double?
    @Option(help: "Packets lost each way, percent.") var loss: Double?
    @Flag(help: "Launch the server's app again — as it was last launched — when it does not have the conditions yet.") var relaunch = false
    @Option var device: String?
    @OptionGroup var common: CommonJSON

    func run() async throws {
        if profile?.lowercased() == "list" {
            if common.json { try printJSON(NetworkCondition.presets); return }
            for preset in NetworkCondition.presets { print(preset.profile.padding(toLength: 10, withPad: " ", startingAt: 0) + preset.summary) }
            return
        }
        let device = try await resolveDeviceToDrive(device)
        let udid = device.udid
        // A server watching the device owns the conditions: it tells its
        // viewers, puts the change in Activity and can relaunch its app.
        let server = ActivityReporter(device: device).servers.first.map { SimToolClient(baseURL: $0) }
        let numbers = [down, up, delay, downDelay, upDelay, loss].contains { $0 != nil }
        guard profile != nil || numbers else {
            try show(try await server?.networkCondition() ?? SimulatorNetworkConditioner.state(deviceUDID: udid))
            return
        }
        let request = NetworkConditionRequest(
            profile: profile ?? "custom",
            downKbps: down, upKbps: up, delayMs: delay, downDelayMs: downDelay, upDelayMs: upDelay, loss: loss,
            relaunch: relaunch
        )
        if let server {
            try show(try await server.setNetworkCondition(request))
            return
        }
        if relaunch { throw ValidationError("--relaunch needs a SimTool server watching the device; launch the app with `simtool app launch`.") }
        try show(try await SimulatorNetworkConditioner.set(request.resolve(), deviceUDID: udid))
    }

    private func show(_ state: NetworkConditionState) throws {
        if common.json { try printJSON(state); return }
        var lines: [(String, String)] = [("network", state.summary)]
        let apps = state.apps.map { "\($0.bundleId) (pid \($0.pid), \($0.connections) connection\($0.connections == 1 ? "" : "s"))" }.joined(separator: ", ")
        if state.condition != nil {
            lines.append(("apps", state.apps.isEmpty ? "none yet — an app gets it at its next launch through SimTool (--relaunch, simtool app launch)" : apps))
        } else if !state.apps.isEmpty {
            lines.append(("apps", apps + " — on the network as it is"))
        }
        lines.append(("reaches", state.scope))
        let width = lines.map(\.0.count).max() ?? 0
        for (name, value) in lines { print(name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value) }
    }
}
