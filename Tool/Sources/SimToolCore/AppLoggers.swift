import Foundation

/// The app-side SimTool loggers an app is launched with: which of them are
/// armed. An app that does not link the logger packages ignores them, and a
/// Release build has them compiled out.
public struct AppLoggers: Equatable, Sendable {
    public var network: Bool
    public var state: Bool

    public init(network: Bool = true, state: Bool = true) {
        self.network = network
        self.state = state
    }

    /// The launch variables that arm them to report to `serverURL` — without
    /// the `SIMCTL_CHILD_` prefix simctl forwards them with. Empty when none is
    /// armed.
    public func launchEnvironment(serverURL: String) -> [String: String] {
        var environment: [String: String] = [:]
        if network { environment["SIMTOOL_NETWORK_LOGGER"] = "1" }
        if state { environment["SIMTOOL_STATE_LOGGER"] = "1" }
        if network || state { environment["SIMTOOL_SERVER_URL"] = serverURL }
        return environment
    }
}
