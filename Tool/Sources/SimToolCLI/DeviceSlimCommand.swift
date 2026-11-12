import ArgumentParser
import Foundation
import SimToolCore

/// The simulator itself, beyond its settings: what runs in it.
struct DeviceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device",
        abstract: "The simulator itself: what runs in it.",
        subcommands: [Slim.self]
    )
}

extension DeviceCommand {
    struct Slim: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "slim",
            abstract: "Turn off the background services an app under test does not need: about 4 GB of memory down to under 1.",
            discussion: """
            A stock iOS 26 simulator runs some 280 processes — widgets and \
            wallpaper posters, Siri and on-device intelligence, Spotlight, \
            iCloud, photo analysis, News, Health… — and keeps about 4 GB in \
            them; slim, about 85 and under 1 GB, and a boot costs a third of \
            the CPU. Apps launch, take touches and keys and reach the network as \
            before.

            By default it keeps on what apps under test reach for: push \
            notifications, universal links, StoreKit testing, the photo picker, \
            Contacts and Calendar. --keep leaves more on — a category or a \
            service, repeated or comma-separated — and --all turns off the \
            whole catalog. --off brings everything back; --status says what \
            is off.

            The list belongs to the simulator and holds through reboots and \
            `simctl erase`, from the next boot: a booted simulator is shut down \
            and booted again (a viewer watching it shows it off for a moment), \
            and then reports what is off; a shut-down one boots slim the next \
            time — before its first boot is best, it skips most of what a first \
            boot does. iOS 18.5 and later.

            Categories: widgets, siri, search, icloud, store, pim, web, family, \
            health, photos, apps, messaging, connectivity, telemetry, mdm, other.
            """
        )

        @Option var device: String?
        @Option(help: "A category or a service to leave on as well (repeat, or comma-separate).") var keep: [String] = []
        @Flag(help: "Turn off the whole catalog, push, universal links, StoreKit, the photo picker, Contacts and Calendar included.") var all = false
        @Flag(help: "Bring every service back.") var off = false
        @Flag(help: "Say what is off, without changing anything.") var status = false
        @OptionGroup var common: CommonJSON

        func validate() throws {
            if status, off || all || !keep.isEmpty { throw ValidationError("--status changes nothing: it takes no --off, --all or --keep") }
            if off, all || !keep.isEmpty { throw ValidationError("--off brings everything back: it takes no --all or --keep") }
        }

        func run() async throws {
            let config = try ProjectConfigLoader.loadIfPresent()
            let device = try await SimulatorDeviceClient.resolve(device, configuredSimulator: config?.simulator)
            if let refusal = SimulatorSlimming.refusal(runtime: device.runtime) { throw SimToolError(refusal) }
            let url = SimulatorSlimming.overridesURL(udid: device.udid)
            let booted = device.state == "Booted"
            let managed = SimulatorSlimming.managedLabels

            if status {
                let off = try booted ? await Self.reportedOff(device.udid) : Self.writtenOff(url)
                try emit(Self.payload(device, off: off.intersection(managed), url: url, rebooted: false, verified: booted ? true : nil, mismatched: nil))
                return
            }

            let wanted = off ? Set<String>() : try SimulatorSlimming.labelsToTurnOff(all: all, keep: keep)
            let written = try Self.writtenOff(url)
            if written == wanted, booted {
                // Nothing to write: only to read back, without a reboot.
                let reported = try await Self.reportedOff(device.udid).intersection(managed)
                if reported == wanted {
                    try emit(Self.payload(device, off: wanted, url: url, rebooted: false, verified: true, mismatched: nil))
                    return
                }
            }
            guard booted else {
                try SimulatorSlimming.writeOverrides(off: wanted, at: url)
                try emit(Self.payload(device, off: wanted, url: url, rebooted: false, verified: nil, mismatched: nil))
                return
            }

            // Written while the simulator is down: its launchd reads the list
            // as it boots, and keeps its own copy while it runs.
            let held = SimulatorLeaseStore.shared.lease(udid: device.udid) != nil
            FileHandle.standardError.write(Data("Shutting \(device.name) down to change what runs in it; it boots again.\n".utf8))
            guard await SimulatorDeviceClient.shutdown(device.udid) else {
                throw SimToolError("Could not shut \(device.name) (\(device.udid)) down; nothing was changed")
            }
            try SimulatorSlimming.writeOverrides(off: wanted, at: url)
            var down = device
            down.state = "Shutdown"
            // Booted again as it was: SimTool's to shut down when idle only
            // if it was before.
            _ = try await SimulatorDeviceClient.ensureBooted(down, lease: held)
            if held { LeaseReaper.ensureRunning() }
            let reported = try await Self.reportedOff(device.udid).intersection(managed)
            let mismatched = reported.symmetricDifference(wanted).sorted()
            try emit(Self.payload(device, off: wanted, url: url, rebooted: true, verified: mismatched.isEmpty, mismatched: mismatched.isEmpty ? nil : mismatched))
        }

        private func emit(_ payload: SimulatorSlimPayload) throws {
            if common.json { try printJSON(payload) } else { print(Self.report(payload)) }
            if payload.verified == false {
                throw SimToolError("\(payload.name) does not report \(payload.mismatched?.count ?? 0) of the services as written — its runtime may not read the list")
            }
        }

        static func payload(_ device: SimulatorDevice, off: Set<String>, url: URL, rebooted: Bool, verified: Bool?, mismatched: [String]?) -> SimulatorSlimPayload {
            let summary = SimulatorSlimming.summary(off: off)
            return SimulatorSlimPayload(
                udid: device.udid, name: device.name, servicesOff: off.count,
                categoriesOff: summary.off, categoriesPartly: summary.partly, categoriesOn: summary.on,
                rebooted: rebooted, verified: verified, mismatched: mismatched, overrides: url.path
            )
        }

        /// The catalog's labels the list on the host turns off.
        static func writtenOff(_ url: URL) throws -> Set<String> {
            Set(try SimulatorSlimming.readOverrides(at: url).filter(\.value).keys).intersection(SimulatorSlimming.managedLabels)
        }

        /// What the booted simulator's launchd says is off.
        static func reportedOff(_ udid: String) async throws -> Set<String> {
            let output = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["simctl", "spawn", udid, "launchctl", "print-disabled", "system"],
                timeoutSeconds: 120
            )
            guard output.status == 0 else {
                throw SimToolError("Could not read what is off in \(udid): \(output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return Set(SimulatorSlimming.parsePrintDisabled(output.stdoutString).filter(\.value).keys)
        }

        static func report(_ payload: SimulatorSlimPayload) -> String {
            let who = "\(payload.name) (\(payload.udid))"
            guard payload.servicesOff > 0 else {
                return who + ": every service on" + (payload.rebooted ? " — rebooted." : (payload.verified == nil ? ", from its next boot." : "."))
            }
            var lines = [who + ": \(payload.servicesOff) services off" + (payload.verified == nil && !payload.rebooted ? ", from its next boot." : ".")]
            let effects = Dictionary(uniqueKeysWithValues: SimulatorSlimming.categories.map { ($0.id, $0.effect) })
            for id in payload.categoriesOff { lines.append("  off    \(id.padding(toLength: 13, withPad: " ", startingAt: 0)) \(effects[id] ?? "")") }
            for id in payload.categoriesPartly { lines.append("  partly \(id)") }
            if !payload.categoriesOn.isEmpty { lines.append("  on     " + payload.categoriesOn.joined(separator: ", ")) }
            let kept = SimulatorSlimming.keptServices.filter { label, _ in
                SimulatorSlimming.categories.contains { payload.categoriesPartly.contains($0.id) && $0.labels.contains(label) }
            }
            if !kept.isEmpty {
                let reasons = Dictionary(grouping: kept, by: \.why).map { why, services in "\(why) (\(services.map { $0.label.replacingOccurrences(of: "com.apple.", with: "") }.joined(separator: ", ")))" }
                lines.append("  kept on: " + reasons.sorted().joined(separator: "; "))
            }
            if payload.rebooted { lines.append(payload.verified == true ? "Rebooted it; it reports them off." : "Rebooted it.") }
            return lines.joined(separator: "\n")
        }
    }
}
