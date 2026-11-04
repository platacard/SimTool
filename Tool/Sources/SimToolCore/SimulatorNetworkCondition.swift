import CryptoKit
import Foundation

/// A network to emulate for an app on the simulator: bandwidth, delay and
/// loss each way, as Network Link Conditioner's profiles describe a link.
public struct NetworkCondition: Codable, Equatable, Sendable {
    /// A preset's id (`3g`, `edge`, …) or `custom`.
    public let profile: String
    public let title: String
    /// Kilobits per second; 0 is no limit.
    public let downKbps: Double
    public let upKbps: Double
    /// Milliseconds added to what arrives / what leaves.
    public let downDelayMs: Double
    public let upDelayMs: Double
    /// Percent of what arrives / leaves that is lost; 100 is no network.
    public let downLoss: Double
    public let upLoss: Double
    /// `3G — ↓780 kbps 100 ms · ↑330 kbps 100 ms`, for whoever shows it.
    public let summary: String

    public init(profile: String, title: String, downKbps: Double = 0, upKbps: Double = 0, downDelayMs: Double = 0, upDelayMs: Double = 0, downLoss: Double = 0, upLoss: Double = 0) {
        self.profile = profile
        self.title = title
        self.downKbps = max(0, downKbps)
        self.upKbps = max(0, upKbps)
        self.downDelayMs = max(0, downDelayMs)
        self.upDelayMs = max(0, upDelayMs)
        self.downLoss = min(100, max(0, downLoss))
        self.upLoss = min(100, max(0, upLoss))
        self.summary = Self.summary(title: title, downKbps: self.downKbps, upKbps: self.upKbps, downDelayMs: self.downDelayMs, upDelayMs: self.upDelayMs, downLoss: self.downLoss, upLoss: self.upLoss)
    }

    /// Network Link Conditioner's presets, by the same names and numbers.
    public static let presets: [NetworkCondition] = [
        NetworkCondition(profile: "loss-100", title: "100% Loss", downLoss: 100, upLoss: 100),
        NetworkCondition(profile: "3g", title: "3G", downKbps: 780, upKbps: 330, downDelayMs: 100, upDelayMs: 100),
        NetworkCondition(profile: "dsl", title: "DSL", downKbps: 2_000, upKbps: 256, downDelayMs: 5, upDelayMs: 5),
        NetworkCondition(profile: "edge", title: "Edge", downKbps: 240, upKbps: 200, downDelayMs: 400, upDelayMs: 440),
        NetworkCondition(profile: "lte", title: "LTE", downKbps: 50_000, upKbps: 10_000, downDelayMs: 50, upDelayMs: 65),
        NetworkCondition(profile: "very-bad", title: "Very Bad Network", downKbps: 1_000, upKbps: 1_000, downDelayMs: 500, upDelayMs: 500, downLoss: 10, upLoss: 10),
        NetworkCondition(profile: "wifi", title: "Wi-Fi", downKbps: 40_000, upKbps: 33_000, downDelayMs: 1, upDelayMs: 1),
    ]

    /// A preset by its id or its title, loosely: `3G`, `very bad`, `100%`.
    public static func preset(named raw: String) -> NetworkCondition? {
        let key = normalized(raw)
        let aliases: [String: String] = ["100loss": "loss-100", "100": "loss-100", "loss": "loss-100", "offline": "loss-100", "verybadnetwork": "very-bad", "bad": "very-bad", "4g": "lte"]
        let wanted = aliases[key] ?? key
        return presets.first { normalized($0.profile) == normalized(wanted) || normalized($0.title) == normalized(wanted) }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func summary(title: String, downKbps: Double, upKbps: Double, downDelayMs: Double, upDelayMs: Double, downLoss: Double, upLoss: Double) -> String {
        if downLoss >= 100 && upLoss >= 100 { return title + " — nothing gets through" }
        func side(_ arrow: String, _ kbps: Double, _ delay: Double, _ loss: Double) -> String {
            var parts: [String] = []
            parts.append(kbps > 0 ? Self.rate(kbps) : "any rate")
            if delay > 0 { parts.append(Self.number(delay) + " ms") }
            if loss > 0 { parts.append(Self.number(loss) + "% loss") }
            return arrow + parts.joined(separator: " ")
        }
        return title + " — " + side("↓", downKbps, downDelayMs, downLoss) + " · " + side("↑", upKbps, upDelayMs, upLoss)
    }

    static func rate(_ kbps: Double) -> String {
        kbps >= 1_000 ? number(kbps / 1_000) + " Mbps" : number(kbps) + " kbps"
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// An app the conditioner is loaded into: it takes every change at once.
public struct NetworkConditionClient: Codable, Equatable, Sendable {
    public var bundleId: String
    public var pid: Int
    /// Connections it shaped since it started.
    public var connections: Int

    public init(bundleId: String, pid: Int, connections: Int) {
        self.bundleId = bundleId
        self.pid = pid
        self.connections = connections
    }
}

/// `GET /api/v1/network/condition`: what is emulated (nil: the network as it
/// is), the apps that have it, and the presets to pick from.
public struct NetworkConditionState: Codable, Equatable, Sendable {
    public var condition: NetworkCondition?
    public var apps: [NetworkConditionClient]
    public var presets: [NetworkCondition]
    /// Who it reaches: the apps SimTool launched on this simulator — never the
    /// Mac, another simulator or this one's system services.
    public var scope: String

    public init(condition: NetworkCondition?, apps: [NetworkConditionClient], presets: [NetworkCondition] = NetworkCondition.presets, scope: String = SimulatorNetworkConditioner.scope) {
        self.condition = condition
        self.apps = apps
        self.presets = presets
        self.scope = scope
    }

    public var summary: String {
        condition?.summary ?? "Off — the network as it is"
    }
}

/// `POST /api/v1/network/condition`: a preset by name, or the numbers of a
/// custom link; `relaunch` launches the server's app again so it has it.
public struct NetworkConditionRequest: Codable, Equatable, Sendable {
    public var profile: String?
    public var downKbps: Double?
    public var upKbps: Double?
    public var delayMs: Double?
    public var downDelayMs: Double?
    public var upDelayMs: Double?
    public var loss: Double?
    public var downLoss: Double?
    public var upLoss: Double?
    public var relaunch: Bool?

    public init(profile: String? = nil, downKbps: Double? = nil, upKbps: Double? = nil, delayMs: Double? = nil, downDelayMs: Double? = nil, upDelayMs: Double? = nil, loss: Double? = nil, downLoss: Double? = nil, upLoss: Double? = nil, relaunch: Bool? = nil) {
        self.profile = profile
        self.downKbps = downKbps
        self.upKbps = upKbps
        self.delayMs = delayMs
        self.downDelayMs = downDelayMs
        self.upDelayMs = upDelayMs
        self.loss = loss
        self.downLoss = downLoss
        self.upLoss = upLoss
        self.relaunch = relaunch
    }

    /// The condition asked for: a preset (its numbers overridden by any given),
    /// `off` (nil), or a custom link from the numbers alone. `delayMs` / `loss`
    /// set both ways.
    public func resolve() throws -> NetworkCondition? {
        let name = profile?.trimmingCharacters(in: .whitespaces) ?? ""
        if ["off", "none", "normal"].contains(name.lowercased()) { return nil }
        var condition: NetworkCondition
        if name.isEmpty || name.lowercased() == "custom" {
            guard [downKbps, upKbps, delayMs, downDelayMs, upDelayMs, loss, downLoss, upLoss].contains(where: { $0 != nil }) else {
                throw SimToolError("Name a profile (\(NetworkCondition.presets.map(\.profile).joined(separator: ", ")), off) or give a link: downKbps, upKbps, delayMs, loss")
            }
            condition = NetworkCondition(profile: "custom", title: "Custom")
        } else {
            guard let preset = NetworkCondition.preset(named: name) else {
                throw SimToolError("Unknown network profile '\(name)'. Profiles: \(NetworkCondition.presets.map(\.profile).joined(separator: ", ")), off — or custom numbers.")
            }
            condition = preset
        }
        for value in [downKbps, upKbps, delayMs, downDelayMs, upDelayMs, loss, downLoss, upLoss].compactMap({ $0 }) where !value.isFinite || value < 0 {
            throw SimToolError("Network numbers must be zero or more, got \(value)")
        }
        let custom = condition.profile == "custom" || [downKbps, upKbps, delayMs, downDelayMs, upDelayMs, loss, downLoss, upLoss].contains { $0 != nil }
        return NetworkCondition(
            profile: custom && condition.profile != "custom" ? condition.profile + "+" : condition.profile,
            title: custom && condition.profile != "custom" ? condition.title + " (adjusted)" : condition.title,
            downKbps: downKbps ?? condition.downKbps,
            upKbps: upKbps ?? condition.upKbps,
            downDelayMs: downDelayMs ?? delayMs ?? condition.downDelayMs,
            upDelayMs: upDelayMs ?? delayMs ?? condition.upDelayMs,
            downLoss: downLoss ?? loss ?? condition.downLoss,
            upLoss: upLoss ?? loss ?? condition.upLoss
        )
    }
}

/// Emulates a bad network for the apps SimTool launches on one simulator,
/// and only for them. A simulator's apps are processes of the Mac on the
/// Mac's own network stack, so nothing in the device can slow them, and
/// anything on the Mac's side — Network Link Conditioner, `dnctl`/`pfctl` —
/// slows the whole Mac, every simulator of every checkout with it, and needs
/// an administrator. Instead SimTool loads a library into the app it launches
/// (`DYLD_INSERT_LIBRARIES`, as for the camera) that holds the app's own
/// sockets to the condition: the delay each way, the bandwidth of one link the
/// app's connections share, lost packets — a lost TCP segment costs a
/// retransmission's wait, a lost datagram is gone — and at 100% loss nothing
/// gets through until it times out. Loopback is never touched, so SimTool's
/// own loggers keep reporting.
///
/// The condition lives per device in `~/Library/Caches/SimTool/NetworkConditions/<udid>/`:
/// `condition.json`, read by the apps every half second, and
/// `clients/<pid>.json`, each app that has the library. An app launched while
/// the condition is off, or by something other than SimTool, gets it at its
/// next launch through SimTool.
public enum SimulatorNetworkConditioner {
    public static let scope = "The apps SimTool launches on this simulator — not the Mac, other simulators or this one's system services."

    private static let injectorVersion = "1"
    private static let injectorFingerprint = SHA256.hash(data: Data(SimulatorNetworkConditionerSource.source.utf8))
        .prefix(6).map { String(format: "%02x", $0) }.joined()

    public static func directory(deviceUDID: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("SimTool/NetworkConditions/\(deviceUDID)", isDirectory: true)
    }

    private struct Stored: Codable {
        var active: Bool
        var condition: NetworkCondition?
        // What the library reads, flat.
        var downKbps: Double
        var upKbps: Double
        var downDelayMs: Double
        var upDelayMs: Double
        var downLoss: Double
        var upLoss: Double
    }

    public static func condition(deviceUDID: String) -> NetworkCondition? {
        guard let data = try? Data(contentsOf: directory(deviceUDID: deviceUDID).appendingPathComponent("condition.json")),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.active else { return nil }
        return stored.condition
    }

    public static func state(deviceUDID: String, now: Date = Date()) -> NetworkConditionState {
        NetworkConditionState(condition: condition(deviceUDID: deviceUDID), apps: clients(deviceUDID: deviceUDID, now: now))
    }

    /// Sets the condition (nil: off). Apps that have the library take it
    /// within half a second; the library is built first, so the next launch
    /// has it.
    @discardableResult
    public static func set(_ condition: NetworkCondition?, deviceUDID: String) async throws -> NetworkConditionState {
        if condition != nil { _ = try await injectorURL() }
        try write(condition, deviceUDID: deviceUDID)
        return state(deviceUDID: deviceUDID)
    }

    /// Off, without building anything: what a server does as it starts and stops.
    public static func off(deviceUDID: String) {
        guard FileManager.default.fileExists(atPath: directory(deviceUDID: deviceUDID).appendingPathComponent("condition.json").path) else { return }
        try? write(nil, deviceUDID: deviceUDID)
    }

    private static func write(_ condition: NetworkCondition?, deviceUDID: String) throws {
        let directory = directory(deviceUDID: deviceUDID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = Stored(
            active: condition != nil,
            condition: condition,
            downKbps: condition?.downKbps ?? 0,
            upKbps: condition?.upKbps ?? 0,
            downDelayMs: condition?.downDelayMs ?? 0,
            upDelayMs: condition?.upDelayMs ?? 0,
            downLoss: condition?.downLoss ?? 0,
            upLoss: condition?.upLoss ?? 0
        )
        try JSONEncoder().encode(stored).write(to: directory.appendingPathComponent("condition.json"), options: .atomic)
    }

    /// The apps that have the library: those that spoke in the last five
    /// seconds, or whose process still runs.
    static func clients(deviceUDID: String, now: Date, startOfProcess: (Int) -> Double? = SimulatorCamera.processStart) -> [NetworkConditionClient] {
        struct Heartbeat: Decodable { var bundleId: String; var pid: Int; var connections: Int; var at: Double }
        let folder = directory(deviceUDID: deviceUDID).appendingPathComponent("clients", isDirectory: true)
        var newest: [String: (client: NetworkConditionClient, at: Double)] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let beat = try? JSONDecoder().decode(Heartbeat.self, from: data) else { continue }
            let fresh = now.timeIntervalSince1970 - beat.at <= 5
            guard fresh || (startOfProcess(beat.pid).map { $0 <= beat.at } ?? false) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if let known = newest[beat.bundleId], known.at >= beat.at { continue }
            newest[beat.bundleId] = (NetworkConditionClient(bundleId: beat.bundleId, pid: beat.pid, connections: beat.connections), beat.at)
        }
        return newest.values.map(\.client).sorted { $0.pid < $1.pid }
    }

    /// What an app launched now needs to be held to the condition: nothing
    /// while it is off. `environment` is the launch's own; a library it
    /// already inserts stays first.
    public static func launchEnvironment(deviceUDID: String, merging environment: [String: String] = [:]) -> [String: String] {
        var result = environment
        guard condition(deviceUDID: deviceUDID) != nil, let injector = builtInjector() else { return result }
        let existing = environment["DYLD_INSERT_LIBRARIES"].flatMap { $0.isEmpty ? nil : $0 }
        result["DYLD_INSERT_LIBRARIES"] = [existing, injector.path].compactMap { $0 }.joined(separator: ":")
        result["SIMTOOL_NETCOND_DIR"] = directory(deviceUDID: deviceUDID).path
        return result
    }

    private static func injectorLocation() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SimTool/SimulatorHelpers/simtool-netcond-\(injectorVersion)-\(injectorFingerprint).dylib")
    }

    private static func builtInjector() -> URL? {
        guard let url = injectorLocation(), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The library, built for the simulator once per source — both
    /// architectures, so an app under Rosetta takes it too — ad-hoc signed and
    /// cached beside the other helpers. Several processes may build it at
    /// once: each writes its own files and renames the result into place.
    public static func injectorURL() async throws -> URL {
        if let built = builtInjector() { return built }
        guard let output = injectorLocation() else { throw SimToolError("Failed to locate user caches directory") }
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unique = UUID().uuidString
        let source = directory.appendingPathComponent("\(output.lastPathComponent).\(unique).c")
        let temporary = directory.appendingPathComponent("\(output.lastPathComponent).tmp.\(unique)")
        try SimulatorNetworkConditionerSource.source.write(to: source, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: temporary)
        }
        let built = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--sdk", "iphonesimulator", "clang", "-arch", "arm64", "-arch", "x86_64", "-mios-simulator-version-min=16.0", "-O2", "-dynamiclib",
                        "-framework", "CoreFoundation", "-Wl,-adhoc_codesign", "-o", temporary.path, source.path],
            timeoutSeconds: 120
        )
        guard built.status == 0 else {
            throw SimToolError(built.stderrString.isEmpty ? "Failed to build the network conditioner" : built.stderrString)
        }
        guard rename(temporary.path, output.path) == 0 else {
            throw SimToolError("Failed to install the network conditioner: \(String(cString: strerror(errno)))")
        }
        return output
    }
}

/// What every app SimTool launches gets in its environment: the camera and
/// the network conditions of its simulator, when they are set.
public enum SimToolLaunchEnvironment {
    public static func forApp(deviceUDID: String, merging environment: [String: String] = [:], cameraEvenWhenOff: Bool = false) -> [String: String] {
        let camera = SimulatorCamera.launchEnvironment(deviceUDID: deviceUDID, merging: environment, evenWhenOff: cameraEvenWhenOff)
        return SimulatorNetworkConditioner.launchEnvironment(deviceUDID: deviceUDID, merging: camera)
    }
}
