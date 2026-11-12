import Foundation
import SimToolCore

/// What a viewer's live input channel streams to the helper.
enum LiveInputEvent: Equatable, Sendable {
    case touch(LiveTouchEvent)
    case key(LiveKeyEvent)
}

/// One viewer's live input connection: its finger and, while it types on the
/// device, its keys. It turns the viewer's messages into helper events in
/// arrival order and remembers what is held, so a viewer that vanishes
/// (closed tab, dropped socket) never leaves a finger pressed or a key down on
/// the device.
///
/// Messages are JSON objects. Touches carry fractions of the screen:
/// `{"t": "down" | "move" | "up", "x": 0.5, "y": 0.7}`, plus `x2`/`y2` for a
/// second finger and, on a foldable, `d` — the panel shown (`primary-1`).
/// Keys carry the browser's physical key name:
/// `{"t": "keydown" | "keyup", "code": "KeyA"}`, and a keydown the character
/// the viewer's keyboard typed with it, when it typed one (`"k": "a"`) — only
/// for the activity feed: the device's own layout decides what lands.
///
/// Several viewers may be open — on this Mac and across the network — and
/// one finger at a time reaches the device (`TouchArbiter`): a gesture that
/// starts while another viewer's finger is down is dropped, and its viewer
/// hears `{"t": "busy"}`. `{"t": "ping", "id": 7}` is answered with
/// `{"t": "pong", "id": 7}`, which is how a viewer times its round trip.
///
/// The channel also carries what the viewer's video stream needs to keep
/// pace with its link (`PacedStream`): `{"t": "got", "s": "<stream>", "b":
/// 123456}` — the bytes of that stream received so far — answered, when the
/// stream's pace changes, with `{"t": "pace", "s": …, "kbps": 1200, "px":
/// 960, "fps": 24, "full": false}`.
final class LiveInputChannel: @unchecked Sendable {
    private struct Message: Decodable {
        var t: String
        var id: Int?
        var x: Double?
        var y: Double?
        var x2: Double?
        var y2: Double?
        var d: String?
        var code: String?
        var k: String?
        var s: String?
        var b: Int?
    }

    private let lock = NSLock()
    private let emit: @Sendable (LiveInputEvent) -> Void
    private let onDown: @Sendable () -> Void
    private let observe: @Sendable (LiveInputEvent, _ character: String?) -> Void
    private let reply: @Sendable (String) -> Void
    private let received: @Sendable (_ stream: String, _ total: Int) -> String?
    private let arbiter: TouchArbiter?
    private var lastDown: LiveTouchEvent?
    private var heldKeys: [KeyboardKey] = []
    private var closed = false

    /// `emit` receives the events in order; `onDown` runs at the start of each
    /// gesture and key press (a test session anchors its step there);
    /// `observe` hears every event `emit` got, with the character a key typed
    /// in the viewer, in the same order — the activity feed reads it.
    /// `reply` writes a text frame back to the viewer; `arbiter` decides
    /// whose finger reaches the device when several viewers are open.
    init(
        emit: @escaping @Sendable (LiveInputEvent) -> Void,
        onDown: @escaping @Sendable () -> Void = {},
        observe: @escaping @Sendable (LiveInputEvent, _ character: String?) -> Void = { _, _ in },
        reply: @escaping @Sendable (String) -> Void = { _ in },
        received: @escaping @Sendable (_ stream: String, _ total: Int) -> String? = { _, _ in nil },
        arbiter: TouchArbiter? = nil
    ) {
        self.emit = emit
        self.onDown = onDown
        self.observe = observe
        self.reply = reply
        self.received = received
        self.arbiter = arbiter
    }

    private func send(_ event: LiveInputEvent, character: String? = nil) {
        emit(event)
        observe(event, character)
    }

    var isTouching: Bool {
        lock.withLock { lastDown != nil }
    }

    /// Handles one text frame. Malformed frames are dropped: live input cannot
    /// wait for an error reply, and the next frame carries the state on.
    func receive(_ text: String) {
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) else { return }
        let started: Bool
        switch message.t {
        case "ping":
            reply(#"{"t":"pong","id":\#(message.id ?? 0)}"#)
            return
        case "got":
            guard let stream = message.s, let total = message.b, total >= 0 else { return }
            if let answer = received(stream, total) { reply(answer) }
            return
        case "keydown", "keyup":
            guard let code = message.code, let key = KeyboardKey(webCode: code) else { return }
            started = receiveKey(key, isDown: message.t == "keydown", character: message.k)
        default:
            guard let phase = TouchPhase(rawValue: message.t),
                  let x = message.x, let y = message.y, x.isFinite, y.isFinite else { return }
            let second: TouchRatio? = if let x2 = message.x2, let y2 = message.y2, x2.isFinite, y2.isFinite {
                TouchRatio(x: x2, y: y2)
            } else {
                nil
            }
            started = receiveTouch(LiveTouchEvent(phase: phase, first: TouchRatio(x: x, y: y), second: second, display: message.d))
        }
        if started { onDown() }
    }

    /// The viewer is gone: lift any finger it left down, where it last was,
    /// and release its keys, the last pressed first.
    func disconnect() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            if let last = lastDown {
                // A finger another viewer took the device from is no longer on it.
                if arbiter?.holds(ObjectIdentifier(self)) ?? true {
                    send(.touch(LiveTouchEvent(phase: .up, first: last.first, second: last.second, display: last.display)))
                }
                lastDown = nil
                arbiter?.release(ObjectIdentifier(self))
            }
            for key in heldKeys.reversed() {
                send(.key(LiveKeyEvent(key: key, isDown: false)))
            }
            heldKeys.removeAll()
        }
    }

    private func receiveTouch(_ event: LiveTouchEvent) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            let me = ObjectIdentifier(self)
            switch event.phase {
            case .down:
                if let arbiter, !arbiter.claim(me) {
                    lastDown = nil
                    reply(#"{"t":"busy"}"#)
                    return false
                }
                lastDown = event
            case .move:
                guard lastDown != nil else { return false }
                // Held still too long, the device went to another viewer: this
                // gesture is over, and it does not move their finger.
                if let arbiter, !arbiter.holds(me) {
                    lastDown = nil
                    return false
                }
                lastDown = event
                arbiter?.touched(me)
            case .up:
                guard lastDown != nil else { return false }
                lastDown = nil
                if let arbiter, !arbiter.holds(me) { return false }
                arbiter?.release(me)
            }
            send(.touch(event))
            return event.phase == .down
        }
    }

    /// A key goes down once and up once: a repeated down or an up for a key
    /// this viewer never pressed is dropped.
    private func receiveKey(_ key: KeyboardKey, isDown: Bool, character: String?) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if isDown {
                guard !heldKeys.contains(key) else { return false }
                heldKeys.append(key)
            } else {
                guard let index = heldKeys.firstIndex(of: key) else { return false }
                heldKeys.remove(at: index)
            }
            send(.key(LiveKeyEvent(key: key, isDown: isDown)), character: isDown ? character.flatMap { $0.count == 1 ? $0 : nil } : nil)
            return isDown
        }
    }
}

/// Whose finger is on the device. Every viewer may watch and touch, but two
/// gestures at once would reach the device as one finger jumping between
/// them: a gesture that starts while another viewer's finger is down is
/// dropped. The finger lifted — or its viewer gone, or silent for
/// `abandonedAfter` (a socket that died without closing) — the next gesture
/// from anyone goes through. Keys are not arbitrated: two people typing at
/// once is rare, and each key lands whole.
final class TouchArbiter: @unchecked Sendable {
    static let abandonedAfter: TimeInterval = 5

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var holder: ObjectIdentifier?
    private var lastHeard = Date.distantPast

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Whether `viewer` may put its finger down now; if so it holds the device.
    func claim(_ viewer: ObjectIdentifier) -> Bool {
        lock.withLock {
            let at = now()
            if let holder, holder != viewer, at.timeIntervalSince(lastHeard) < Self.abandonedAfter { return false }
            holder = viewer
            lastHeard = at
            return true
        }
    }

    /// Whether `viewer`'s finger is the one on the device.
    func holds(_ viewer: ObjectIdentifier) -> Bool {
        lock.withLock { holder == viewer }
    }

    /// The holder's finger moved: it is still there.
    func touched(_ viewer: ObjectIdentifier) {
        lock.withLock { if holder == viewer { lastHeard = now() } }
    }

    func release(_ viewer: ObjectIdentifier) {
        lock.withLock { if holder == viewer { holder = nil } }
    }
}
