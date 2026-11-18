import Foundation

/// The app a server serves: the viewer's attached app (`/config`'s `logApp`),
/// what its Logs capture scopes to, and what a route that names no app acts
/// on. `serve --app` names it as the server starts. A build installed from a
/// URL and launched takes its place — a site that hands out simulators starts
/// them with no `--app`, and the build someone picked there is the app under
/// test from then on.
///
/// The server arms the loggers of an app it took on that way in every launch
/// it makes of it, as `serve --app` arms its app's from the server's own
/// environment: the app reports its calls and state to this server, also
/// after it came back with the simulator.
final class ServedApp: @unchecked Sendable {
    private let lock = NSLock()
    private var bundleId: String?
    /// Taken on from an install: the server arms its loggers itself.
    private var armed = false

    init(_ bundleId: String?) {
        self.bundleId = bundleId.flatMap { $0.isEmpty ? nil : $0 }
    }

    var current: String? {
        lock.withLock { bundleId }
    }

    /// Takes on `bundleId`, launched from an install; answers whether the
    /// served app changed.
    @discardableResult
    func takeOn(_ bundleId: String) -> Bool {
        lock.withLock {
            defer {
                self.bundleId = bundleId
                armed = true
            }
            return self.bundleId != bundleId
        }
    }

    /// Whether a launch of `bundleId` gets the loggers from the server.
    func armsLoggers(of bundleId: String) -> Bool {
        lock.withLock { armed && self.bundleId == bundleId }
    }
}
