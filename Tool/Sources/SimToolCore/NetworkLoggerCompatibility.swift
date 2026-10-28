import Foundation

/// Whether the network logger an app links and the CLI serving it come from one
/// SimTool release. The app pins the SimTool package, the CLI comes from Homebrew
/// or a mise pin, and nothing else ties the two: a server and a logger from
/// different releases disagree about mocks and events without saying so. Patch
/// releases talk to each other; another major or minor is worth a warning.
public enum NetworkLoggerCompatibility {
    /// The first release whose logger reports its version: one that reports
    /// nothing is older.
    public static let firstReportingRelease = "1.0"

    /// What `simtool doctor` and the viewer say, or nil when the two match.
    /// `reported` is the version the logger sent; nil when it sent none.
    public static func warning(reported: String?, cli: String = SimToolVersion.base) -> String? {
        guard let cliRelease = release(of: cli) else { return nil }
        guard let reported else {
            // A CLI from before 1.0 cannot tell a logger that says nothing from its own.
            guard cliRelease.major >= 1 else { return nil }
            return "The app links a SimToolNetworkLogger older than \(firstReportingRelease), the CLI is \(cliRelease): "
                + "update the app's SimTool package to \(cliRelease)."
        }
        guard let loggerRelease = release(of: reported), loggerRelease != cliRelease else { return nil }
        return "The app links SimToolNetworkLogger \(loggerRelease), the CLI is \(cliRelease): "
            + "pin the app's SimTool package and the CLI to one release."
    }

    struct Release: Equatable, CustomStringConvertible {
        var major: Int
        var minor: Int
        var description: String { "\(major).\(minor)" }
    }

    /// The major and minor of `1.0.0`, `1.0.0-dev`, `1.1-beta.1`.
    static func release(of version: String) -> Release? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1].prefix { $0.isNumber }) else { return nil }
        return Release(major: major, minor: minor)
    }
}

/// What a server last heard from the app's network logger about itself, with
/// every event batch and mock poll.
public final class NetworkLoggerPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var last: NetworkLoggerReportPayload?

    public init() {}

    /// Records what a logger reported — nil when it reported no version. Returns
    /// the new report when it differs from what was heard before, the first one
    /// included, so whoever shows the last one can be told; nil when it repeats.
    @discardableResult
    public func heard(version: String?, at date: Date = Date(), cli: String = SimToolVersion.base) -> NetworkLoggerReportPayload? {
        lock.lock(); defer { lock.unlock() }
        let changed = last == nil || last?.version != version
        let report = NetworkLoggerReportPayload(
            version: version,
            reportedAt: date,
            warning: NetworkLoggerCompatibility.warning(reported: version, cli: cli)
        )
        last = report
        return changed ? report : nil
    }

    public var lastReport: NetworkLoggerReportPayload? {
        lock.lock(); defer { lock.unlock() }
        return last
    }
}
