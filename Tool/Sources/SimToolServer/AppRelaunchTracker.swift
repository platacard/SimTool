import Foundation
import SimToolCore

/// The app a server brings back when its simulator comes back on.
///
/// A simulator that goes off — SimTool shuts it down once it sits unused, or
/// something outside SimTool does — takes its apps with it, and the next boot
/// starts at the home screen with SimTool attached to nothing. So the server
/// keeps the last launch it heard of (its own Launch, the viewer's stdout
/// capture, `simtool app launch`, a test run) and, if that app was running when
/// the simulator went off, launches it again the same way once it is on: the
/// same argv and environment, the loggers armed, the camera and the network
/// conditions as they are now.
///
/// "Was running" is asked of the simulator itself when it can still answer
/// (SimTool shutting it down); once it is already gone (shut down outside), the
/// last look at the app's process decides, and with no process known a launch
/// SimTool made counts as running. An app terminated through SimTool since its
/// launch does not come back.
final class AppRelaunchTracker: @unchecked Sendable {
    private let lock = NSLock()
    /// The server's own app (`--app`): what comes back when no launch was heard of.
    private let defaultApp: String?
    private var last: AppLaunchRecord?
    private var terminated = false
    /// The last look at the launch's process; nil before one, or with no pid.
    private var alive: Bool?
    private var pending: AppLaunchRecord?
    private var launches = 0

    init(defaultApp: String?) {
        self.defaultApp = defaultApp.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Bumped by every launch heard of: a relaunch that waited sees whether
    /// someone else launched an app meanwhile.
    var generation: Int {
        lock.withLock { launches }
    }

    /// The launch an app of `bundleId` would get again: the last one's, when
    /// it was of that app.
    func launch(of bundleId: String) -> AppLaunchRecord? {
        lock.withLock { last?.bundleId == bundleId ? last : nil }
    }

    func launched(_ record: AppLaunchRecord) {
        lock.withLock {
            last = record
            terminated = false
            alive = record.pid == nil ? nil : true
            pending = nil
            launches += 1
        }
    }

    func terminated(bundleId: String) {
        lock.withLock {
            if (last?.bundleId ?? defaultApp) == bundleId { terminated = true }
        }
    }

    /// Looks at the launch's process, while the simulator is on.
    func sample(isAlive: (Int) -> Bool) {
        lock.withLock {
            guard let pid = last?.pid else { return }
            alive = isAlive(pid)
        }
    }

    /// What would come back, and whether it is worth asking the simulator about.
    var candidate: AppLaunchRecord? {
        lock.withLock { terminated ? nil : (last ?? defaultApp.map { AppLaunchRecord(bundleId: $0) }) }
    }

    /// The simulator went off. `runningNow` is the simulator's own answer, when
    /// it could still give one.
    func wentOff(runningNow: Bool?) {
        lock.withLock {
            guard !terminated, let candidate = last ?? defaultApp.map({ AppLaunchRecord(bundleId: $0) }) else {
                pending = nil
                return
            }
            // Gone already: the last look decides; a launch SimTool made with no
            // process known counts as running, the server's app it never
            // launched does not.
            let wasRunning = runningNow ?? alive ?? (last != nil)
            pending = wasRunning ? candidate : nil
        }
    }

    /// The launch to make now that the simulator is on, once.
    func takePending() -> AppLaunchRecord? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }
}
