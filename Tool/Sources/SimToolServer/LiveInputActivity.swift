import Foundation
import SimToolCore

/// What a person does to the device by hand in a viewer — the live finger and
/// the keys streamed over `/api/v1/input/stream` — as entries in the activity
/// feed, beside what agents and tests do. The stream carries raw downs, moves
/// and ups; this turns each gesture into one entry once the finger lifts (a
/// tap, a long press, a swipe or a drag, a two-finger gesture) and a burst of
/// typing into one `Type “…”` that grows while the keys keep coming.
///
/// One per viewer connection: its finger and its keys are its own.
final class LiveInputActivity: @unchecked Sendable {
    /// Points the finger may wander and still be a tap or a long press.
    static let slop = 10.0
    /// UIKit's long-press delay: a still finger held this long is a long press.
    static let longPress = 0.5
    /// A finger that rested this long before moving drags what it holds; a
    /// quicker one swipes.
    static let dragRest = 0.3
    /// Keys this close together are one burst of typing.
    static let typingGap = 2.0
    /// The longest typed text an entry shows; the rest is counted.
    static let typedExcerpt = 60

    private struct Finger {
        var down: LiveTouchEvent
        var downAt: Date
        var last: LiveTouchEvent
        /// When it first left the slop, if it did.
        var movedAt: Date?
        var twoFingers: Bool
        var firstSecond: TouchRatio?
    }

    private struct Typing {
        var entryId: Int
        var text: String
        var keys: Int
        var lastAt: Date
    }

    private let lock = NSLock()
    private let log: DeviceActivityLog
    private let now: @Sendable () -> Date
    private var screen: SimulatorScreenSize?
    private var finger: Finger?
    private var typing: Typing?
    private var modifiers: Set<UInt32> = []

    init(log: DeviceActivityLog, screen: SimulatorScreenSize? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.log = log
        self.screen = screen
        self.now = now
    }

    /// The screen in points, as the device has it now: a gesture is measured
    /// and drawn in it. Until it is known, a gesture is told in fractions.
    func setScreen(_ screen: SimulatorScreenSize?) {
        guard let screen else { return }
        lock.withLock { self.screen = screen }
    }

    // MARK: - the finger

    func touch(_ event: LiveTouchEvent) {
        let at = now()
        let finished: (Finger, LiveTouchEvent, SimulatorScreenSize?)? = lock.withLock {
            switch event.phase {
            case .down:
                finger = Finger(down: event, downAt: at, last: event, movedAt: nil, twoFingers: event.second != nil, firstSecond: event.second)
                return nil
            case .move:
                guard var current = finger else { return nil }
                current.last = event
                if event.second != nil {
                    current.twoFingers = true
                    if current.firstSecond == nil { current.firstSecond = event.second }
                }
                if current.movedAt == nil, Self.distance(current.down.first, event.first, screen: screen) > Self.slop {
                    current.movedAt = at
                }
                finger = current
                return nil
            case .up:
                guard let current = finger else { return nil }
                finger = nil
                return (current, event, screen)
            }
        }
        guard let (gesture, up, screen) = finished else { return }
        record(gesture, up: up, screen: screen, endedAt: at)
    }

    private func record(_ gesture: Finger, up: LiveTouchEvent, screen: SimulatorScreenSize?, endedAt: Date) {
        let duration = max(0, endedAt.timeIntervalSince(gesture.downAt))
        let from = Self.point(gesture.down.first, screen: screen)
        let to = Self.point(up.first, screen: screen)
        let moved = gesture.movedAt != nil || Self.distance(gesture.down.first, up.first, screen: screen) > Self.slop
        let rest = gesture.movedAt.map { max(0, $0.timeIntervalSince(gesture.downAt)) } ?? duration
        let words: (kind: String, title: String, detail: String?)
        if gesture.twoFingers {
            words = Self.twoFingerWords(gesture, up: up, screen: screen)
        } else if !moved {
            let held = duration >= Self.longPress
            words = held
                ? ("long-press", "Long press " + Self.describe(from, screen: screen), "held " + Self.seconds(duration))
                : ("tap", "Tap " + Self.describe(from, screen: screen), nil)
        } else {
            let verb = rest >= Self.dragRest ? "Drag" : "Swipe"
            let direction = Self.direction(from: from, to: to)
            words = (verb.lowercased(), verb + (direction.map { " " + $0 } ?? ""), Self.describe(from, screen: screen) + " → " + Self.describe(to, screen: screen))
        }
        let gestureRecord = screen.map { screen in
            DeviceActivityGesture(from: from, to: moved ? to : from, press: min(rest, duration), duration: duration, screen: screen)
        }
        let entry = log.begin(actor: .viewer, via: "viewer", kind: words.kind, title: words.title, detail: words.detail, gesture: gestureRecord, at: gesture.downAt)
        log.update(id: entry.id) {
            $0.endedAt = endedAt
            $0.status = .done
        }
    }

    private static func twoFingerWords(_ gesture: Finger, up: LiveTouchEvent, screen: SimulatorScreenSize?) -> (kind: String, title: String, detail: String?) {
        guard let startSecond = gesture.firstSecond ?? gesture.down.second, let endSecond = up.second ?? gesture.last.second else {
            return ("pinch", "Two-finger gesture", nil)
        }
        let spreadBefore = distance(gesture.down.first, startSecond, screen: screen)
        let spreadAfter = distance(up.first, endSecond, screen: screen)
        if spreadAfter - spreadBefore > slop { return ("pinch", "Pinch out", nil) }
        if spreadBefore - spreadAfter > slop { return ("pinch", "Pinch in", nil) }
        let direction = Self.direction(from: point(gesture.down.first, screen: screen), to: point(up.first, screen: screen))
        return ("pinch", "Two-finger drag" + (direction.map { " " + $0 } ?? ""), nil)
    }

    // MARK: - the keys

    /// `character` is what the viewer's keyboard typed with the key, when it
    /// typed one: the device's own layout decides what lands, the feed shows
    /// what the person pressed.
    func key(_ event: LiveKeyEvent, character: String?) {
        let at = now()
        let usage = event.key.usage
        if Self.modifierUsages.contains(usage) {
            lock.withLock {
                if event.isDown { modifiers.insert(usage) } else { modifiers.remove(usage) }
            }
            return
        }
        guard event.isDown else { return }
        lock.withLock {
            let command = !modifiers.isDisjoint(with: Self.commandUsages)
            let control = !modifiers.isDisjoint(with: Self.controlUsages)
            var burst = typing.flatMap { at.timeIntervalSince($0.lastAt) <= Self.typingGap ? $0 : nil }
            var text = burst?.text ?? ""
            if usage == Self.backspace, !command, !control, let last = text.last, !Self.tokens.contains(last) {
                text.removeLast()
            } else {
                text += Self.token(usage: usage, character: character, command: command, control: control)
            }
            let keys = (burst?.keys ?? 0) + 1
            let title = "Type " + Self.quoted(text)
            let detail = keys == 1 ? nil : "\(keys) keys"
            if let open = burst, log.update(id: open.entryId, {
                $0.title = title
                $0.detail = detail
                $0.endedAt = at
            }) != nil {
                burst?.text = text
                burst?.keys = keys
                burst?.lastAt = at
                typing = burst
                return
            }
            let entry = log.record(actor: .viewer, via: "viewer", kind: "type", title: title, detail: detail, at: at)
            burst = Typing(entryId: entry.id, text: text, keys: keys, lastAt: at)
            typing = burst
        }
    }

    // MARK: - words

    static let backspace: UInt32 = 0x2A
    static let modifierUsages: Set<UInt32> = [0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7]
    static let commandUsages: Set<UInt32> = [0xE3, 0xE7]
    static let controlUsages: Set<UInt32> = [0xE0, 0xE4]
    /// The marks keys without a character leave in the text.
    static let named: [UInt32: String] = [
        0x28: "⏎", 0x58: "⏎", 0x29: "⎋", 0x2A: "⌫", 0x2B: "⇥", 0x2C: " ", 0x4C: "⌦",
        0x4F: "→", 0x50: "←", 0x51: "↓", 0x52: "↑", 0x4A: "↖", 0x4D: "↘", 0x4B: "⇞", 0x4E: "⇟",
    ]
    static let tokens: Set<Character> = Set(named.values.filter { $0 != " " }.compactMap(\.first)).union(["⌘", "⌃"])

    static func token(usage: UInt32, character: String?, command: Bool, control: Bool) -> String {
        let base: String
        if let character, character.count == 1, !(command || control), named[usage] == nil {
            base = character
        } else if let mark = named[usage] {
            base = mark
        } else {
            base = character.flatMap { $0.count == 1 ? $0 : nil } ?? usLayout[usage] ?? "?"
        }
        if command { return "⌘" + base.uppercased() }
        if control { return "⌃" + base.uppercased() }
        return base
    }

    /// What a key types on a US keyboard, unshifted — for a viewer that sent
    /// no character with it.
    static let usLayout: [UInt32: String] = {
        var map: [UInt32: String] = [:]
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { map[0x04 + UInt32(offset)] = String(letter) }
        for (offset, digit) in "1234567890".enumerated() { map[0x1E + UInt32(offset)] = String(digit) }
        let rest: [UInt32: String] = [0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\", 0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/"]
        map.merge(rest) { current, _ in current }
        return map
    }()

    static func quoted(_ text: String) -> String {
        let shown = text.count > typedExcerpt ? String(text.prefix(typedExcerpt)) + "…" : text
        return "“" + shown + "”"
    }

    static func point(_ ratio: TouchRatio, screen: SimulatorScreenSize?) -> TouchPoint {
        guard let screen else { return TouchPoint(x: ratio.x, y: ratio.y) }
        return TouchPoint(x: ratio.x * screen.width, y: ratio.y * screen.height)
    }

    /// In points when the screen is known; else in thousandths of the screen,
    /// which the slop then reads as points of a 1000-point screen.
    static func distance(_ a: TouchRatio, _ b: TouchRatio, screen: SimulatorScreenSize?) -> Double {
        let width = screen?.width ?? 1000, height = screen?.height ?? 1000
        return hypot((a.x - b.x) * width, (a.y - b.y) * height)
    }

    /// Points as `simtool input` names them; with no screen known, the
    /// fractions read as percentages of it.
    static func describe(_ point: TouchPoint, screen: SimulatorScreenSize?) -> String {
        guard screen != nil else { return "\(Int((point.x * 100).rounded()))%, \(Int((point.y * 100).rounded()))%" }
        return "\(Int(point.x.rounded())), \(Int(point.y.rounded()))"
    }

    /// The way the finger went, by its larger travel: up, down, left, right.
    static func direction(from: TouchPoint, to: TouchPoint) -> String? {
        let dx = to.x - from.x, dy = to.y - from.y
        guard dx != 0 || dy != 0 else { return nil }
        return abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
    }

    static func seconds(_ value: Double) -> String {
        String(format: value < 10 ? "%.1f s" : "%.0f s", value)
    }
}
