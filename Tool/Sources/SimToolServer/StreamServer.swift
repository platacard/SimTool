import CoreMedia
import CoreVideo
import Foundation
import SimToolCore
import SimToolNetworkLogger
import SimToolStateLogger
import SimToolStream
import SimToolWeb
import Swifter

public struct StreamServerConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var device: SimulatorDevice
    public var captureEnabled: Bool
    /// When set, log capture defaults to this app (and stdout/print capture) so the
    /// viewers scope to the app's own logs instead of flooding with system OSLog.
    public var defaultLogApp: String?
    /// Where test sessions persist: the project's `.simtool/test-sessions`.
    public var testSessionsRoot: URL
    /// Where declarative YAML UI tests live: the project’s `.simtool/tests`.
    public var testsRoot: URL
    /// Launch profiles from the project config, so a web-triggered run can
    /// resolve a test's `launch.profile` exactly like the CLI does.
    public var profiles: [LaunchProfile]
    /// The server's own URL as the simulator sees it, used to arm the app-side
    /// loggers for runs the server starts.
    public var appFacingServerURL: String?
    /// The project checkout, for a run's provenance commit.
    public var projectRoot: URL?
    /// Open to the network: `port` answers every interface — HTTPS for other
    /// devices, plain HTTP for this Mac's loopback alone (`NetworkDoor`).
    /// Nil: the server listens on `host` only, as it is.
    public var network: NetworkExposure?
    /// Where builds fetched from a URL are kept (`~/Library/Caches/SimTool/builds` when nil).
    public var downloadCacheDirectory: URL?

    public init(
        host: String = "127.0.0.1",
        port: UInt16,
        device: SimulatorDevice,
        captureEnabled: Bool = true,
        defaultLogApp: String? = nil,
        testSessionsRoot: URL = SimToolDirectory.testSessionsDirectory(in: SimToolDirectory.resolve()),
        testsRoot: URL = SimToolDirectory.testsDirectory(in: SimToolDirectory.resolve()),
        profiles: [LaunchProfile] = [],
        appFacingServerURL: String? = nil,
        projectRoot: URL? = nil,
        network: NetworkExposure? = nil,
        downloadCacheDirectory: URL? = nil
    ) {
        self.network = network
        self.downloadCacheDirectory = downloadCacheDirectory
        self.host = host
        self.port = port
        self.device = device
        self.captureEnabled = captureEnabled
        self.defaultLogApp = defaultLogApp
        self.testSessionsRoot = testSessionsRoot
        self.testsRoot = testsRoot
        self.profiles = profiles
        self.appFacingServerURL = appFacingServerURL
        self.projectRoot = projectRoot
    }
}

/// What opening a server to the network takes: the TLS identity it answers with.
public struct NetworkExposure: @unchecked Sendable {
    public var identity: NetworkServerIdentity
    /// This Mac's Bonjour name, answered besides the certificate's names.
    public var localHostName: String?

    public init(identity: NetworkServerIdentity, localHostName: String?) {
        self.identity = identity
        self.localHostName = localHostName
    }

    /// The names the network may use for this server, lowercased.
    var names: Set<String> {
        Set((identity.names + [localHostName].compactMap { $0 }).map { $0.lowercased() })
    }

    /// The addresses to open it at, best first: the certificate's names, then
    /// its addresses — not loopback or link-local, which no other device reaches.
    public func urls(port: UInt16) -> [String] {
        let names = identity.names.filter { $0 != "localhost" && !$0.hasPrefix("*") }
        let addresses = identity.addresses.filter { !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.") }
        return (names + addresses).map { "https://\($0):\(port)/" }
    }
}

public final class StreamServer: @unchecked Sendable {
    public let config: StreamServerConfig

    /// Every route answers through `SameOriginPolicy`.
    private let server: SameOriginHttpServer
    /// Open to the network: the port's listener, and the server for the
    /// network behind it.
    private var networkDoor: NetworkDoor?
    private var networkServer: NetworkDoorServer?
    /// Whose finger is on the device: one viewer's gesture at a time.
    private let touchArbiter = TouchArbiter()
    /// Network, logs, state, tests and launches, pushed to viewers as they
    /// change. Its instance id also tells clients that poll by cursor which run
    /// of the server numbered what they hold.
    private let inspectorEvents = InspectorEventHub()
    private var testDefinitionsWatcher: TestDefinitionsWatcher?
    private let clientManager = ClientManager()
    private let frameCapture = FrameCapture()
    private let h264Encoder = H264Encoder(fps: 60)
    private let directInput = SimulatorDirectInputClient.shared
    private let metrics = StreamMetricsStore()
    private let networkLoggerEvents = NetworkLoggerEventStore(capacity: 1_000)
    private let mockRules = MockRuleRegistry()
    private let loggerPeer = NetworkLoggerPeer()
    private let stateLoggerEvents = StateLoggerEventStore()
    private let logEntries = LogEntryStore(capacity: 5_000)
    /// SimTool's own log (`DebugLog`) while the server runs: shown in the
    /// viewer's Logs tab apart from the app's, never mixed into the app's lines.
    private let ownLog = LogEntryStore(capacity: 2_000)
    /// Its lines reach the viewers from here, never from inside the hub's lock.
    private let ownLogQueue = DispatchQueue(label: "simtool.own-log")
    private var ownLogSink: UUID?
    /// When each viewer last fell behind, as said in the log (once a while each).
    private var slowViewersSaid: [Int: Date] = [:]
    private let slowViewersLock = NSLock()
    /// App launches detected for the inspected app, shared by the log and network ingest paths and
    /// retained for the server's lifetime so entries stay attributable across relaunches.
    private let launches = AppLaunchRegistry()
    /// Agent test sessions: timeline + screen recording, persisted on disk.
    private let testSessions: TestSessionController
    private let testRuns: TestRunController
    /// Screen recordings started from the viewer.
    private let screenRecordings: ScreenRecordingController
    /// What was done to the device and by whom, for the viewer's activity feed.
    private let activity = DeviceActivityLog()
    /// The app last launched through SimTool, which comes back when the
    /// simulator does.
    private let appRelaunch: AppRelaunchTracker
    /// Whether that app ran as SimTool shut the simulator down, asked just before.
    private var appRunningAtShutdown: Bool?
    /// A build being fetched from a URL and installed, or the last one.
    private let installJobs = AppInstallJobs()
    /// Builds fetched before, so the same one is not downloaded twice.
    private let downloadCache: SimulatorAppDownloadCache
    /// When anyone last used the server: what decides it has been left idle.
    private let usage = ServerUsage()
    /// Whether the simulator is on, and what starts it again while it is off.
    private let power = DevicePower()
    private var wakeHandler: (@Sendable () async throws -> Void)?
    /// The device's screens and the lit one, once its device type is read.
    private let displays = DeviceDisplays()
    /// Every SimTool process on the Mac, and stopping one: the viewer's
    /// process list.
    private let processes: SimToolProcessControl
    /// The device's settings and debug switches as it reports them.
    private let deviceSettings: DeviceSettingsReader
    private var displayMonitor: DisplayStateMonitor?
    private var foldMonitor: FoldMonitor?
    private var orientationMonitor: OrientationMonitor?
    /// The Mac's webcam, while it is the simulator's camera.
    private var cameraFeed: MacCameraFeed?
    /// A foldable's 3D preview, rendered while a viewer watches it.
    private var duo3D: Duo3DStream?
    /// The fold last told to the activity feed, and a viewer update or a
    /// settle check already on its way.
    private var recordedFold: SimulatorFoldState?
    private var foldTopicPending = false
    private var foldSettleGeneration = 0
    /// OSLog category that, by convention, carries a crash summary of the previous run (apps can
    /// only write it after relaunching - crash handlers cannot safely log at crash time).
    private static let crashReportCategory = "Crash"
    /// Formats state-event epoch timestamps for AppLaunchRegistry, which keys
    /// launches by ISO8601 strings (the network logger sends them pre-formatted).
    private static let stateTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let logLock = NSLock()
    private var logCapture: SimulatorLogCapture?
    private var logCaptureInfo: (device: String, app: String?, captureStdout: Bool)?
    /// The capture that ran when the simulator went off: it runs again, its
    /// lines kept, once the simulator is on.
    private var resumedLogCapture: (device: String, app: String?, captureStdout: Bool)?
    private var logLastPollAt = Date()
    private var logIdleTask: Task<Void, Never>?
    private let logIdleTimeout: TimeInterval = 60
    private let h264Queue = DispatchQueue(label: "simtool.encode.h264", qos: .userInteractive)
    private let stateLock = NSLock()
    private var h264Encoding = false
    private var h264Broadcasting = false
    private var forceKeyframe = false
    /// The frame being encoded shows the screen as the last one did (the
    /// idle refresh): its envelope says so. One frame encodes at a time.
    private var encodingRepeat = false
    private var screenWidth = 0
    private var screenHeight = 0
    private var started = false
    /// Viewers whose stream is paced to their link, by the id they named it with.
    private let pacedLock = NSLock()
    private var pacedStreams: [String: PacedStream] = [:]
    private let liveInputLock = NSLock()
    private var liveInputs: [ObjectIdentifier: (channel: LiveInputChannel, events: AsyncStream<LiveInputEvent>.Continuation)] = [:]

    /// - Parameter processes: how the process list finds and stops SimTool's
    ///   processes; a CLI passes one that stops a session as `simtool kill` does.
    public init(config: StreamServerConfig, processes: SimToolProcessControl = SimToolProcessControl()) {
        self.config = config
        self.processes = processes
        self.appRelaunch = AppRelaunchTracker(defaultApp: config.defaultLogApp)
        self.downloadCache = SimulatorAppDownloadCache(directory: config.downloadCacheDirectory)
        let server = SameOriginHttpServer(policy: SameOriginPolicy(serverHost: config.host, networkNames: config.network?.names ?? []))
        self.server = server
        let device = config.device
        self.deviceSettings = DeviceSettingsReader {
            await SimulatorDeviceControl.read(deviceUDID: device.udid, deviceType: device.deviceTypeIdentifier)
        }
        let displays = displays
        self.testSessions = TestSessionController(
            store: TestSessionStore(root: config.testSessionsRoot),
            device: config.device,
            // A foldable's recording follows the screen lit when it starts.
            makeRecorder: { SimctlVideoRecorder(display: { displays.activeDisplay?.id }) }
        )
        let events = inspectorEvents
        self.screenRecordings = ScreenRecordingController(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("simtool-recordings-\(config.port)", isDirectory: true),
            deviceUDID: config.device.udid,
            display: { displays.activeDisplay?.id },
            makeRecorder: { masked in SimctlVideoRecorder(display: { displays.activeDisplay?.id }, masked: masked) },
            onChange: { events.publish(.recording, $0) }
        )
        self.testRuns = TestRunController(
            testsRoot: config.testsRoot,
            profiles: config.profiles,
            defaultApp: config.defaultLogApp,
            appFacingServerURL: config.appFacingServerURL,
            projectRoot: config.projectRoot
        )
        server.onRequest = { [weak self] request in self?.admit(request) }
    }

    deinit {
        if let ownLogSink { DebugLog.removeSink(ownLogSink) }
    }

    /// SimTool's own lines this server kept after `since`.
    func ownLogLines(since: Int?) -> [LogEntry] {
        ownLog.query(since: since, limit: .max).entries
    }

    /// One line of SimTool's own log, kept and pushed to the viewers.
    private func recordOwnLine(_ line: DebugLog.Line) {
        ownLogQueue.async { [weak self] in
            guard let self else { return }
            self.inspectorEvents.publish { changes in
                let entry = self.ownLog.append(LogEntryDraft(
                    timestamp: Self.stateTimestampFormatter.string(from: line.date),
                    source: .simtool,
                    message: line.message,
                    level: line.level.rawValue,
                    subsystem: line.tag,
                    process: "simtool"
                ))
                changes.emit(.simtoolLogs, LogsTopicPayload(entries: [entry], droppedCount: self.ownLog.droppedCount()))
            }
        }
    }

    /// Notes who uses the server, and holds back what acts on the device while
    /// the simulator is off: a request from an agent or the CLI starts it and
    /// goes on once it is up; the viewer's own is told it is off.
    private func admit(_ request: HttpRequest) -> HttpResponse? {
        let counted = ServerUsage.counts(method: request.method, path: request.path, headers: request.headers)
        if counted { usage.note() }
        guard !power.isOn, DevicePower.needsDevice(method: request.method, path: request.path) else { return nil }
        guard counted else {
            let current = power.current
            let refusal = DevicePowerRefusal(error: DevicePower.refusal(device: config.device.name, power: current), power: current)
            return (try? jsonEncodedResponse(refusal, statusCode: 409, reason: "Conflict")) ?? errorResponse(SimToolError(refusal.error), statusCode: 409, reason: "Conflict")
        }
        if let failure = waitForWake(timeout: Self.wakeWait) {
            return errorResponse(failure, statusCode: 503, reason: "Service Unavailable")
        }
        return nil
    }

    /// How long a request waits for the simulator to start before it is told
    /// to try again; the start goes on.
    static let wakeWait: TimeInterval = 150

    /// Starts the simulator and waits for it, at most `timeout` seconds:
    /// what went wrong, or nil once it is on.
    private func waitForWake(timeout: TimeInterval) -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Void>()
        Task {
            do {
                box.result = .success(try await self.wake())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return SimToolError("\(config.device.name) is still starting — try again in a moment.")
        }
        if case let .failure(error) = box.result { return error }
        return nil
    }

    public func start() throws {
        guard !started else { return }
        started = true
        // A server starts on the network as it is: a condition left by one
        // that died is not anyone's now.
        SimulatorNetworkConditioner.off(deviceUDID: config.device.udid)
        // SimTool's own log reaches this server's viewers while it runs.
        if ownLogSink == nil { ownLogSink = DebugLog.addSink { [weak self] line in self?.recordOwnLine(line) } }
        installRoutes()
        wireEncoders()
        wireInspectorEvents()
        if let network = config.network {
            try openToNetwork(network)
        } else {
            server.listenAddressIPv4 = Self.listenAddress(forHost: config.host)
            try server.start(config.port, forceIPv4: true, priority: .userInteractive)
        }
        if config.captureEnabled {
            try frameCapture.start(deviceUDID: config.device.udid, onFrame: frameHandler)
            Task { await self.loadDisplays() }
        }
    }

    /// The server for this Mac and the one for the network on loopback ports
    /// of their own, and the port itself opened on every interface in front
    /// of both.
    private func openToNetwork(_ network: NetworkExposure) throws {
        server.listenAddressIPv4 = "127.0.0.1"
        try server.start(0, forceIPv4: true, priority: .userInteractive)
        let networkServer = NetworkDoorServer(server: server)
        networkServer.listenAddressIPv4 = "127.0.0.1"
        do {
            try networkServer.start(0, forceIPv4: true, priority: .userInteractive)
            let policy = server.policy
            let fallback = network.urls(port: config.port).first ?? "https://localhost:\(config.port)/"
            let door = NetworkDoor(
                port: config.port,
                localPort: UInt16(try server.port()),
                networkPort: UInt16(try networkServer.port()),
                identity: network.identity,
                landing: { host in
                    let url = host.flatMap { policy.isAllowedHost($0) ? "https://\($0)/" : nil } ?? fallback
                    return NetworkPages.landing(secureURL: url, offersAuthority: network.identity.authority != nil)
                }
            )
            try door.start()
            self.networkServer = networkServer
            networkDoor = door
        } catch {
            networkServer.stop()
            server.stop()
            throw error
        }
    }

    /// Reads which screens the device has. A foldable is then watched for the
    /// screen it lights, and the stream follows it.
    private func loadDisplays() async {
        var deviceType = config.device.deviceTypeIdentifier
        if deviceType == nil {
            deviceType = (try? await SimulatorDeviceClient.listDevices())?.first { $0.udid == config.device.udid }?.deviceTypeIdentifier
        }
        guard let deviceType, let layout = await SimulatorDisplayLayout.load(deviceType: deviceType) else { return }
        displays.set(layout: layout)
        frameCapture.setScreens(layout.displays.map { ($0.width, $0.height) })
        guard layout.isFoldable else {
            // A phone turns its picture on its framebuffer when it is rotated —
            // by SimTool, by Device Hub, by an app that forces landscape. It is
            // read now, and again whenever the guest says it turned.
            let monitor = DisplayStateMonitor(deviceUDID: config.device.udid, layout: layout) { [weak self] state in
                self?.displayStateChanged(state)
            }
            let turns = OrientationMonitor(deviceUDID: config.device.udid) { [weak monitor] in await monitor?.refresh() }
            stateLock.withLock {
                displayMonitor = monitor
                orientationMonitor = turns
            }
            await monitor.refresh()
            turns.start()
            return
        }
        let monitor = DisplayStateMonitor(deviceUDID: config.device.udid, layout: layout) { [weak self] state in
            self?.displayStateChanged(state)
        }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        stateLock.withLock { duo3D = Duo3DStream(deviceUDID: config.device.udid, executable: executable) }
        let fold = FoldMonitor(deviceUDID: config.device.udid) { [weak self] state, panelSwitched in
            self?.foldChanged(state, panelSwitched: panelSwitched)
        }
        stateLock.withLock {
            displayMonitor = monitor
            foldMonitor = fold
        }
        monitor.start()
        fold.start()
    }

    /// SpringBoard reported the hinge, the posture or the primary panel. The
    /// viewer hears it at most ten times a second; a new panel is read at once;
    /// where the fold comes to rest goes to the activity feed.
    private func foldChanged(_ fold: SimulatorFoldState, panelSwitched: Bool) {
        guard displays.set(fold: fold) else { return }
        update3D()
        if panelSwitched, let monitor = stateLock.withLock({ displayMonitor }) {
            Task { await monitor.refresh() }
        }
        let publish = stateLock.withLock {
            defer { foldTopicPending = true }
            return !foldTopicPending
        }
        if publish {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.stateLock.withLock { self.foldTopicPending = false }
                self.inspectorEvents.publish(.device, self.displays.topic)
            }
        }
        let generation = stateLock.withLock {
            foldSettleGeneration += 1
            return foldSettleGeneration
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.foldSettled(generation: generation)
        }
    }

    /// The fold has rested for a moment. A pose SimTool was asked for carries
    /// where it landed in its own entry; one made elsewhere — Device Hub's
    /// hinge slider — gets an entry of its own.
    private func foldSettled(generation: Int) {
        guard let fold = displays.fold else { return }
        let changed = stateLock.withLock {
            guard generation == foldSettleGeneration,
                  recordedFold?.pose != fold.pose || recordedFold?.panel != fold.panel || recordedFold.flatMap(\.hingeDegrees).map({ abs($0 - (fold.hingeDegrees ?? $0)) >= 5 }) ?? true else { return false }
            recordedFold = fold
            return true
        }
        guard changed else { return }
        // A pose still running is the one that moved it; one that just
        // finished where the device is now already says so.
        let recent = Date().addingTimeInterval(-6)
        if let asked = activity.last(where: { $0.kind == "pose" && $0.via != "device" }) {
            if asked.status == .running {
                activity.update(id: asked.id) { $0.detail = fold.summary }
                return
            }
            if (asked.endedAt ?? asked.at) > recent, asked.detail == nil || asked.detail == fold.summary {
                if asked.detail == nil { activity.update(id: asked.id) { $0.detail = fold.summary } }
                return
            }
        }
        activity.record(actor: .viewer, via: "device", kind: "pose", title: "Folded to " + (fold.pose ?? fold.hingeDegrees.map(SimulatorFoldState.degrees) ?? "an unknown pose"), detail: fold.summary)
    }

    /// Whether the 3D preview can be shown, with the model it renders, or why not.
    private func view3D() -> (url: URL?, reason: String?) {
        let located = Duo3DModel.locate(layout: displays.current.layout, developerDir: DeveloperFrameworks.developerDir())
        if located.url != nil, let failure = stateLock.withLock({ duo3D })?.recentFailure { return (nil, failure) }
        return located
    }

    /// Where the 3D preview's hinge and lit panel stand.
    private func update3D() {
        guard let stream = stateLock.withLock({ duo3D }) else { return }
        let role = displays.activeDisplay?.role ?? "cover"
        stream.update(panel: role, hinge: displays.fold?.hingeDegrees ?? (role == "cover" ? 0 : 180))
    }

    private func displayStateChanged(_ state: SimulatorDisplayState) {
        defer { update3D() }
        guard displays.set(state: state), let layout = displays.current.layout else { return }
        // Touches follow the panel without asking CoreDevice each time.
        let directInput = directInput, udid = config.device.udid
        Task { await directInput.setDisplayState(state, deviceUDID: udid) }
        let lit = layout.display(named: state.active)
        frameCapture.setScreens(layout.displays.map { ($0.width, $0.height) }, preferred: lit.map { ($0.width, $0.height) })
        inspectorEvents.publish(.device, displays.topic)
    }

    public func stop() {
        // The emulated network goes with the server that set it.
        SimulatorNetworkConditioner.off(deviceUDID: config.device.udid)
        detachDevice()
        inspectorEvents.closeAll()
        testDefinitionsWatcher?.stop()
        testDefinitionsWatcher = nil
        closeLiveInputs()
        shutdownScreenRecordings()
        networkDoor?.stop()
        networkDoor = nil
        networkServer?.stop()
        networkServer = nil
        server.stop()
        if let ownLogSink {
            DebugLog.removeSink(ownLogSink)
            self.ownLogSink = nil
        }
        started = false
    }

    /// Lets go of the simulator's boot: the stream and the viewers' video
    /// connections, the screen and fold monitors, the 3D preview, a webcam
    /// feed, the log capture, an agent's test session and the input helpers.
    private func detachDevice() {
        let (display, fold, orientation, preview) = stateLock.withLock {
            defer {
                displayMonitor = nil
                foldMonitor = nil
                orientationMonitor = nil
                duo3D = nil
            }
            return (displayMonitor, foldMonitor, orientationMonitor, duo3D)
        }
        display?.stop()
        fold?.stop()
        orientation?.stop()
        preview?.stop()
        // A webcam this server ran stops with it: the apps would hold its last frame.
        if stateLock.withLock({ cameraFeed }) != nil {
            stopCameraFeed()
            _ = try? SimulatorCamera.off(deviceUDID: config.device.udid)
        }
        shutdownTestSessions()
        logLock.withLock { resumedLogCapture = logCaptureInfo }
        stopLogCapture()
        frameCapture.stop()
        h264Encoder.stop()
        let paced = pacedLock.withLock { Array(pacedStreams.values) }
        for stream in paced { stream.stop() }
        clientManager.closeAll()
        let directInput = directInput
        Task {
            await directInput.close()
            await SimulatorFoldClient.shared.close()
        }
    }

    /// Takes on the simulator's boot — a new one, after it was off: the
    /// stream and the monitors that follow its screens.
    private func attachDevice() throws {
        let relaunch = appRelaunch.takePending()
        var relaunched = false
        if let capture = logLock.withLock({ resumedLogCapture }) {
            // With stdout, starting it launches the app again, as it was last
            // launched — that is the app coming back.
            if let relaunch, capture.captureStdout, capture.app == relaunch.bundleId {
                relaunched = true
                activity.record(actor: .simtool, via: "server", kind: "launch", title: "Relaunch " + relaunch.bundleId, detail: Self.relaunchDetail(relaunch))
            }
            Task {
                do {
                    _ = try self.startLogCapture(LogCaptureStartRequest(device: capture.device, app: capture.app, captureStdout: capture.captureStdout))
                } catch {
                    DebugLog.error("logs", "the log capture of \(capture.app ?? "the simulator") did not start again: \(error.localizedDescription)")
                }
            }
        }
        if let relaunch, !relaunched {
            Task { await self.relaunchAfterWake(relaunch) }
        }
        guard config.captureEnabled else { return }
        try frameCapture.start(deviceUDID: config.device.udid, onFrame: frameHandler)
        Task { await self.loadDisplays() }
    }

    /// Who starts the simulator again: the viewer's Start, a request that
    /// needs the device. Set by whoever runs the server, which knows how to
    /// boot it under SimTool's hold and to take it on (`powerOn()`).
    public func onWake(_ handler: @escaping @Sendable () async throws -> Void) {
        stateLock.withLock { wakeHandler = handler }
    }

    /// Starts the simulator, and returns once it is on.
    public func wake() async throws {
        guard !power.isOn else { return }
        guard let handler = stateLock.withLock({ wakeHandler }) else {
            throw SimToolError("This server cannot start \(config.device.name) again.")
        }
        try await handler()
    }

    /// The simulator is off, or is going off: the server lets go of its boot,
    /// keeps answering, and tells the viewers why.
    public func powerOff(_ payload: ServerPowerPayload) {
        let wasOn = power.isOn
        let said = [payload.title, payload.detail].compactMap { $0 }.joined(separator: " — ")
        if payload.reason == "failed" { DebugLog.error("power", said) } else { DebugLog.info("power", said.isEmpty ? "\(config.device.name) is off" : said) }
        if wasOn { noteAppAsTheDeviceGoes(payload) }
        power.set(payload)
        // Said before the stream closes, so a page reads it as off, not lost.
        inspectorEvents.publish(.server, ServerPowerNotice(power: payload))
        if wasOn { detachDevice() }
    }

    /// The simulator is starting.
    public func powerStarting(_ payload: ServerPowerPayload) {
        DebugLog.info("power", payload.title ?? "starting \(config.device.name)")
        power.set(payload)
        inspectorEvents.publish(.server, ServerPowerNotice(power: payload))
    }

    /// The simulator is on again — booted by the server or by anyone else:
    /// the stream and its monitors start on the new boot, and the viewers
    /// reconnect. Starting counts as use.
    public func powerOn() throws {
        guard !power.isOn else { return }
        try attachDevice()
        DebugLog.info("power", "\(config.device.name) is on: streaming it again")
        usage.note()
        power.set(.on)
        inspectorEvents.publish(.server, ServerPowerNotice(power: .on))
    }

    public var powerState: ServerPowerPayload {
        power.current
    }

    // MARK: - the app, when the simulator comes back

    /// Looks at the last launched app's process, while the simulator is on:
    /// a simulator shut down outside SimTool is found off only after its apps
    /// are gone, and this is what says whether the app was still running.
    public func sampleApp() {
        appRelaunch.sample { pid in kill(pid_t(pid), 0) == 0 }
    }

    /// SimTool is about to shut the simulator down, which is still up: it is
    /// asked whether the app runs, and that decides whether the app comes back.
    public func noteAppBeforeShutdown() async {
        guard let candidate = appRelaunch.candidate else { return }
        let running = await SimulatorAppProcess.isRunning(bundleId: candidate.bundleId, deviceUDID: config.device.udid)
        stateLock.withLock { appRunningAtShutdown = running }
    }

    /// The simulator is going off: whether the app comes back with it is
    /// decided now — by the simulator's own answer when SimTool asked it just
    /// before shutting it down, else (shut down outside: it is already gone)
    /// by the last look at the app's process.
    private func noteAppAsTheDeviceGoes(_ payload: ServerPowerPayload) {
        let asked = stateLock.withLock {
            defer { appRunningAtShutdown = nil }
            return appRunningAtShutdown
        }
        appRelaunch.wentOff(runningNow: asked)
    }

    /// Launches the app that ran before the simulator went off, as it was
    /// launched. Not when someone launched an app since the simulator came
    /// on, not over a test run (which launches its own), and not when the app
    /// already runs.
    private func relaunchAfterWake(_ record: AppLaunchRecord) async {
        let generation = appRelaunch.generation
        // A moment for the home screen, and for whoever woke the simulator to
        // launch something of their own.
        try? await Task.sleep(for: .seconds(1))
        guard power.isOn, appRelaunch.generation == generation, testSessions.activeSession == nil else {
            DebugLog.write("relaunch", "\(record.bundleId) is not relaunched: an app was launched since, a test runs, or the simulator went off")
            return
        }
        let udid = config.device.udid
        if await SimulatorAppProcess.isRunning(bundleId: record.bundleId, deviceUDID: udid) == true {
            DebugLog.write("relaunch", "\(record.bundleId) runs already")
            return
        }
        DebugLog.info("relaunch", "relaunching \(record.bundleId): it ran when the simulator went off")
        let entry = activity.begin(actor: .simtool, via: "server", kind: "launch", title: "Relaunch " + record.bundleId, detail: Self.relaunchDetail(record))
        var lastError: Error?
        // Right after a boot the home screen may refuse a launch for a moment.
        for attempt in 1...3 {
            guard power.isOn, appRelaunch.generation == generation else { activity.finish(id: entry.id); return }
            do {
                let output = try await launchApp(record)
                var launched = record
                launched.pid = AppLaunchRecord.pid(fromLaunchOutput: output.stdoutString)
                appRelaunch.launched(launched)
                activity.finish(id: entry.id)
                return
            } catch {
                lastError = error
                DebugLog.write("relaunch", "attempt \(attempt) of 3 to launch \(record.bundleId) failed: \(error.localizedDescription)")
                if attempt < 3 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        DebugLog.error("relaunch", "\(record.bundleId) did not come back: \(lastError?.localizedDescription ?? "launch failed")")
        activity.finish(id: entry.id, error: lastError?.localizedDescription ?? "launch failed")
    }

    static func relaunchDetail(_ record: AppLaunchRecord) -> String {
        "the simulator came back on" + (record.arguments.isEmpty ? "" : " · " + record.arguments.joined(separator: " "))
    }

    /// `simctl launch`, cold, with the launch's argv and variables on top of
    /// the server's own (the loggers), and the camera and network conditions
    /// as they are now.
    private func launchApp(_ record: AppLaunchRecord) async throws -> ProcessOutput {
        let udid = config.device.udid
        let environment = SimToolLaunchEnvironment.forApp(deviceUDID: udid, merging: record.environment)
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: SimulatorAppLifecycleClient.simctlLaunchArguments(deviceUDID: udid, bundleIdentifier: record.bundleId, launchArguments: record.arguments),
            environment: environment.isEmpty ? nil : SimulatorAppLifecycleClient.simctlChildEnvironment(launchEnvironment: environment),
            timeoutSeconds: 120
        )
        guard output.status == 0 else {
            throw SimToolError("simctl launch \(record.bundleId) failed: \(output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    /// When anyone last used the server, and whether it is busy with
    /// something that sends no requests while it runs.
    public func usageState() -> ServerUsageState {
        let busy = testRuns.status().active || screenRecordings.topic.current?.state == .recording || installJobs.isRunning
        return ServerUsageState(lastUse: usage.lastUse, busy: busy)
    }

    /// Tells the viewers the server is about to stop, and why, so the page can
    /// say so instead of only that the connection is gone.
    public func announceStop(_ notice: ServerStopNotice) {
        inspectorEvents.publish(.server, notice)
    }

    public var baseURL: String { "http://\(config.host):\(config.port)" }
    public var apiURL: String { "\(baseURL)/api/v1" }

    /// The address the socket binds: the configured host, so a server started
    /// on 127.0.0.1 is not reachable from the network. `0.0.0.0`, an empty
    /// host or a name other than localhost listen on every interface.
    static func listenAddress(forHost host: String) -> String? {
        let host = host.lowercased()
        if host == "localhost" { return "127.0.0.1" }
        var address = in_addr()
        guard host != "0.0.0.0", inet_pton(AF_INET, host, &address) == 1 else { return nil }
        return host
    }

    private func installRoutes() {
        server["/"] = { _ in
            .ok(.html(WebViewer.html()))
        }

        // The viewer's stylesheets and scripts, as separate files.
        for path in WebViewer.assetPaths {
            guard let asset = WebViewer.servedAsset(path) else { continue }
            let data = Data(asset.contents.utf8)
            server.GET[WebViewer.assetsPath + path] = { _ in
                self.dataResponse(data, contentType: asset.contentType)
            }
        }

        server["/health"] = { _ in
            self.jsonResponse(["status": "ok"])
        }

        // SimTool's certificate authority, for a device to trust once: on both doors.
        server.GET[NetworkPages.authorityPath] = { _ in
            guard let authority = self.config.network?.identity.authority else { return .notFound }
            return .raw(200, "OK", ["Content-Type": "application/x-x509-ca-cert", "Content-Length": "\(authority.count)"]) { try $0.write(authority) }
        }
        // The QR code a phone scans to open the viewer.
        server.GET["/api/v1/network/qr.png"] = { _ in
            guard let link = self.networkPayload()?.urls.first, let png = QRCodeImage.png(for: link) else { return .notFound }
            return .raw(200, "OK", ["Content-Type": "image/png", "Content-Length": "\(png.count)", "Cache-Control": "no-store"]) { try $0.write(png) }
        }

        server["/config"] = { _ in
            do { return try self.jsonEncodedResponse(self.configPayload()) }
            catch { return self.errorResponse(error) }
        }

        server["/api/v1/status"] = { _ in
            do { return try self.jsonEncodedResponse(self.statusPayload()) }
            catch { return self.errorResponse(error) }
        }

        server.GET["/api/v1/metrics"] = { _ in
            do { return try self.jsonEncodedResponse(self.metricsPayload()) }
            catch { return self.errorResponse(error) }
        }

        // The inspector's data as it changes: one Server-Sent Events stream per
        // page. It sends no CORS header, so only the viewer's own origin reads it.
        server.GET["/api/v1/events"] = { request in self.eventStreamResponse(request) }

        server.GET["/api/v1/devices"] = { _ in
            self.asyncJSONResponse {
                let devices = try await SimulatorDeviceClient.listDevices()
                return DeviceListPayload(devices: devices, selected: self.config.device.udid)
            }
        }

        server.GET["/api/v1/activity"] = { request in
            let page = self.activity.query(since: request.queryInt("since"), limit: request.queryInt("limit") ?? 200)
            let run = self.testRuns.status(activeSession: self.testSessions.activeSession)
            do {
                return try self.jsonEncodedResponse(DeviceActivityPayload(entries: page.entries, revision: page.revision, run: run.active ? run : nil))
            } catch {
                return self.errorResponse(error)
            }
        }

        // The CLI acts on the device in its own process and says so here.
        server.POST["/api/v1/activity"] = { request in
            do {
                let report = try self.decodeJSON(DeviceActivityReport.self, from: request)
                return try self.jsonEncodedResponse(try self.activity.apply(report))
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }

        server.POST["/api/v1/input"] = { request in self.handleInput(request) }

        // A bad network for the apps SimTool launches on this simulator.
        server.GET["/api/v1/network/condition"] = { _ in
            do { return try self.jsonEncodedResponse(SimulatorNetworkConditioner.state(deviceUDID: self.config.device.udid)) }
            catch { return self.errorResponse(error) }
        }
        server.POST["/api/v1/network/condition"] = { request in self.handleNetworkCondition(request, off: false) }
        server.DELETE["/api/v1/network/condition"] = { request in self.handleNetworkCondition(request, off: true) }

        // Every SimTool process on this Mac — servers from any binary, their
        // helpers, the reaper, commands, orphans — and stopping one. Only a
        // PID the discovery calls SimTool's is stopped; this server itself
        // only when the request confirms it.
        server.GET["/api/v1/processes"] = { _ in
            let processes = self.processes
            return self.asyncJSONResponse { processes.list() }
        }
        server.POST["/api/v1/processes/:pid/kill"] = { request in self.handleProcessKill(request) }
        server.POST["/api/v1/processes/kill-orphans"] = { _ in
            let processes = self.processes
            return self.asyncJSONResponse { ProcessKillPayload(outcomes: await processes.killOrphans()) }
        }

        // The viewer's page, while someone works in it: what keeps the server
        // and its simulator up for a person who reads more than they touch.
        server.POST["/api/v1/presence"] = { _ in
            self.usage.note()
            return self.jsonResponse(["ok": true])
        }
        // The viewer's live finger and keys: down/move/up and keydown/keyup
        // frames, never answered.
        server["/api/v1/input/stream"] = websocket(
            text: { session, text in self.liveInputChannel(for: session)?.receive(text) },
            connected: { session in self.openLiveInputChannel(for: session) },
            disconnected: { session in self.closeLiveInputChannel(for: session) }
        )
        // The device's settings and debug switches: read back as the device
        // reports them, changed one request at a time.
        server.GET["/api/v1/device"] = { _ in
            do {
                let settings = self.deviceSettings
                return try self.jsonEncodedResponse(try self.waitForAsync { await settings.current() })
            } catch {
                return self.errorResponse(error)
            }
        }
        server.POST["/api/v1/device"] = { request in self.handleDeviceControl(request) }
        // Starts the simulator SimTool shut down, and answers once it is on —
        // a person's Start on the viewer is use, as a touch is.
        server.POST["/api/v1/device/wake"] = { _ in
            self.usage.note()
            do {
                try self.waitForAsync { try await self.wake() }
                return try self.jsonEncodedResponse(self.power.current)
            } catch {
                return self.errorResponse(error, statusCode: 503, reason: "Service Unavailable")
            }
        }
        // The app under test (or `bundleId`): its card, its bundle and data in
        // the Finder, and installing a build dropped on the viewer.
        server.GET["/api/v1/app"] = { request in
            do {
                let bundleId = try self.bundleId(request.queryValue("bundleId"))
                let udid = self.config.device.udid
                return try self.jsonEncodedResponse(try self.waitForAsync { try await SimulatorAppInfoClient.read(bundleId: bundleId, deviceUDID: udid, permissions: true) })
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }
        server.POST["/api/v1/app/reveal"] = { request in
            do {
                let body = try self.decodeJSON([String: String].self, from: request)
                let bundleId = try self.bundleId(body["bundleId"])
                let udid = self.config.device.udid
                let path = try self.waitForAsync { try await SimulatorAppInfoClient.reveal(body["what"] ?? "bundle", bundleId: bundleId, deviceUDID: udid) }
                return try self.jsonEncodedResponse(CommandResultPayload(ok: true, stdout: path, stderr: ""))
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }
        // A build in the body (an .ipa, a tar of an .app) installs while the
        // request waits; a JSON body names one at a URL, fetched and installed
        // by a job the request only starts (`GET` follows it).
        server.POST["/api/v1/app/install"] = { request in
            self.isJSON(request) ? self.handleInstallFromURL(request) : self.handleInstall(request)
        }
        server.GET["/api/v1/app/install"] = { _ in
            do {
                guard let job = self.installJobs.current else { return self.jsonResponse(["state": "idle"]) }
                return try self.jsonEncodedResponse(job)
            } catch {
                return self.errorResponse(error)
            }
        }
        server.POST["/api/v1/app/launch"] = { request in self.handleLaunch(request) }
        // A launch made outside the server — `simtool app launch`, a test run —
        // so the app comes back as it was launched when the simulator does.
        server.POST["/api/v1/app/launched"] = { request in
            do {
                let record = try self.decodeJSON(AppLaunchRecord.self, from: request)
                guard !record.bundleId.isEmpty else { throw SimToolError("Name the app: bundleId") }
                self.appRelaunch.launched(record)
                return self.jsonResponse(["ok": true])
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }
        // The simulator's camera: an image or a video, the Mac's webcam, or off.
        server.GET["/api/v1/camera"] = { _ in
            do { return try self.jsonEncodedResponse(self.cameraState()) } catch { return self.errorResponse(error) }
        }
        server.POST["/api/v1/camera"] = { request in self.handleCameraFile(request) }
        server.POST["/api/v1/camera/webcam"] = { request in self.handleWebcam(request) }
        server.DELETE["/api/v1/camera"] = { request in
            do {
                let udid = self.config.device.udid
                _ = try self.recordingActivity(of: request, kind: "camera", title: "Camera off") {
                    self.stopCameraFeed()
                    return try SimulatorCamera.off(deviceUDID: udid)
                }
                return try self.jsonEncodedResponse(self.cameraState())
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }
        server.POST["/api/v1/input/paste-image"] = { request in self.handlePasteImage(request) }
        server.POST["/api/v1/photos"] = { request in self.handleAddToPhotos(request) }

        server.GET["/api/v1/ax/tree"] = { request in
            let includeRaw = request.queryFlag("raw")
            if request.queryValue("format")?.lowercased() == "flat" {
                let labeledOnly = request.queryFlag("labeled")
                return self.asyncJSONResponse {
                    SimulatorAccessibilityClient.flatten(
                        try await SimulatorAccessibilityClient.normalizedTree(deviceUDID: self.config.device.udid),
                        labeledOnly: labeledOnly
                    )
                }
            }
            return self.asyncJSONResponse {
                try await SimulatorAccessibilityClient.normalizedTree(deviceUDID: self.config.device.udid, includeRaw: includeRaw)
            }
        }

        server.GET["/api/v1/ax/raw"] = { _ in
            do {
                let data = try self.waitForAsync {
                    try await SimulatorAccessibilityClient.tree(deviceUDID: self.config.device.udid)
                }
                return self.dataResponse(data, contentType: "application/json")
            } catch {
                return self.errorResponse(error)
            }
        }

        server.GET["/api/v1/ax/find"] = { request in
            guard let needle = request.queryValue("q") ?? request.queryValue("needle"), !needle.isEmpty else {
                return self.errorResponse(SimToolError("Missing q query parameter"), statusCode: 400, reason: "Bad Request")
            }
            let includeRaw = request.queryFlag("raw")
            return self.asyncJSONResponse {
                try await SimulatorAccessibilityClient.findNodes(needle: needle, deviceUDID: self.config.device.udid, includeRaw: includeRaw)
            }
        }

        server.GET["/api/v1/logs"] = { request in
            let lines = request.queryInt("lines") ?? 200
            let seconds = request.queryDouble("seconds") ?? 2
            let app = request.queryValue("app")
            return self.asyncJSONResponse {
                let payload = try await SimulatorLogsClient.tail(
                    deviceUDID: self.config.device.udid,
                    app: app,
                    lines: lines,
                    seconds: seconds
                )
                return LogTailPayload(lines: payload)
            }
        }

        server.GET["/api/v1/network"] = { request in
            let seconds = request.queryDouble("seconds") ?? 2
            let limit = request.queryInt("limit") ?? 200
            return self.asyncJSONResponse {
                try await SimulatorNetworkClient.snapshot(
                    deviceUDID: self.config.device.udid,
                    seconds: seconds,
                    limit: limit
                )
            }
        }

        server.POST["/api/v1/network/events"] = { request in
            self.handleNetworkLoggerIngestion(request)
        }

        server.GET["/api/v1/network/events"] = { request in
            do {
                let filter = try self.networkLoggerFilter(from: request)
                var payload = self.networkLoggerEvents.query(filter: filter)
                if let warning = self.loggerPeer.lastReport?.warning { payload.warnings.append(warning) }
                return try self.jsonEncodedResponse(payload)
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }

        server.POST["/api/v1/mocks"] = { request in
            do {
                let draft = try self.decodeJSON(MockRuleDraft.self, from: request)
                let created = self.inspectorEvents.publish { changes in
                    let created = self.mockRules.add(draft)
                    changes.emit(.network, NetworkTopicPayload(mocks: self.mockRules.list(since: nil).rules))
                    return created
                }
                let (actor, via) = self.activityActor(of: request)
                self.activity.record(actor: actor, via: via, kind: "mock", title: "Mock armed: " + draft.match.method, detail: Self.mockAnswer(draft) + " · " + created.id)
                return try self.jsonEncodedResponse(created)
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }

        server.GET["/api/v1/mocks"] = { request in
            do {
                let since = request.queryInt("since")
                let loggerVersion = request.queryValue("loggerVersion")
                // An app's poller says `since` (from its second poll on) and, from
                // 1.0, its version; the viewer and `mock list` say neither.
                if since != nil || loggerVersion != nil, let report = self.loggerPeer.heard(version: loggerVersion) {
                    self.inspectorEvents.publish(.network, NetworkTopicPayload(logger: report))
                }
                return try self.jsonEncodedResponse(self.mockRules.list(since: since))
            } catch {
                return self.errorResponse(error)
            }
        }

        server.GET["/api/v1/mocks/ack"] = { _ in
            do {
                let ack = self.mockRules.acknowledgement()
                return try self.jsonEncodedResponse(MockAcknowledgementPayload(
                    generation: ack.generation,
                    acknowledged: ack.acknowledged,
                    lastPollAt: ack.lastPollAt,
                    logger: self.loggerPeer.lastReport
                ))
            } catch {
                return self.errorResponse(error)
            }
        }

        server.DELETE["/api/v1/mocks/:id"] = { request in
            guard let id = request.params[":id"], !id.isEmpty else {
                return self.errorResponse(SimToolError("Missing mock id"), statusCode: 400, reason: "Bad Request")
            }
            let removed = self.inspectorEvents.publish { changes in
                let removed = self.mockRules.remove(id: id)
                if removed { changes.emit(.network, NetworkTopicPayload(mocks: self.mockRules.list(since: nil).rules)) }
                return removed
            }
            if removed {
                let (actor, via) = self.activityActor(of: request)
                self.activity.record(actor: actor, via: via, kind: "mock", title: "Mock removed: " + id)
            }
            return self.jsonResponse(["ok": true, "removed": removed ? 1 : 0])
        }

        server.DELETE["/api/v1/mocks"] = { request in
            let removed = self.inspectorEvents.publish { changes in
                let removed = self.mockRules.clear()
                if removed > 0 { changes.emit(.network, NetworkTopicPayload(mocks: [])) }
                return removed
            }
            if removed > 0 {
                let (actor, via) = self.activityActor(of: request)
                self.activity.record(actor: actor, via: via, kind: "mock", title: removed == 1 ? "1 mock cleared" : "\(removed) mocks cleared")
            }
            return self.jsonResponse(["ok": true, "removed": removed])
        }

        server.DELETE["/api/v1/network/launches/:launchId"] = { request in
            guard let raw = request.params[":launchId"], let launchId = Int(raw) else {
                return self.errorResponse(SimToolError("Missing launch id"), statusCode: 400, reason: "Bad Request")
            }
            let removed = self.inspectorEvents.publish { changes in
                let removed = self.networkLoggerEvents.deleteEvents(launchId: launchId)
                changes.emit(.network, NetworkTopicPayload(removedLaunch: launchId))
                return removed
            }
            return self.jsonResponse(["ok": true, "removed": removed])
        }

        server.DELETE["/api/v1/logs/launches/:launchId"] = { request in
            guard let raw = request.params[":launchId"], let launchId = Int(raw) else {
                return self.errorResponse(SimToolError("Missing launch id"), statusCode: 400, reason: "Bad Request")
            }
            let removed = self.inspectorEvents.publish { changes in
                let removed = self.logEntries.deleteEntries(launchId: launchId)
                changes.emit(.logs, LogsTopicPayload(removedLaunch: launchId))
                return removed
            }
            return self.jsonResponse(["ok": true, "removed": removed])
        }

        server.POST["/api/v1/state/events"] = { request in
            self.handleStateLoggerIngestion(request)
        }

        server.GET["/api/v1/state/events"] = { request in
            let since = request.queryInt("since")
            let limit = request.queryInt("limit") ?? 500
            do {
                return try self.jsonEncodedResponse(self.stateLoggerEvents.query(since: since, limit: limit))
            } catch {
                return self.errorResponse(error)
            }
        }

        server.POST["/api/v1/logs/capture"] = { request in
            do {
                let start = (try? self.decodeJSON(LogCaptureStartRequest.self, from: request)) ?? LogCaptureStartRequest()
                return try self.jsonEncodedResponse(try self.startLogCapture(start))
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }

        server.GET["/api/v1/logs/capture"] = { request in
            let since = request.queryInt("since")
            let limit = request.queryInt("limit") ?? 500
            do {
                return try self.jsonEncodedResponse(self.logCaptureEntries(since: since, limit: limit))
            } catch {
                return self.errorResponse(error)
            }
        }

        // SimTool's own log: what the server did and what failed inside it.
        server.GET["/api/v1/logs/simtool"] = { request in
            do {
                return try self.jsonEncodedResponse(self.ownLog.query(since: request.queryInt("since"), limit: request.queryInt("limit") ?? 500))
            } catch {
                return self.errorResponse(error)
            }
        }

        server.POST["/api/v1/logs/capture/stop"] = { _ in
            do {
                return try self.jsonEncodedResponse(self.stopLogCapture())
            } catch {
                return self.errorResponse(error)
            }
        }

        server.GET["/api/v1/launches"] = { _ in
            do {
                return try self.jsonEncodedResponse(AppLaunchesPayload(launches: self.launches.snapshot()))
            } catch {
                return self.errorResponse(error)
            }
        }

        server.POST["/api/v1/tests/start"] = { request in
            do {
                let start = try self.decodeJSON(TestSessionStartRequest.self, from: request)
                let session = try self.inspectorEvents.publish { changes in
                    let session = try self.testSessions.start(
                        title: start.title,
                        file: start.file,
                        video: start.video ?? true,
                        kind: start.kind,
                        reference: start.reference,
                        criteria: start.criteria ?? [],
                        provenance: start.provenance
                    )
                    changes.emit(.tests, TestsTopicPayload(session: session, run: self.testRunStatus()))
                    return session
                }
                self.activity.record(actor: .test, via: "api", kind: "test", title: "Test started: " + session.title, detail: session.file)
                return try self.jsonEncodedResponse(session)
            } catch {
                return self.testSessionErrorResponse(error)
            }
        }

        server.POST["/api/v1/tests/entries"] = { request in
            do {
                let entry = try self.decodeJSON(TestSessionEntryRequest.self, from: request)
                let session = try self.inspectorEvents.publish { changes in
                    let session = try self.testSessions.append(entry)
                    changes.emit(.tests, TestsTopicPayload(session: session))
                    return session
                }
                // Steps and the run's narration ("Launched …"), not the log
                // dumps attached to a failure.
                if entry.kind == .step, let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    self.activity.record(actor: .test, via: "api", kind: "step", title: text, failed: text.hasPrefix("✗") ? "step failed" : nil)
                }
                return try self.jsonEncodedResponse(session)
            } catch {
                return self.testSessionErrorResponse(error)
            }
        }

        server.POST["/api/v1/tests/stop"] = { request in
            do {
                let stop = try self.decodeJSON(TestSessionStopRequest.self, from: request)
                let session = try self.waitForAsync {
                    try await self.testSessions.stop(
                        status: stop.status,
                        verdict: stop.verdict,
                        criteria: stop.criteria,
                        mocks: stop.mocks,
                        evidence: stop.evidence
                    )
                }
                // Stopping awaits the recorder, so it cannot run under the hub's
                // lock; nothing else changes a session once it is no longer active.
                self.inspectorEvents.publish(.tests, TestsTopicPayload(session: session, run: self.testRunStatus()))
                self.activity.record(
                    actor: .test,
                    via: "api",
                    kind: "test",
                    title: "Test \(session.status.rawValue): " + session.title,
                    detail: session.verdict.map { "verdict " + $0.rawValue },
                    failed: session.status == .failed ? "the run failed" : nil
                )
                return try self.jsonEncodedResponse(session)
            } catch {
                return self.testSessionErrorResponse(error)
            }
        }

        server.GET["/api/v1/tests"] = { _ in
            do {
                return try self.jsonEncodedResponse(self.testSessions.list())
            } catch {
                return self.errorResponse(error)
            }
        }

        server.GET["/api/v1/tests/definitions"] = { _ in
            do {
                return try self.jsonEncodedResponse(self.testRuns.list())
            } catch {
                return self.errorResponse(error)
            }
        }

        server.GET["/api/v1/tests/run"] = { _ in
            do {
                return try self.jsonEncodedResponse(self.testRunStatus())
            } catch {
                return self.errorResponse(error)
            }
        }

        server.POST["/api/v1/tests/run"] = { request in
            do {
                let body = try self.decodeJSON(TestRunRequest.self, from: request)
                guard let serverURL = URL(string: self.baseURL) else {
                    return self.errorResponse(SimToolError("Cannot resolve own base URL"))
                }
                let status = try self.testRuns.start(
                    file: body.file,
                    serverURL: serverURL,
                    video: body.video ?? true,
                    activeSession: self.testSessions.activeSession
                )
                self.publishTestRun()
                return try self.jsonEncodedResponse(status)
            } catch {
                return self.errorResponse(error, statusCode: 409, reason: "Conflict")
            }
        }

        server.POST["/api/v1/tests/run/stop"] = { _ in
            do {
                return try self.jsonEncodedResponse(self.testRuns.stop())
            } catch {
                return self.errorResponse(error)
            }
        }

        server.DELETE["/api/v1/tests/:id"] = { request in
            guard let id = request.params[":id"], !id.isEmpty else {
                return self.errorResponse(SimToolError("Missing session id"), statusCode: 400, reason: "Bad Request")
            }
            do {
                try self.inspectorEvents.publish { changes in
                    try self.testSessions.delete(id: id)
                    changes.emit(.tests, TestsTopicPayload(removedSession: id))
                }
                return self.jsonResponse(["ok": true])
            } catch {
                return self.testSessionErrorResponse(error)
            }
        }

        server.GET["/api/v1/tests/:id/video"] = { request in
            guard let id = request.params[":id"], !id.isEmpty else {
                return self.errorResponse(SimToolError("Missing session id"), statusCode: 400, reason: "Bad Request")
            }
            do {
                let file = try self.testSessions.videoFile(id: id)
                return self.videoFileResponse(file, rangeHeader: request.headers["range"])
            } catch {
                return self.testSessionErrorResponse(error)
            }
        }

        // A session's own network, logs and state, for reviewing it step by step
        // long after the server that recorded it is gone.
        server.GET["/api/v1/tests/:id/evidence/:name"] = { request in
            guard let id = request.params[":id"], let name = request.params[":name"]?.removingPercentEncoding, !id.isEmpty, !name.isEmpty else {
                return self.errorResponse(SimToolError("Missing session id or file name"), statusCode: 400, reason: "Bad Request")
            }
            do {
                let file = try self.testSessions.evidenceFile(id: id, name: name)
                return self.dataResponse(try Data(contentsOf: file), contentType: Self.evidenceContentType(file.pathExtension))
            } catch {
                return self.testSessionErrorResponse(error)
            }
        }

        server.GET["/api/v1/screenshot"] = { request in
            let maxDimension = request.queryInt("maxDim")
            if let maxDimension, maxDimension <= 0 {
                return self.errorResponse(SimToolError("maxDim must be positive"), statusCode: 400, reason: "Bad Request")
            }
            // A foldable's screenshot is of the lit screen unless `display` names another.
            let display: SimulatorDisplay?
            do {
                display = try self.displays.display(named: request.queryValue("display")?.removingPercentEncoding)
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
            // `bezel=1`: the device drawn around the screen, as Simulator shows it.
            let bezel = request.queryFlag("bezel")
            do {
                let data = try self.waitForAsync {
                    let png = try await SimulatorScreenshotClient.png(deviceUDID: self.config.device.udid, display: display?.id, maxDimension: bezel ? nil : maxDimension, masked: bezel)
                    guard bezel else { return png }
                    let framed = try self.framedScreenshot(png: png, display: display)
                    return try maxDimension.map { try SimulatorScreenshotClient.downscaled(pngData: framed, maxDimension: $0) } ?? framed
                }
                return self.dataResponse(data, contentType: "image/png")
            } catch {
                return self.errorResponse(error)
            }
        }

        // Screen recordings started from the viewer: one at a time, the newest
        // kept to download until the next one starts.
        server.GET["/api/v1/recording"] = { _ in
            do { return try self.jsonEncodedResponse(self.screenRecordings.topic) }
            catch { return self.errorResponse(error) }
        }

        // `{"bezel": true}`: saved with the device around the screen, as a
        // screenshot with `bezel=1` is.
        server.POST["/api/v1/recording"] = { request in
            let data = Data(request.body)
            let bezel = (data.isEmpty ? nil : try? JSON.decoder.decode(StartRecordingBody.self, from: data))?.bezel == true
            do {
                let shown = self.displays.shownDisplay
                let framer = bezel ? Self.bezelFramer(display: shown, rotation: self.displays.rotation(of: shown)) : nil
                return try self.jsonEncodedResponse(try self.screenRecordings.start(framer: framer))
            } catch ScreenRecordingError.alreadyRecording {
                return self.errorResponse(ScreenRecordingError.alreadyRecording, statusCode: 409, reason: "Conflict")
            } catch {
                return self.errorResponse(error)
            }
        }

        server.POST["/api/v1/recording/stop"] = { _ in
            let recordings = self.screenRecordings
            do {
                let recording: ScreenRecording = try self.waitForAsync { try await recordings.stop() }
                return try self.jsonEncodedResponse(recording)
            } catch ScreenRecordingError.notRecording {
                return self.errorResponse(ScreenRecordingError.notRecording, statusCode: 409, reason: "Conflict")
            } catch {
                return self.errorResponse(error)
            }
        }

        server.GET["/api/v1/recording/:id/video"] = { request in
            guard let id = request.params[":id"], !id.isEmpty else {
                return self.errorResponse(SimToolError("Missing recording id"), statusCode: 400, reason: "Bad Request")
            }
            do {
                return self.videoFileResponse(try self.screenRecordings.videoFile(id: id), rangeHeader: request.headers["range"])
            } catch {
                return self.errorResponse(error, statusCode: 404, reason: "Not Found")
            }
        }

        server["/stream.avcc"] = { request in
            if request.queryValue("view") == "3d" { return self.stream3DResponse(request) }
            // A viewer that names its stream says what it received on its
            // input channel, and gets a stream paced to its link.
            let streamID = request.queryValue("sid").flatMap(Self.pacedStreamID)
            let client = self.clientManager.addAvccClient(paced: streamID != nil)
            let paced = streamID.map { PacedStream(id: $0, client: client) }
            DebugLog.write("stream", "viewer \(client.id) connected" + (paced == nil ? "" : ", paced to its link"))
            return .raw(200, "OK", [
                "Content-Type": "application/octet-stream",
                "Cache-Control": "no-cache, no-store",
                "Connection": "keep-alive",
            ]) { writer in
                let semaphore = DispatchSemaphore(value: 0)
                client.setWriter({ data in
                    do {
                        try writer.write(data)
                        return true
                    } catch {
                        semaphore.signal()
                        return false
                    }
                }, onClose: { semaphore.signal() })
                // Frames reach a paced stream once its client can write them:
                // its first is the next capture — the screen's change, or its
                // idle refresh a moment later.
                if let paced { self.pacedLock.withLock { self.pacedStreams[paced.id] = paced } }
                self.clientManager.sendInitialAvcc(to: client)
                semaphore.wait()
                if let paced {
                    self.pacedLock.withLock { if self.pacedStreams[paced.id] === paced { self.pacedStreams[paced.id] = nil } }
                    paced.stop()
                }
                self.clientManager.removeAvccClient(client)
                self.slowViewersLock.withLock { _ = self.slowViewersSaid.removeValue(forKey: client.id) }
                DebugLog.write("stream", "viewer \(client.id) disconnected")
            }
        }
    }

    /// The id a viewer named its paced stream with, when it is one: letters,
    /// digits and dashes, 8 to 64 of them.
    static func pacedStreamID(_ raw: String) -> String? {
        guard (8...64).contains(raw.count),
              raw.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }) else { return nil }
        return raw
    }

    private func pacedStream(_ id: String) -> PacedStream? {
        pacedLock.withLock { pacedStreams[id] }
    }

    /// `/stream.avcc?view=3d&theme=dark&bg=1b1d20&aspect=0.8`: the 3D
    /// preview, in the same envelopes as the screen plus each frame's
    /// projection, framed for a stage of that shape. 503 with the reason when
    /// there is none to show.
    private func stream3DResponse(_ request: HttpRequest) -> HttpResponse {
        let view = view3D()
        guard let model = view.url, let layout = displays.current.layout, let stream = stateLock.withLock({ duo3D }) else {
            return errorResponse(SimToolError(view.reason ?? "the 3D preview is not running"), statusCode: 503, reason: "Service Unavailable")
        }
        let background = request.queryValue("bg").flatMap { $0.count == 6 && Int($0, radix: 16) != nil ? "#" + $0 : nil } ?? "#000000"
        let aspect = request.queryValue("aspect").flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let look = Duo3DStream.Look(dark: request.queryValue("theme") != "light", background: background, aspect: aspect)
        let role = displays.activeDisplay?.role ?? "cover"
        let hinge = displays.fold?.hingeDegrees ?? (role == "cover" ? 0 : 180)
        return .raw(200, "OK", [
            "Content-Type": "application/octet-stream",
            "Cache-Control": "no-cache, no-store",
            "Connection": "keep-alive",
        ]) { writer in
            let client = Duo3DStream.Client { data in (try? writer.write(data)) != nil }
            do {
                try stream.attach(client, model: model, layout: layout, panel: role, hinge: hinge, look: look)
            } catch {
                DebugLog.write("duo3d", "cannot start the renderer: \(error.localizedDescription)")
                return
            }
            client.ended.wait()
            stream.detach(client)
        }
    }

    private func wireInspectorEvents() {
        testRuns.onChange = { [weak self] in self?.publishTestRun() }
        // Outside the hub's lock: the snapshot reads the log under it, so the
        // log never takes the hub's lock under its own. The viewer keeps the
        // newer revision of an entry whichever way round two changes arrive.
        activity.observe { [weak self] entry, revision in
            // Whoever did it, something was done to the device.
            self?.usage.note()
            self?.inspectorEvents.publish(.activity, ActivityTopicPayload(entries: [entry], revision: revision))
        }
        let watcher = TestDefinitionsWatcher(root: config.testsRoot) { [weak self] in self?.publishTestDefinitions() }
        watcher.start()
        testDefinitionsWatcher = watcher
    }

    /// `GET /api/v1/events`: the inspector topics as Server-Sent Events. The
    /// stream opens with a snapshot or, reconnecting with `Last-Event-ID` (or
    /// `?lastEventId=` from a page that had to open a new EventSource), with the
    /// events it missed — and holds this connection's thread until the page goes.
    private func eventStreamResponse(_ request: HttpRequest) -> HttpResponse {
        // Swifter hands query values over still percent-encoded: `:` arrives as %3A.
        let lastEventID = request.headers["last-event-id"] ?? request.queryValue("lastEventId")?.removingPercentEncoding
        return .raw(200, "OK", [
            "Content-Type": "text/event-stream; charset=utf-8",
            "Cache-Control": "no-cache, no-store",
        ]) { writer in
            // Reconnect a second after a dropped stream or a restarted server.
            guard (try? writer.write(Data("retry: 1000\n\n".utf8))) != nil else { return }
            let subscription = self.inspectorEvents.subscribe(lastEventID: lastEventID) { self.inspectorSnapshot() }
            defer { self.inspectorEvents.unsubscribe(subscription) }
            // A comment when nothing changed for a while finds a page that is gone.
            while let chunk = subscription.next(timeout: 15) {
                guard (try? writer.write(chunk.isEmpty ? Data(": keep-alive\n\n".utf8) : chunk)) != nil else { return }
            }
        }
    }

    /// As many log lines as the viewer keeps.
    private static let snapshotLogLimit = 3_000
    private static let snapshotOwnLogLimit = 1_000

    /// Everything the inspector shows, each topic in the shape of its messages.
    /// Runs under the hub's lock, so no change lands in it by halves.
    private func inspectorSnapshot() -> InspectorSnapshotPayload {
        let logs = logEntries.query(since: nil, limit: Self.snapshotLogLimit)
        return InspectorSnapshotPayload(
            instance: inspectorEvents.instanceId,
            network: NetworkTopicPayload(
                events: networkLoggerEvents.query().events,
                mocks: mockRules.list(since: nil).rules,
                logger: loggerPeer.lastReport
            ),
            logs: LogsTopicPayload(entries: logs.entries, droppedCount: logs.droppedCount ?? 0),
            simtoolLogs: {
                let own = ownLog.query(since: nil, limit: Self.snapshotOwnLogLimit)
                return LogsTopicPayload(entries: own.entries, droppedCount: own.droppedCount ?? 0)
            }(),
            state: StateTopicPayload(events: stateLoggerEvents.query(since: nil, limit: .max).events),
            tests: TestsTopicPayload(sessions: testSessions.list().sessions, definitions: testRuns.list().tests, run: testRunStatus()),
            launches: AppLaunchesPayload(launches: launches.snapshot()),
            activity: {
                let page = activity.query(since: nil)
                return ActivityTopicPayload(entries: page.entries, revision: page.revision)
            }(),
            device: displays.topic,
            recording: screenRecordings.topic
        )
    }

    /// Runs `body`, which may register a new app launch, and emits the launch
    /// list first when it did — so a viewer knows the launch before its entries.
    /// Called from inside `publish`.
    private func trackingLaunches<T>(_ changes: inout InspectorEventHub.Changes, _ body: () -> T) -> T {
        let before = launches.currentLaunchId()
        let result = body()
        if launches.currentLaunchId() != before {
            changes.emit(.launches, AppLaunchesPayload(launches: launches.snapshot()))
        }
        return result
    }

    private func testRunStatus() -> TestRunStatusPayload {
        testRuns.status(activeSession: testSessions.activeSession)
    }

    /// Read under the hub's lock, so the last status sent is the latest one.
    private func publishTestRun() {
        inspectorEvents.publish { $0.emit(.tests, TestsTopicPayload(run: testRunStatus())) }
    }

    private func publishTestDefinitions() {
        inspectorEvents.publish { $0.emit(.tests, TestsTopicPayload(definitions: testRuns.list().tests)) }
    }

    private func openLiveInputChannel(for session: WebSocketSession) {
        let udid = config.device.udid
        let directInput = directInput
        let testSessions = testSessions
        let (events, continuation) = AsyncStream<LiveInputEvent>.makeStream()
        // One consumer per viewer keeps its events in order; the helper starts
        // now so the first touch does not wait for it.
        Task {
            try? await directInput.prepare(deviceUDID: udid)
            for await event in events {
                switch event {
                case let .touch(touch): await directInput.stream(touch, deviceUDID: udid)
                case let .key(key): await directInput.stream(key, deviceUDID: udid)
                }
            }
        }
        let usage = usage
        // What the person does by hand goes in the feed, measured in the
        // screen's points; the size is asked for at each gesture's start, so a
        // turn of the device is followed.
        let recorder = LiveInputActivity(log: activity)
        let refreshScreen: @Sendable () -> Void = {
            Task { recorder.setScreen(try? await SimulatorInputClient.screenSize(deviceUDID: udid)) }
        }
        refreshScreen()
        let channel = LiveInputChannel(
            emit: { event in
                usage.note()
                continuation.yield(event)
            },
            onDown: { [weak self] in
                testSessions.noteInput(at: Date())
                self?.noteLiveInputDuringRun()
            },
            observe: { event, character in
                switch event {
                case let .touch(touch):
                    if touch.phase == .down { refreshScreen() }
                    recorder.touch(touch)
                case let .key(key):
                    recorder.key(key, character: character)
                }
            },
            // Written from the socket's own reading thread, as the frames come in.
            reply: { [weak session] text in session?.writeText(text) },
            received: { [weak self] stream, total in
                guard let pace = self?.pacedStream(stream)?.received(total: total) else { return nil }
                return #"{"t":"pace","s":"\#(stream)","kbps":\#(pace.bitrate / 1000),"px":\#(pace.maxDimension),"fps":\#(pace.fpsCap),"full":\#(pace.full)}"#
            },
            arbiter: touchArbiter
        )
        liveInputLock.withLock { liveInputs[ObjectIdentifier(session)] = (channel, continuation) }
    }

    private func liveInputChannel(for session: WebSocketSession) -> LiveInputChannel? {
        liveInputLock.withLock { liveInputs[ObjectIdentifier(session)]?.channel }
    }

    private func closeLiveInputChannel(for session: WebSocketSession) {
        guard let entry = liveInputLock.withLock({ liveInputs.removeValue(forKey: ObjectIdentifier(session)) }) else { return }
        entry.channel.disconnect()
        entry.events.finish()
    }

    private func closeLiveInputs() {
        let entries = liveInputLock.withLock {
            defer { liveInputs.removeAll() }
            return Array(liveInputs.values)
        }
        for entry in entries {
            entry.channel.disconnect()
            entry.events.finish()
        }
    }

    private func configPayload() -> ServerConfigPayload {
        ServerConfigPayload(
            device: config.device.name,
            udid: config.device.udid,
            width: screenWidth,
            height: screenHeight,
            stream: StreamPaths(),
            metrics: metricsPayload(),
            logApp: config.defaultLogApp,
            testSessionsPath: config.testSessionsRoot.path,
            instanceId: inspectorEvents.instanceId,
            runtime: config.device.runtime,
            version: SimToolVersion.current,
            deviceType: displays.current.layout?.deviceType ?? config.device.deviceTypeIdentifier,
            displays: displays.current.layout == nil ? nil : displays.payloads,
            activeDisplay: displays.activeDisplay?.id,
            fold: displays.fold,
            view3d: displays.isFoldable ? { let view = view3D(); return ServerView3DPayload(available: view.url != nil, reason: view.reason) }() : nil,
            power: power.current,
            network: networkPayload()
        )
    }

    /// How a device on the network opens this server, when it is open to it.
    func networkPayload() -> ServerNetworkPayload? {
        guard let network = config.network else { return nil }
        return ServerNetworkPayload(
            urls: network.urls(port: config.port),
            certificate: network.identity.authority == nil ? nil : NetworkPages.authorityPath,
            certificateFingerprint: network.identity.authorityFingerprint
        )
    }

    /// The addresses to print for the network.
    public var networkURLs: [String] { config.network?.urls(port: config.port) ?? [] }

    private func statusPayload() -> ServerStatusPayload {
        ServerStatusPayload(
            device: config.device.name,
            udid: config.device.udid,
            width: screenWidth,
            height: screenHeight,
            healthy: true,
            metrics: metricsPayload(),
            power: power.current
        )
    }

    private func metricsPayload() -> StreamMetricsPayload {
        metrics.snapshot(clients: clientManager.clientCounts(), pacedViewers: pacedLock.withLock { Array(pacedStreams.values) }.map { $0.metrics() })
    }

    private func handleInput(_ request: HttpRequest) -> HttpResponse {
        let input: SimulatorInputPayload
        do {
            input = try decodeJSON(SimulatorInputPayload.self, from: request)
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
        let action = (input.action ?? input.type ?? "").lowercased()
        let (actor, via) = activityActor(of: request)
        let words = DeviceActivityWording.describe(input, action: action)
        let entry = activity.begin(actor: actor, via: via, kind: words.kind, title: words.title, detail: words.detail)
        let activity = activity
        do {
            // Stamped before the gesture so a step entry lands on the frame
            // just before its action; failed inputs never reach noteInput.
            let startedAt = Date()
            let output = try waitForAsync {
                // Where the finger goes is known before it goes down: the
                // viewer draws it while it moves.
                try await self.perform(input: input, action: action) { stroke, screen in
                    let words = DeviceActivityWording.describe(input, action: action, stroke: stroke)
                    activity.update(id: entry.id) {
                        $0.title = words.title
                        $0.detail = words.detail
                        $0.gesture = DeviceActivityGesture(stroke: stroke, screen: screen)
                    }
                }
            }
            testSessions.noteInput(at: startedAt)
            // A fold or a turn says where the device came to rest.
            if action == "pose" || action == "rotate", !output.stdoutString.isEmpty {
                activity.update(id: entry.id) { $0.detail = output.stdoutString }
            }
            activity.finish(id: entry.id)
            return try jsonEncodedResponse(CommandResultPayload(
                ok: true,
                stdout: output.stdoutString,
                stderr: output.stderrString
            ))
        } catch {
            activity.finish(id: entry.id, error: error.localizedDescription)
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    // MARK: - the network conditions

    /// Sets the conditions (or turns them off) as one activity; with
    /// `relaunch`, launches the app again — as it was last launched — when it
    /// does not have them yet.
    private func handleNetworkCondition(_ request: HttpRequest, off: Bool) -> HttpResponse {
        let asked: NetworkConditionRequest
        let condition: NetworkCondition?
        do {
            asked = off || request.body.isEmpty ? NetworkConditionRequest(profile: "off") : try decodeJSON(NetworkConditionRequest.self, from: request)
            condition = try asked.resolve()
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
        let (actor, via) = activityActor(of: request)
        let udid = config.device.udid
        let entry = activity.begin(actor: actor, via: via, kind: "network-condition", title: "Network: " + (condition?.title ?? "as it is"))
        do {
            var state = try waitForAsync { try await SimulatorNetworkConditioner.set(condition, deviceUDID: udid) }
            let app = config.defaultLogApp
            if condition != nil, asked.relaunch == true, let app, !state.apps.contains(where: { $0.bundleId == app }) {
                let record = appRelaunch.launch(of: app) ?? AppLaunchRecord(bundleId: app)
                let output = try waitForAsync { try await self.launchApp(record) }
                var launched = record
                launched.pid = AppLaunchRecord.pid(fromLaunchOutput: output.stdoutString)
                appRelaunch.launched(launched)
                // Its first heartbeat says it has them.
                for _ in 0..<12 where !state.apps.contains(where: { $0.bundleId == app }) {
                    Thread.sleep(forTimeInterval: 0.25)
                    state = SimulatorNetworkConditioner.state(deviceUDID: udid)
                }
            }
            activity.update(id: entry.id) { entry in
                let apps = state.apps.map(\.bundleId)
                entry.detail = (condition?.summary ?? "no delay, no limit, no loss") + " · " + (apps.isEmpty
                    ? (condition == nil ? "no app had it" : "no app has it yet: an app gets it when SimTool launches it")
                    : apps.joined(separator: ", ") + (apps.count == 1 ? " has it" : " have it"))
            }
            activity.finish(id: entry.id)
            return try jsonEncodedResponse(state)
        } catch {
            activity.finish(id: entry.id, error: error.localizedDescription)
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    // MARK: - the simulator's camera

    private func cameraState() -> SimulatorCameraState {
        var state = SimulatorCamera.state(deviceUDID: config.device.udid)
        state.macCameras = MacCameraFeed.cameras()
        return state
    }

    private func stopCameraFeed() {
        let feed = stateLock.withLock {
            defer { cameraFeed = nil }
            return cameraFeed
        }
        feed?.stop()
    }

    /// One camera change as an activity: its title names the new source, its
    /// detail which apps see it — an app launched while the camera was off
    /// gets it only at its next launch through SimTool.
    private func cameraActivity(of request: HttpRequest, title: String, _ body: () throws -> SimulatorCameraState) throws -> SimulatorCameraState {
        let (actor, via) = activityActor(of: request)
        let entry = activity.begin(actor: actor, via: via, kind: "camera", title: title)
        do {
            let state = try body()
            activity.update(id: entry.id) { entry in
                entry.title = "Camera: " + state.summary
                entry.detail = state.apps.isEmpty
                    ? "No app has it yet: an app gets it when SimTool launches it — relaunch \(self.config.defaultLogApp ?? "the app")"
                    : state.apps.map(\.bundleId).joined(separator: ", ") + " sees it"
            }
            activity.finish(id: entry.id)
            return state
        } catch {
            activity.finish(id: entry.id, error: error.localizedDescription)
            throw error
        }
    }

    /// An image or a video in the body becomes the camera's picture.
    private func handleCameraFile(_ request: HttpRequest) -> HttpResponse {
        do {
            let file = try receiveMedia(request, accepting: [.image, .video])
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let udid = config.device.udid
            _ = try cameraActivity(of: request, title: "Camera: " + file.lastPathComponent) {
                let state = try self.waitForAsync { try await SimulatorCamera.setFile(file, deviceUDID: udid) }
                self.stopCameraFeed()
                return state
            }
            return try jsonEncodedResponse(cameraState())
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    /// The Mac's webcam — the one the body names (`{"camera": id or name}`),
    /// else the default — becomes the camera's picture.
    private func handleWebcam(_ request: HttpRequest) -> HttpResponse {
        do {
            let requested = request.body.isEmpty ? nil : try decodeJSON([String: String].self, from: request)["camera"]
            let udid = config.device.udid
            _ = try cameraActivity(of: request, title: "Camera: the Mac's camera") {
                self.stopCameraFeed()
                let feed = try self.waitForAsync { try await MacCameraFeed.start(camera: requested, deviceUDID: udid) }
                do {
                    let state = try self.waitForAsync { try await SimulatorCamera.setWebcam(name: feed.camera.name, deviceUDID: udid) }
                    self.stateLock.withLock { self.cameraFeed = feed }
                    return state
                } catch {
                    feed.stop()
                    throw error
                }
            }
            return try jsonEncodedResponse(cameraState())
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    /// The app a request names, or the server's own.
    private func bundleId(_ requested: String?) throws -> String {
        guard let bundleId = requested.flatMap({ $0.isEmpty ? nil : $0 }) ?? config.defaultLogApp else {
            throw SimToolError("Name the app: pass bundleId, or start the server with --app")
        }
        return bundleId
    }

    /// Installs the build in the body: an `.ipa`, or a tar of a `.app` — what
    /// the viewer sends for a bundle dropped on its screen.
    private func handleInstall(_ request: HttpRequest) -> HttpResponse {
        do {
            guard !request.body.isEmpty else { throw SimToolError("The request body must be the .ipa, or a tar of the .app") }
            let name = request.headers["x-simtool-filename"].flatMap { $0.removingPercentEncoding }.map { ($0 as NSString).lastPathComponent } ?? "upload"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simtool-install-upload-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent(name.isEmpty ? "upload" : name)
            try Data(request.body).write(to: file)
            let udid = config.device.udid
            let installed = try recordingActivity(of: request, kind: "install", title: "Install " + (name as NSString).deletingPathExtension.replacingOccurrences(of: ".app", with: "")) {
                try self.waitForAsync { try await SimulatorAppInstaller.install(file, deviceUDID: udid) }
            }
            // The upload's name was a guess; the bundle says what it is.
            if let entry = activity.last(where: { $0.kind == "install" }) {
                activity.update(id: entry.id) { $0.title = "Install " + installed.name; $0.detail = installed.bundleId }
            }
            return try jsonEncodedResponse(installed)
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    private func isJSON(_ request: HttpRequest) -> Bool {
        (request.headers["content-type"] ?? "").lowercased().hasPrefix("application/json")
    }

    /// Starts fetching a build from a URL; answers 202 with the job, or 409
    /// with the one already running.
    private func handleInstallFromURL(_ request: HttpRequest) -> HttpResponse {
        let body: AppInstallURLRequest
        let url: URL
        do {
            body = try decodeJSON(AppInstallURLRequest.self, from: request)
            guard let address = body.url, !address.isEmpty else { throw SimToolError("Name the build: url") }
            guard let parsed = URL(string: address), let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http", parsed.host != nil else {
                throw SimToolError("url must be an http(s) address of the build")
            }
            url = parsed
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
        let source = SimulatorAppArchive.displaySource(url)
        let app = body.app.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let candidate = AppInstallJob(id: UUID().uuidString.lowercased(), state: .downloading, source: source, app: app, label: body.label,
                                      receivedBytes: 0, totalBytes: nil, cached: false, startedAt: Date())
        let (job, started) = installJobs.start(candidate)
        guard started else {
            do { return try jsonEncodedResponse(job, statusCode: 409, reason: "Conflict") } catch { return errorResponse(error) }
        }
        usage.note()
        let (actor, via) = activityActor(of: request)
        let title = "Install " + (body.label ?? (app ?? url.lastPathComponent))
        let entry = activity.begin(actor: actor, via: via, kind: "install", title: title, detail: AppInstallJobs.progressDetail(job))
        DebugLog.info("install", "fetching \(source)" + (app.map { " (\($0))" } ?? ""))
        let headers = body.headers ?? [:]
        let clean = body.clean ?? false
        let launch = body.launch
        Task.detached { [self] in
            await self.runInstall(job.id, url: url, headers: headers, clean: clean, launch: launch, activityId: entry.id)
        }
        do { return try jsonEncodedResponse(job, statusCode: 202, reason: "Accepted") } catch { return errorResponse(error) }
    }

    /// The job behind `handleInstallFromURL`: the simulator on, the build
    /// fetched (or found from before), its app unpacked, installed and maybe
    /// launched — each step told to the job and the activity feed.
    private func runInstall(_ id: String, url: URL, headers: [String: String], clean: Bool, launch: AppInstallLaunch?, activityId: Int) async {
        let activity = activity
        @Sendable func step(_ change: (inout AppInstallJob) -> Void) {
            guard let job = installJobs.update(id: id, change) else { return }
            activity.update(id: activityId) { $0.detail = AppInstallJobs.progressDetail(job) }
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("simtool-install-\(id)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try await wake()
            guard let job = installJobs.current, job.id == id else { return }
            let key = SimulatorAppDownloadCache.key(source: job.source, app: job.app)
            let bundle: URL
            if let kept = downloadCache.bundle(for: key) {
                DebugLog.info("install", "\(job.source) was fetched before: installing it again")
                step { $0.cached = true; $0.state = .installing }
                bundle = kept
            } else {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let archive = scratch.appendingPathComponent("build" + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension))
                let usage = usage
                try await SimulatorAppArchive.download(url, headers: headers, to: archive) { received, total in
                    usage.note()
                    step { $0.receivedBytes = received; $0.totalBytes = total }
                }
                step { $0.state = .unpacking }
                let unpacked = try await SimulatorAppArchive.unpackApp(from: archive, named: job.app, into: scratch.appendingPathComponent("unpacked", isDirectory: true))
                try? FileManager.default.removeItem(at: archive)
                bundle = try downloadCache.store(unpacked, for: key)
                step { $0.state = .installing }
            }
            let info = try SimulatorAppInstaller.info(of: bundle)
            step { $0.bundleId = info.bundleId; $0.name = info.name; $0.version = info.version; $0.build = info.build }
            let udid = config.device.udid
            if clean {
                appRelaunch.terminated(bundleId: info.bundleId)
                try await SimulatorAppInstaller.uninstall(bundleId: info.bundleId, deviceUDID: udid)
            }
            _ = try await SimulatorAppInstaller.install(bundle: bundle, deviceUDID: udid)
            if let launch {
                step { $0.state = .launching }
                let pid = try await launchRecorded(AppLaunchRecord(bundleId: info.bundleId, arguments: launch.arguments ?? [], environment: launch.environment ?? [:]))
                step { $0.pid = pid }
            }
            usage.note()
            step { $0.state = .done; $0.finishedAt = Date() }
            activity.finish(id: activityId)
            DebugLog.info("install", "installed \(info.bundleId) from \(job.source)")
        } catch {
            usage.note()
            step { $0.state = .failed; $0.error = error.localizedDescription; $0.finishedAt = Date() }
            activity.finish(id: activityId, error: error.localizedDescription)
            DebugLog.error("install", "\(error.localizedDescription)")
        }
    }

    /// Launches an app as `record` says — a running one again — and keeps the
    /// launch so the app comes back with the simulator. Answers its pid.
    private func launchRecorded(_ record: AppLaunchRecord) async throws -> Int? {
        let output = try await launchApp(record)
        var launched = record
        launched.pid = AppLaunchRecord.pid(fromLaunchOutput: output.stdoutString)
        appRelaunch.launched(launched)
        return launched.pid
    }

    private func handleLaunch(_ request: HttpRequest) -> HttpResponse {
        do {
            let body = try decodeJSON(AppLaunchRequest.self, from: request)
            guard !body.bundleId.isEmpty else { throw SimToolError("Name the app: bundleId") }
            let record = AppLaunchRecord(bundleId: body.bundleId, arguments: body.arguments ?? [], environment: body.environment ?? [:])
            let detail = record.arguments.isEmpty ? nil : record.arguments.joined(separator: " ")
            let pid = try recordingActivity(of: request, kind: "launch", title: "Launch " + body.bundleId, detail: detail) {
                try self.waitForAsync {
                    try await self.wake()
                    return try await self.launchRecorded(record)
                }
            }
            var answer: [String: Any] = ["bundleId": body.bundleId]
            if let pid { answer["pid"] = pid }
            return jsonResponse(answer)
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    /// Changes a setting of the device or acts on it, as one activity entry.
    private func handleDeviceControl(_ request: HttpRequest) -> HttpResponse {
        let control: DeviceControlPayload
        do {
            control = try decodeJSON(DeviceControlPayload.self, from: request)
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
        let (actor, via) = activityActor(of: request)
        let words = DeviceActivityWording.describe(control: control)
        let entry = activity.begin(actor: actor, via: via, kind: words.kind, title: words.title, detail: words.detail)
        let udid = config.device.udid, app = config.defaultLogApp
        defer { deviceSettings.invalidate() }
        do {
            let startedAt = Date()
            let result = try waitForAsync { try await SimulatorDeviceControl.perform(control, deviceUDID: udid, app: app) }
            testSessions.noteInput(at: startedAt)
            if DeviceActivityWording.reportsResult(of: control) { activity.update(id: entry.id) { $0.detail = [words.detail, result].compactMap { $0 }.joined(separator: " · ") } }
            activity.finish(id: entry.id)
            return try jsonEncodedResponse(CommandResultPayload(ok: true, stdout: result, stderr: ""))
        } catch {
            activity.finish(id: entry.id, error: error.localizedDescription)
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    /// Who sent a request that acts on the device. The viewer says so in a
    /// header; anything else is an agent — or, while a test session records,
    /// the run itself, which drives the device over this same API.
    private func activityActor(of request: HttpRequest) -> (DeviceActivityActor, String) {
        if request.headers["x-simtool-source"]?.lowercased() == "viewer" { return (.viewer, "viewer") }
        return (testSessions.activeSession != nil ? .test : .agent, "api")
    }

    /// A person touching the device while a test records is part of that
    /// run's story. One entry per burst: a drag or a typed word is one
    /// interference, not forty.
    private func noteLiveInputDuringRun() {
        guard testSessions.activeSession != nil else { return }
        let now = Date()
        if let last = activity.last(where: { $0.kind == "live-input" }), now.timeIntervalSince(last.endedAt ?? last.at) < 3 {
            activity.update(id: last.id) { $0.endedAt = now }
            return
        }
        activity.record(actor: .viewer, via: "viewer", kind: "live-input", title: "Touched by hand during the run")
    }

    private static func evidenceContentType(_ pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "jsonl": "application/x-ndjson"
        case "json": "application/json"
        case "png": "image/png"
        default: "text/plain; charset=utf-8"
        }
    }

    private static func mockAnswer(_ draft: MockRuleDraft) -> String {
        let answer = switch draft.response.kind {
        case .success: draft.response.bodyJSON == nil ? "answers empty" : "answers a body"
        case .error: "fails with " + (draft.response.grpcStatus ?? "an error")
        }
        return draft.match.times.map { answer + ", \($0)×" } ?? answer
    }

    /// The image arrives as the raw body; Content-Type and the percent-encoded
    /// X-SimTool-Filename header say what it is.
    private func handlePasteImage(_ request: HttpRequest) -> HttpResponse {
        do {
            let file = try receiveMedia(request, accepting: [.image])
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let startedAt = Date()
            let output = try recordingActivity(of: request, kind: "paste", title: "Paste an image", detail: file.lastPathComponent) {
                try self.waitForAsync { try await SimulatorInputClient.pasteImage(at: file, deviceUDID: self.config.device.udid) }
            }
            testSessions.noteInput(at: startedAt)
            return try jsonEncodedResponse(CommandResultPayload(ok: true, stdout: output.stdoutString, stderr: output.stderrString))
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    /// Runs `body` as one activity of whoever sent `request`.
    private func recordingActivity<T>(of request: HttpRequest, kind: String, title: String, detail: String? = nil, _ body: () throws -> T) throws -> T {
        let (actor, via) = activityActor(of: request)
        let entry = activity.begin(actor: actor, via: via, kind: kind, title: title, detail: detail)
        do {
            let result = try body()
            activity.finish(id: entry.id)
            return result
        } catch {
            activity.finish(id: entry.id, error: error.localizedDescription)
            throw error
        }
    }

    private func handleAddToPhotos(_ request: HttpRequest) -> HttpResponse {
        do {
            let file = try receiveMedia(request, accepting: [.image, .video])
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let output = try recordingActivity(of: request, kind: "photos", title: "Add " + file.lastPathComponent + " to Photos") {
                try self.waitForAsync { try await SimulatorPhotosClient.add([file], deviceUDID: self.config.device.udid) }
            }
            return try jsonEncodedResponse(CommandResultPayload(ok: true, stdout: output.stdoutString, stderr: output.stderrString))
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    /// Saves an uploaded body under a name whose extension tells simctl and
    /// devicectl its type, alone in a fresh temporary directory the caller removes.
    private func receiveMedia(_ request: HttpRequest, accepting kinds: Set<MediaUpload.Kind>) throws -> URL {
        guard !request.body.isEmpty else { throw SimToolError("The request body must be the file's bytes") }
        let suggested = request.headers["x-simtool-filename"].flatMap { $0.removingPercentEncoding }
        guard let name = MediaUpload.fileName(suggested: suggested, contentType: request.headers["content-type"]),
              let kind = MediaUpload.kind(ofExtension: (name as NSString).pathExtension),
              kinds.contains(kind) else {
            let expected = kinds.contains(.video) ? "an image or a video" : "an image"
            throw SimToolError("The upload is not \(expected): send its Content-Type (image/png, …) or an X-SimTool-Filename with its extension")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data(request.body).write(to: file)
        return file
    }

    private func handleNetworkLoggerIngestion(_ request: HttpRequest) -> HttpResponse {
        do {
            let data = Data(request.body)
            guard !data.isEmpty else { throw SimToolError("Request body must be JSON") }
            // Event by event: one this server cannot read costs the batch nothing else.
            let (batch, rejected) = try NetworkLoggerBatchPayload.decodingEachEvent(from: data, decoder: JSON.decoder)
            return try jsonEncodedResponse(inspectorEvents.publish { changes in
                // The release the logger reports rides with its calls, in one message;
                // a viewer is told only when it is not the one heard before.
                let logger = loggerPeer.heard(version: batch.loggerVersion)
                let events = trackingLaunches(&changes) { taggedWithLaunch(batch) }
                var response = networkLoggerEvents.ingest(events)
                if rejected > 0 { response.rejectedCount = rejected }
                if !events.isEmpty || logger != nil {
                    changes.emit(.network, NetworkTopicPayload(events: events.isEmpty ? nil : events, logger: logger))
                }
                return response
            })
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    /// Attributes an ingested batch to an app launch using its process id, stamping each event with
    /// the resolved `launchId`. Batches without a `pid` (older app builds) are stored untagged.
    private func taggedWithLaunch(_ batch: NetworkLoggerBatchPayload) -> [NetworkLoggerEvent] {
        guard let pid = batch.pid, !batch.events.isEmpty else { return batch.events }
        let timestamp = batch.events.map(\.timestamp).min() ?? batch.events[0].timestamp
        let launchId = launches.observe(pid: pid, app: batch.events.first?.appBundleID, timestamp: timestamp)
        return batch.events.map { event in
            var event = event
            event.pid = event.pid ?? pid
            event.launchId = launchId
            return event
        }
    }

    private func handleStateLoggerIngestion(_ request: HttpRequest) -> HttpResponse {
        do {
            let batch = try decodeJSON(StateLoggerBatchPayload.self, from: request)
            return try jsonEncodedResponse(inspectorEvents.publish { changes in
                let events = trackingLaunches(&changes) { stateEventsTaggedWithLaunch(batch) }
                let recorded = stateLoggerEvents.record(events)
                if !recorded.isEmpty { changes.emit(.state, StateTopicPayload(events: recorded)) }
                return StateLoggerIngestionResponse(acceptedCount: recorded.count)
            })
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    /// Mirrors `taggedWithLaunch(_:)` for state events: attributes a batch to an app
    /// launch by its pid and stamps each event with the resolved `launchId`.
    private func stateEventsTaggedWithLaunch(_ batch: StateLoggerBatchPayload) -> [StateLoggerEvent] {
        guard let pid = batch.pid, !batch.events.isEmpty else { return batch.events }
        let earliest = batch.events.map(\.timestamp).min() ?? batch.events[0].timestamp
        let timestamp = Self.stateTimestampFormatter.string(from: Date(timeIntervalSince1970: earliest))
        let launchId = launches.observe(pid: pid, timestamp: timestamp)
        return batch.events.map { event in
            var event = event
            event.pid = event.pid ?? pid
            event.launchId = launchId
            return event
        }
    }

    private func networkLoggerFilter(from request: HttpRequest) throws -> NetworkLoggerEventFilter {
        // Any protocol name: a logger may report one this server has never heard of.
        let networkProtocol = request.queryValue("protocol").flatMap { $0.isEmpty ? nil : NetworkLoggerProtocol($0) }
        return NetworkLoggerEventFilter(
            app: request.queryValue("app"),
            networkProtocol: networkProtocol,
            session: request.queryValue("session").flatMap { $0.isEmpty ? nil : $0 },
            since: request.queryValue("since"),
            limit: request.queryInt("limit") ?? 200
        )
    }

    private func startLogCapture(_ request: LogCaptureStartRequest) throws -> LogCaptureStatusPayload {
        let device = request.device.flatMap { $0.isEmpty ? nil : $0 } ?? config.device.udid
        // Scope to the server's configured app and capture its stdout/print plus OSLog. Starting
        // capture relaunches the app once (`--console-pty`); the idempotent + server-owned logic
        // below ensures reopening the viewer never relaunches it again.
        let app = request.app.flatMap { $0.isEmpty ? nil : $0 } ?? config.defaultLogApp
        let captureStdout = request.captureStdout ?? (app != nil)
        if captureStdout && app == nil {
            throw SimToolError("Capturing stdout/print requires an app bundle identifier")
        }

        logLock.lock()
        // Idempotent: identical parameters reuse the running capture.
        if let info = logCaptureInfo, logCapture != nil,
           info.device == device, info.app == app, info.captureStdout == captureStdout {
            logLastPollAt = Date()
            logLock.unlock()
            return currentLogStatus()
        }
        // Different parameters: last-writer-wins restart. The capture that
        // ran before the simulator went off picks up where it left off.
        let resuming = resumedLogCapture.map { $0 == (device, app, captureStdout) } ?? false
        resumedLogCapture = nil
        logCapture?.stop()
        logCapture = nil
        logCaptureInfo = nil
        if !resuming {
            inspectorEvents.publish { changes in
                logEntries.clear()
                changes.emit(.logs, LogsTopicPayload(droppedCount: 0, cleared: true))
            }
        }

        // The stdout capture launches the app again: as it was last launched.
        let relaunch = captureStdout ? app.flatMap { appRelaunch.launch(of: $0) } : nil
        let capture = SimulatorLogCapture(
            options: SimulatorLogCapture.Options(
                deviceUDID: device,
                app: app,
                captureStdout: captureStdout,
                bundleID: app,
                launchArguments: relaunch?.arguments ?? [],
                launchEnvironment: relaunch?.environment ?? [:]
            )
        ) { [weak self] draft in
            guard let self else { return }
            self.inspectorEvents.publish { changes in
                // OSLog lines carry a process id, so they drive launch detection; stdout/print has no
                // per-line pid and adopts the current launch.
                let launchId: Int? = self.trackingLaunches(&changes) {
                    guard let pid = draft.pid else { return self.launches.currentLaunchId() }
                    let launchId = self.launches.observe(pid: pid, app: app, timestamp: draft.timestamp)
                    // Crash summaries are logged by the launch that follows the crash but describe
                    // the previous one - file them under the launch that actually crashed.
                    if draft.category == Self.crashReportCategory,
                       let crashed = self.launches.launchId(preceding: launchId) {
                        return crashed
                    }
                    return launchId
                }
                let entry = self.logEntries.append(draft, launchId: launchId)
                changes.emit(.logs, LogsTopicPayload(entries: [entry], droppedCount: self.logEntries.droppedCount()))
            }
        }
        do {
            try capture.start()
        } catch {
            logLock.unlock()
            throw error
        }
        // That relaunch is the app's newest launch; its process is unknown.
        if captureStdout, let app {
            appRelaunch.launched(relaunch.map { AppLaunchRecord(bundleId: app, arguments: $0.arguments, environment: $0.environment) } ?? AppLaunchRecord(bundleId: app))
        }
        logCapture = capture
        logCaptureInfo = (device, app, captureStdout)
        logLastPollAt = Date()
        startLogIdleWatchLocked()
        logLock.unlock()
        return currentLogStatus()
    }

    private func logCaptureEntries(since: Int?, limit: Int) throws -> LogCaptureEntriesPayload {
        logLock.lock()
        logLastPollAt = Date()
        logLock.unlock()
        return logEntries.query(since: since, limit: limit)
    }

    @discardableResult
    private func stopLogCapture() -> LogCaptureStatusPayload {
        logLock.lock()
        logCapture?.stop()
        logCapture = nil
        logCaptureInfo = nil
        logIdleTask?.cancel()
        logIdleTask = nil
        logLock.unlock()
        return currentLogStatus()
    }

    /// Caller must hold `logLock`.
    private func startLogIdleWatchLocked() {
        logIdleTask?.cancel()
        // The server-owned capture for the configured default app is never idle-reaped: it lives
        // for the server's lifetime, so reopening the viewer reuses it without relaunching the app.
        // Only ad-hoc captures (a different app) are torn down on idle.
        if let app = logCaptureInfo?.app, app == config.defaultLogApp {
            logIdleTask = nil
            return
        }
        let timeout = logIdleTimeout
        logIdleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                let snapshot = self.logIdleSnapshot()
                guard snapshot.active else { return }
                if snapshot.idle > timeout {
                    self.stopLogCapture()
                    return
                }
            }
        }
    }

    private func logIdleSnapshot() -> (active: Bool, idle: TimeInterval) {
        // A viewer on the event stream reads every line without polling for it.
        let watched = inspectorEvents.subscriberCount > 0
        logLock.lock()
        defer { logLock.unlock() }
        return (logCapture != nil, watched ? 0 : Date().timeIntervalSince(logLastPollAt))
    }

    private func currentLogStatus() -> LogCaptureStatusPayload {
        logLock.lock()
        let info = logCaptureInfo
        logLock.unlock()
        return LogCaptureStatusPayload(
            active: info != nil,
            device: info?.device,
            app: info?.app,
            captureStdout: info?.captureStdout ?? false,
            droppedCount: logEntries.droppedCount()
        )
    }

    /// Performs one API input. A touch is worked out first and handed to
    /// `onStroke` just before it plays.
    private func perform(
        input: SimulatorInputPayload,
        action: String,
        onStroke: @escaping @Sendable (TouchStroke, SimulatorScreenSize?) -> Void = { _, _ in }
    ) async throws -> ProcessOutput {
        let udid = config.device.udid
        @Sendable func play(_ stroke: TouchStroke) async throws -> ProcessOutput {
            onStroke(stroke, try? await SimulatorInputClient.screenSize(deviceUDID: udid))
            return try await SimulatorInputClient.play(stroke, deviceUDID: udid)
        }
        switch action {
        case "tap":
            if (input.x == nil) != (input.y == nil) {
                throw SimToolError("Tap requires both x and y when using coordinates")
            }
            let point = try await points(input.x, input.y, of: input)
            let target = try await SimulatorInputClient.touchPoint(deviceUDID: udid, x: point?.x, y: point?.y, id: input.id, label: input.label, action: "Tap")
            return try await play(.tap(at: target))
        case "longpress", "long-press":
            if (input.x == nil) != (input.y == nil) {
                throw SimToolError("Long press requires both x and y when using coordinates")
            }
            let point = try await points(input.x, input.y, of: input)
            let target = try await SimulatorInputClient.touchPoint(deviceUDID: udid, x: point?.x, y: point?.y, id: input.id, label: input.label, action: "Long press")
            let duration = input.duration ?? TouchStroke.longPressDuration
            onStroke(.longPress(at: target, duration: max(0.1, duration)), try? await SimulatorInputClient.screenSize(deviceUDID: udid))
            // Through longPress rather than play: it warns about a press too short to register.
            return try await SimulatorInputClient.longPress(deviceUDID: udid, x: target.x, y: target.y, duration: duration)
        case "type", "typetext", "text":
            guard let text = input.text else { throw SimToolError("Type input requires text") }
            return try await SimulatorInputClient.typeText(text, deviceUDID: config.device.udid)
        case "paste":
            guard let text = input.text, !text.isEmpty else { throw SimToolError("Paste input requires text") }
            return try await SimulatorInputClient.paste(text, deviceUDID: config.device.udid)
        case "swipe", "drag":
            guard let startX = input.startX,
                  let startY = input.startY,
                  let endX = input.endX,
                  let endY = input.endY else {
                throw SimToolError("\(action == "drag" ? "Drag" : "Swipe") requires startX, startY, endX, and endY")
            }
            guard let start = try await points(startX, startY, of: input),
                  let end = try await points(endX, endY, of: input) else {
                throw SimToolError("\(action == "drag" ? "Drag" : "Swipe") requires startX, startY, endX, and endY")
            }
            if action == "drag" {
                return try await play(.drag(
                    from: start,
                    to: end,
                    press: input.press ?? TouchStroke.dragPress,
                    velocity: input.velocity ?? TouchStroke.dragVelocity,
                    hold: input.hold ?? TouchStroke.dragHold
                ))
            }
            // The old pixel swipe from a viewer is a straight move lifted in motion.
            let pixels = input.coordinateSpace?.lowercased() == "pixels"
            return try await play(SimulatorInputClient.swipeStroke(
                from: start,
                to: end,
                duration: input.duration ?? (pixels ? 0.2 : nil),
                velocity: input.velocity,
                hold: input.hold ?? (pixels ? 0 : nil)
            ))
        case "scroll", "fling":
            guard let raw = input.direction, let direction = TouchDirection(rawValue: raw.lowercased()) else {
                throw SimToolError("\(action == "fling" ? "Fling" : "Scroll") requires direction: up, down, left or right")
            }
            if (input.x == nil) != (input.y == nil) {
                throw SimToolError("A start point needs both x and y")
            }
            let start = try await points(input.x, input.y, of: input)
            if action == "fling" {
                let velocity = input.velocity ?? TouchStroke.flingVelocity
                return try await play(try await SimulatorInputClient.flingStroke(deviceUDID: udid, direction: direction, velocity: velocity, x: start?.x, y: start?.y))
            }
            return try await play(try await SimulatorInputClient.scrollStroke(deviceUDID: udid, direction: direction, distance: input.distance, x: start?.x, y: start?.y))
        case "pose":
            // A foldable's hinge: a named pose or an angle, confirmed by the device.
            let pose: SimulatorPose
            if let angle = input.angle {
                pose = try SimulatorPose(parsing: String(angle))
            } else if let name = input.name {
                pose = try SimulatorPose(parsing: name)
            } else {
                throw SimToolError("Pose input requires name (closed, book, open) or angle (0…180)")
            }
            let displays = displays
            let monitor = stateLock.withLock { displayMonitor }
            let state = try await SimulatorFoldClient.shared.fold(
                to: pose,
                from: displays.fold?.hingeDegrees,
                layout: displays.current.layout,
                deviceUDID: udid
            ) {
                await monitor?.refresh()
                return (displays.current.state?.active, displays.fold)
            }
            return ProcessOutput(status: 0, stdout: Data(state.summary.utf8))
        case "rotate", "orientation":
            // Simulator.app's Rotate Left / Right; the picture turns once the
            // device has, and is read again at once.
            guard let name = input.name, !name.isEmpty else {
                throw SimToolError("Rotate input requires name: portrait, landscape-left, landscape-right, upside-down, left or right")
            }
            let reached = try await SimulatorOrientation.rotate(to: name, deviceUDID: udid, layout: displays.current.layout)
            await stateLock.withLock { displayMonitor }?.refresh()
            return ProcessOutput(status: 0, stdout: Data(reached.title.utf8))
        case "shake":
            // Same darwin notification Simulator.app's Device > Shake menu posts;
            // UIKit in the simulated OS turns it into motionEnded(.motionShake).
            return try await ProcessRunner.runXcrun(["simctl", "spawn", config.device.udid, "notifyutil", "-p", "com.apple.UIKit.SimulatorShake"])
        case "terminate":
            // Kills the app outright (same as `simctl terminate`), so the next launch is cold.
            guard let bundleId = input.name.flatMap({ $0.isEmpty ? nil : $0 }) ?? config.defaultLogApp else {
                throw SimToolError("Terminate requires an app bundle id: start the server with --app or pass name")
            }
            let output = try await ProcessRunner.runXcrun(["simctl", "terminate", config.device.udid, bundleId])
            if output.status == 0 { appRelaunch.terminated(bundleId: bundleId) }
            return output
        case "launch", "relaunch":
            // Relaunches through simctl so the app inherits the server's SIMCTL_CHILD_*
            // environment and the state/network loggers re-arm; an icon-tap launch in the
            // Simulator loses that environment and those tabs go silent.
            guard let bundleId = input.name.flatMap({ $0.isEmpty ? nil : $0 }) ?? config.defaultLogApp else {
                throw SimToolError("Launch requires an app bundle id: start the server with --app or pass name")
            }
            // With the simulator's camera or network conditions on, the app is launched with them.
            let camera = SimToolLaunchEnvironment.forApp(deviceUDID: config.device.udid)
            let output = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["simctl", "launch", "--terminate-running-process", config.device.udid, bundleId],
                environment: camera.isEmpty ? nil : SimulatorAppLifecycleClient.simctlChildEnvironment(launchEnvironment: camera)
            )
            if output.status == 0 {
                appRelaunch.launched(AppLaunchRecord(bundleId: bundleId, pid: AppLaunchRecord.pid(fromLaunchOutput: output.stdoutString)))
            }
            return output
        case "software-keyboard":
            guard let visible = input.visible else {
                return try await SimulatorInputClient.toggleSoftwareKeyboard(deviceUDID: config.device.udid)
            }
            return try await SimulatorInputClient.setSoftwareKeyboard(visible: visible, deviceUDID: config.device.udid)
        case "hardware-keyboard":
            guard let connected = input.enabled else { throw SimToolError("Hardware keyboard input requires enabled: true or false") }
            return try await SimulatorInputClient.setHardwareKeyboard(connected: connected, deviceUDID: config.device.udid)
        case "button":
            guard let name = input.name else { throw SimToolError("Button input requires name") }
            if name.lowercased() == "home" {
                return try await ProcessRunner.runXcrun(["simctl", "launch", config.device.udid, "com.apple.springboard"])
            }
            if name.lowercased() == "app-switcher" {
                return try await SimulatorInputClient.openAppSwitcher(deviceUDID: config.device.udid)
            }
            return try await SimulatorInputClient.button(name, deviceUDID: config.device.udid)
        default:
            throw SimToolError("Unsupported input action: \(action.isEmpty ? "<missing>" : action)")
        }
    }

    private func ratio(_ value: Double, in size: Double) -> Double {
        return max(0, min(1, value / size))
    }

    /// A point in screen points. Coordinates come in points, or — with
    /// `coordinateSpace: "pixels"` and the source size, as an older viewer sends
    /// them — in pixels of the streamed frame.
    private func points(_ x: Double?, _ y: Double?, of input: SimulatorInputPayload) async throws -> TouchPoint? {
        guard let x, let y else { return nil }
        guard input.coordinateSpace?.lowercased() == "pixels" else { return TouchPoint(x: x, y: y) }
        guard let sourceWidth = input.sourceWidth, let sourceHeight = input.sourceHeight, sourceWidth > 0, sourceHeight > 0 else {
            throw SimToolError("Pixel coordinates require sourceWidth and sourceHeight")
        }
        let screen = try await SimulatorInputClient.screenSize(deviceUDID: config.device.udid)
        return TouchPoint(x: ratio(x, in: sourceWidth) * screen.width, y: ratio(y, in: sourceHeight) * screen.height)
    }

    private func wireEncoders() {
        h264Encoder.onEncoded = { [weak self] encoded in
            guard let self else { return }
            if let description = encoded.description {
                self.clientManager.broadcastAvcc(StreamFrame(kind: .description, envelope: AVCCEnvelope.description(avcc: description))) { sent in
                    self.metrics.recordAVCCDescription(sent: sent)
                }
            }
            // Hand the frame to the clients' queues before the next source frame
            // is encoded; each client keeps its own pace (ClientManager).
            self.stateLock.lock()
            self.h264Broadcasting = true
            let repeats = self.encodingRepeat
            self.stateLock.unlock()
            // A still screen's refresh is marked, so a viewer counts and reacts
            // to the frames that change it only. Marker and frame go as one.
            var envelope = repeats ? AVCCEnvelope.repeatsScreen() : Data()
            switch encoded.kind {
            case .keyframe: envelope.append(AVCCEnvelope.keyframe(avcc: encoded.avcc))
            case .delta: envelope.append(AVCCEnvelope.delta(avcc: encoded.avcc))
            }
            let kind = encoded.kind
            self.clientManager.broadcastAvcc(StreamFrame(kind: kind == .keyframe ? .keyframe : .delta, envelope: envelope)) { sent in
                self.metrics.recordH264Encoded(kind: kind, sent: sent)
                self.stateLock.lock(); self.h264Broadcasting = false; self.stateLock.unlock()
            }
        }
        clientManager.onAvccClientConnect = { [weak self] in
            self?.requestKeyframe()
        }
        // A viewer that fell behind skipped frames and caught up: it decodes
        // again from a keyframe.
        clientManager.onClientNeedsKeyframe = { [weak self] in
            self?.requestKeyframe()
        }
        clientManager.onSkip = { [weak self] id in
            guard let self else { return }
            self.metrics.recordSkippedForSlowClient()
            // Said once a minute per viewer: the frames go on being counted.
            let now = Date()
            let say = self.slowViewersLock.withLock {
                guard now.timeIntervalSince(self.slowViewersSaid[id] ?? .distantPast) > 60 else { return false }
                self.slowViewersSaid[id] = now
                return true
            }
            if say { DebugLog.info("stream", "viewer \(id) reads slower than the screen changes: it skips frames up to the next keyframe; the other viewers keep their rate") }
        }
        clientManager.onStall = { id in
            DebugLog.write("stream", "viewer \(id) stopped reading for \(Int(StreamClient.stallLimit)) s: its connection is closed, it reconnects once it reads again")
        }
    }

    private func requestKeyframe() {
        h264Queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.forceKeyframe = true
            self.stateLock.unlock()
        }
    }

    private func frameHandler(pixelBuffer: CVPixelBuffer, timestamp _: CMTime, changed: Bool) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        metrics.recordCapturedFrame()
        stateLock.lock()
        screenWidth = width
        screenHeight = height
        let hasAvcc = clientManager.hasAvccClients()
        stateLock.unlock()

        guard hasAvcc else { return }
        for stream in pacedLock.withLock({ Array(pacedStreams.values) }) {
            stream.offer(pixelBuffer, changed: changed)
        }
        guard clientManager.hasSharedClients() else { return }
        h264Queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            if self.h264Encoding || self.h264Broadcasting {
                self.stateLock.unlock()
                self.metrics.recordDroppedH264Frame()
                return
            }
            self.h264Encoding = true
            self.encodingRepeat = !changed
            let force = self.forceKeyframe
            self.forceKeyframe = false
            self.stateLock.unlock()
            self.h264Encoder.encode(pixelBuffer, forceKeyframe: force) {
                self.h264Queue.async {
                    self.stateLock.lock(); self.h264Encoding = false; self.stateLock.unlock()
                }
            }
        }
    }

    private func asyncJSONResponse<T: Encodable>(_ operation: @escaping @Sendable () async throws -> T) -> HttpResponse {
        do {
            return try jsonEncodedResponse(waitForAsync(operation))
        } catch {
            return errorResponse(error)
        }
    }

    private func waitForAsync<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }

    private struct StartRecordingBody: Decodable { var bezel: Bool? }

    private struct ProcessKillBody: Decodable { var confirm: Bool? }

    private func handleProcessKill(_ request: HttpRequest) -> HttpResponse {
        guard let raw = request.params[":pid"], let pid = Int32(raw), pid > 0 else {
            return errorResponse(SimToolError("A process is named by its PID."), statusCode: 400, reason: "Bad Request")
        }
        let confirm = request.body.isEmpty ? false : ((try? decodeJSON(ProcessKillBody.self, from: request))?.confirm ?? false)
        let processes = processes
        do {
            return try jsonEncodedResponse(ProcessKillPayload(outcomes: [try waitForAsync { try await processes.kill(pid: pid, confirmingOwnProcess: confirm) }]))
        } catch let refusal as SimToolProcessControl.Refusal {
            switch refusal {
            case .notSimTool: return errorResponse(refusal, statusCode: 403, reason: "Forbidden")
            case .ownProcess: return errorResponse(refusal, statusCode: 409, reason: "Conflict")
            }
        } catch {
            return errorResponse(error)
        }
    }

    /// Puts the device around a recording of `display`.
    static func bezelFramer(display: SimulatorDisplay?, rotation: Int = 0) -> ScreenRecordingController.Framer {
        { input, output in
            try await BezelVideo.frame(input: input, output: output) { pixels in bezel(for: display, pixels: pixels, rotation: rotation) }
        }
    }

    /// The bezel around a picture of `pixels` of `display` — the screen a
    /// screenshot or a recording shows, turned `rotation` degrees on its panel.
    /// The picture's own shape has the last word on a quarter turn: one with
    /// the panel's sides swapped is turned, whatever the last reading said.
    /// Without the device type read yet, a drawn frame at the phones' 3× scale.
    static func bezel(for display: SimulatorDisplay?, pixels: CGSize, rotation: Int = 0) -> DeviceBezel {
        let scale = display.map { CGFloat($0.scale) }.flatMap { $0 > 0 ? $0 : nil } ?? 3
        var degrees = SimulatorDisplayRotation.normalized(rotation)
        if let display, display.width != display.height, pixels.width != pixels.height {
            let sidesSwapped = (pixels.width > pixels.height) != (display.width > display.height)
            if sidesSwapped != SimulatorDisplayRotation.isQuarterTurn(degrees) { degrees = sidesSwapped ? 90 : 0 }
        }
        return DeviceBezel(
            screen: CGSize(width: pixels.width / scale, height: pixels.height / scale),
            cornerRadii: display?.cornerRadii(rotation: degrees),
            chrome: display?.chrome,
            rotation: degrees
        )
    }

    /// A screenshot with the device drawn around it.
    private func framedScreenshot(png: Data, display: SimulatorDisplay?) throws -> Data {
        guard let image = DeviceBezel.image(png: png) else { throw SimToolError("The screenshot is not a decodable image") }
        let shown = display ?? displays.shownDisplay
        let bezel = Self.bezel(for: shown, pixels: CGSize(width: image.width, height: image.height), rotation: displays.rotation(of: shown))
        guard let framed = bezel.compose(screenshot: image), let data = DeviceBezel.png(framed) else { throw SimToolError("Could not draw the device bezel") }
        return data
    }

    private func shutdownScreenRecordings() {
        let semaphore = DispatchSemaphore(value: 0)
        let controller = screenRecordings
        Task {
            await controller.shutdown()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(8))
    }

    private func shutdownTestSessions() {
        let semaphore = DispatchSemaphore(value: 0)
        let controller = testSessions
        Task {
            await controller.shutdown()
            semaphore.signal()
        }
        // Bounded: stop() can run from a signal handler; a hung recorder must
        // delay exit, not deadlock it.
        _ = semaphore.wait(timeout: .now() + .seconds(8))
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from request: HttpRequest) throws -> T {
        let data = Data(request.body)
        guard !data.isEmpty else { throw SimToolError("Request body must be JSON") }
        return try JSON.decoder.decode(type, from: data)
    }

    private func jsonEncodedResponse<T: Encodable>(_ value: T, statusCode: Int = 200, reason: String = "OK") throws -> HttpResponse {
        let data = try JSON.data(value, pretty: false)
        return dataResponse(data, contentType: "application/json", statusCode: statusCode, reason: reason)
    }

    private func jsonResponse(_ object: [String: Any], statusCode: Int = 200, reason: String = "OK") -> HttpResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return .internalServerError
        }
        return dataResponse(data, contentType: "application/json", statusCode: statusCode, reason: reason)
    }

    private func errorResponse(_ error: Error, statusCode: Int = 500, reason: String = "Internal Server Error") -> HttpResponse {
        // A failure of the server's own is SimTool's error; a request it
        // turned down is the caller's — said quietly.
        if statusCode >= 500 { DebugLog.error("api", "\(statusCode) \(reason): \(error.localizedDescription)") }
        else { DebugLog.write("api", "\(statusCode) \(reason): \(error.localizedDescription)") }
        return jsonResponse(["error": error.localizedDescription], statusCode: statusCode, reason: reason)
    }

    private func testSessionErrorResponse(_ error: Error) -> HttpResponse {
        switch error {
        case TestSessionError.alreadyActive, TestSessionError.noActiveSession, TestSessionError.videoNotReady,
             TestSessionError.sessionRunning:
            return errorResponse(error, statusCode: 409, reason: "Conflict")
        case TestSessionError.sessionNotFound, TestSessionError.videoMissing, TestSessionError.evidenceMissing:
            return errorResponse(error, statusCode: 404, reason: "Not Found")
        case TestSessionError.emptyEntry, TestSessionError.entryTooLarge, TestSessionError.badStatus,
             is DecodingError, is SimToolError:
            // Validation and decode failures are the client's fault.
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        default:
            // Anything else (store I/O) is a server-side failure.
            return errorResponse(error)
        }
    }

    private func videoFileResponse(_ url: URL, rangeHeader: String?) -> HttpResponse {
        guard let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue else {
            return errorResponse(SimToolError("Video file unreadable"), statusCode: 404, reason: "Not Found")
        }
        var headers = [
            "Content-Type": "video/mp4",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache, no-store",
        ]
        switch HTTPRange.parse(header: rangeHeader, fileSize: size) {
        case .unsatisfiable:
            headers["Content-Range"] = "bytes */\(size)"
            headers["Content-Length"] = "0"
            return .raw(416, "Range Not Satisfiable", headers, nil)
        case let .partial(range):
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return errorResponse(SimToolError("Video file unreadable"), statusCode: 404, reason: "Not Found")
            }
            headers["Content-Range"] = "bytes \(range.offset)-\(range.offset + range.length - 1)/\(size)"
            headers["Content-Length"] = "\(range.length)"
            return .raw(206, "Partial Content", headers) { writer in
                Self.streamFile(handle, offset: range.offset, length: range.length, to: writer)
            }
        case .full:
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return errorResponse(SimToolError("Video file unreadable"), statusCode: 404, reason: "Not Found")
            }
            headers["Content-Length"] = "\(size)"
            return .raw(200, "OK", headers) { writer in
                Self.streamFile(handle, offset: 0, length: size, to: writer)
            }
        }
    }

    /// Streams `length` bytes from `offset` in bounded chunks so a long
    /// recording never has to fit in memory. Closes the handle when done.
    private static func streamFile(_ handle: FileHandle, offset: Int, length: Int, to writer: HttpResponseBodyWriter) {
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return }
        var remaining = length
        let chunkSize = 1 << 20
        while remaining > 0 {
            guard let chunk = try? handle.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else { return }
            guard (try? writer.write(chunk)) != nil else { return }
            remaining -= chunk.count
        }
    }

    private func dataResponse(
        _ data: Data,
        contentType: String,
        statusCode: Int = 200,
        reason: String = "OK"
    ) -> HttpResponse {
        return .raw(statusCode, reason, [
            "Content-Type": contentType,
            "Cache-Control": "no-cache, no-store",
            "Content-Length": "\(data.count)",
        ]) { writer in
            try? writer.write(data)
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private extension HttpRequest {
    func queryValue(_ name: String) -> String? {
        queryParams.last { $0.0 == name }?.1
    }

    func queryInt(_ name: String) -> Int? {
        queryValue(name).flatMap(Int.init)
    }

    func queryFlag(_ name: String) -> Bool {
        guard let value = queryValue(name)?.lowercased() else { return false }
        return value.isEmpty || value == "1" || value == "true" || value == "yes"
    }

    func queryDouble(_ name: String) -> Double? {
        queryValue(name).flatMap(Double.init)
    }
}
