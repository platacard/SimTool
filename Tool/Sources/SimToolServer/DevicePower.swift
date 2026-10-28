import Foundation
import SimToolCore

/// Whether the server's simulator is on. Once nothing uses it for the idle
/// timeout SimTool shuts it down and the server stays up: the page, its lists
/// and recordings go on answering, the viewer says the simulator is off and
/// offers to start it, and a request that acts on the device starts it — when
/// an agent or the CLI sends it — or is told the simulator is off — when the
/// viewer does, by itself or on a click a person should make on purpose.
final class DevicePower: @unchecked Sendable {
    private let lock = NSLock()
    private var payload = ServerPowerPayload.on

    var current: ServerPowerPayload {
        lock.withLock { payload }
    }

    var isOn: Bool {
        current.state == .on
    }

    func set(_ payload: ServerPowerPayload) {
        lock.withLock { self.payload = payload }
    }

    /// Whether a request acts on the device, which a simulator that is off
    /// cannot answer. `path` has no query.
    static func needsDevice(method: String, path: String) -> Bool {
        deviceRoutes.contains(method + " " + path)
    }

    /// What the viewer is told when it asks for one of them with the simulator off.
    static func refusal(device: String, power: ServerPowerPayload) -> String {
        power.state == .starting
            ? "\(device) is starting — try again in a moment."
            : "\(device) is off. Start it again to do this."
    }

    private static let deviceRoutes: Set<String> = [
        "GET /stream.avcc",
        "POST /api/v1/input",
        "POST /api/v1/input/paste-image",
        "POST /api/v1/photos",
        "GET /api/v1/device",
        "POST /api/v1/device",
        "GET /api/v1/app",
        "POST /api/v1/app/reveal",
        "POST /api/v1/app/install",
        "POST /api/v1/camera",
        "POST /api/v1/camera/webcam",
        "GET /api/v1/ax/tree",
        "GET /api/v1/ax/raw",
        "GET /api/v1/ax/find",
        "POST /api/v1/logs/capture",
        "POST /api/v1/tests/start",
        "POST /api/v1/tests/run",
        "GET /api/v1/screenshot",
        "POST /api/v1/recording",
    ]
}

/// The answer to the viewer asking for the device while the simulator is off.
struct DevicePowerRefusal: Encodable {
    var error: String
    var power: ServerPowerPayload
}

/// The `server` topic as the simulator goes off, starts or comes back on —
/// the server itself is not stopping.
public struct ServerPowerNotice: Encodable, Equatable, Sendable {
    public var stopping = false
    public var power: ServerPowerPayload

    public init(power: ServerPowerPayload) {
        self.power = power
    }
}
