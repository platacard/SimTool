import Foundation

/// One launch of an app through SimTool, as it was launched: the app, its
/// argv and environment, and its process. A SimTool server keeps the last
/// one, so the same app comes back the same way once its simulator was off
/// and is on again.
public struct AppLaunchRecord: Codable, Equatable, Sendable {
    public var bundleId: String
    public var arguments: [String]
    /// The launch's own variables, without the `SIMCTL_CHILD_` prefix.
    public var environment: [String: String]
    /// The app's process — a process of the Mac — when the launch said it.
    public var pid: Int?

    public init(bundleId: String, arguments: [String] = [], environment: [String: String] = [:], pid: Int? = nil) {
        self.bundleId = bundleId
        self.arguments = arguments
        self.environment = environment
        self.pid = pid
    }

    /// `simctl launch` answers `<bundle id>: <pid>`.
    public static func pid(fromLaunchOutput output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.lastIndex(of: ":") else { continue }
            if let pid = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)), pid > 0 { return pid }
        }
        return nil
    }
}

/// Whether an app runs on a simulator right now, from its `launchd`:
/// `UIKitApplication:<bundle id>[…]` with a pid, or `-` once it ended.
public enum SimulatorAppProcess {
    /// Nil when the simulator could not be asked — it is off, or `simctl` failed.
    public static func isRunning(bundleId: String, deviceUDID: String) async -> Bool? {
        guard let output = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "spawn", deviceUDID, "launchctl", "list"],
            timeoutSeconds: 5
        ), output.status == 0 else { return nil }
        return isRunning(bundleId: bundleId, launchctlList: output.stdoutString)
    }

    public static func isRunning(bundleId: String, launchctlList: String) -> Bool {
        let label = "UIKitApplication:" + bundleId + "["
        for line in launchctlList.split(whereSeparator: \.isNewline) where line.contains(label) {
            let pid = line.split(separator: "\t", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if Int(pid) != nil { return true }
        }
        return false
    }
}
