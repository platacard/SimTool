import Foundation
import SimToolCore
@testable import SimToolServer
import XCTest

// What a person does by hand in a viewer, as the activity feed tells it.
final class LiveInputActivityTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { time } }
        func advance(_ seconds: Double) { lock.withLock { time = time.addingTimeInterval(seconds) } }
    }

    private let screen = SimulatorScreenSize(width: 400, height: 800, scale: 3)

    private func make() -> (LiveInputActivity, DeviceActivityLog, Clock) {
        let clock = Clock()
        let log = DeviceActivityLog(now: { clock.now })
        return (LiveInputActivity(log: log, screen: screen, now: { clock.now }), log, clock)
    }

    private func touch(_ phase: TouchPhase, _ x: Double, _ y: Double, second: TouchRatio? = nil) -> LiveTouchEvent {
        LiveTouchEvent(phase: phase, first: TouchRatio(x: x, y: y), second: second)
    }

    func testAQuickStillTouchIsATapInPoints() throws {
        let (recorder, log, clock) = make()
        recorder.touch(touch(.down, 0.5, 0.25))
        clock.advance(0.08)
        recorder.touch(touch(.move, 0.501, 0.251))
        recorder.touch(touch(.up, 0.501, 0.251))
        let entry = try XCTUnwrap(log.query(since: nil).entries.last)
        XCTAssertEqual(entry.actor, .viewer)
        XCTAssertEqual(entry.via, "viewer")
        XCTAssertEqual(entry.kind, "tap")
        XCTAssertEqual(entry.title, "Tap 200, 200")
        XCTAssertEqual(entry.status, .done)
        XCTAssertEqual(entry.gesture?.from, TouchPoint(x: 200, y: 200))
        XCTAssertEqual(entry.gesture?.to, TouchPoint(x: 200, y: 200), "a tap lifts where it went down")
        XCTAssertEqual(try XCTUnwrap(entry.gesture?.duration), 0.08, accuracy: 0.001)
        XCTAssertEqual(entry.endedAt?.timeIntervalSince(entry.at) ?? 0, 0.08, accuracy: 0.001, "the entry spans the touch")
    }

    func testAStillTouchHeldHalfASecondIsALongPress() throws {
        let (recorder, log, clock) = make()
        recorder.touch(touch(.down, 0.25, 0.5))
        clock.advance(0.7)
        recorder.touch(touch(.up, 0.25, 0.5))
        let entry = try XCTUnwrap(log.query(since: nil).entries.last)
        XCTAssertEqual(entry.kind, "long-press")
        XCTAssertEqual(entry.title, "Long press 100, 400")
        XCTAssertEqual(entry.detail, "held 0.7 s")
    }

    func testAQuickMoveIsASwipeAndARestedOneADrag() throws {
        let (recorder, log, clock) = make()
        recorder.touch(touch(.down, 0.5, 0.75))
        clock.advance(0.05)
        recorder.touch(touch(.move, 0.5, 0.5))
        clock.advance(0.1)
        recorder.touch(touch(.up, 0.5, 0.25))
        var entry = try XCTUnwrap(log.query(since: nil).entries.last)
        XCTAssertEqual(entry.kind, "swipe")
        XCTAssertEqual(entry.title, "Swipe up")
        XCTAssertEqual(entry.detail, "200, 600 → 200, 200")
        XCTAssertEqual(entry.gesture?.to, TouchPoint(x: 200, y: 200))

        recorder.touch(touch(.down, 0.2, 0.5))
        clock.advance(0.6)
        recorder.touch(touch(.move, 0.4, 0.5))
        clock.advance(0.3)
        recorder.touch(touch(.up, 0.8, 0.5))
        entry = try XCTUnwrap(log.query(since: nil).entries.last)
        XCTAssertEqual(entry.kind, "drag")
        XCTAssertEqual(entry.title, "Drag right")
        XCTAssertEqual(try XCTUnwrap(entry.gesture?.press), 0.6, accuracy: 0.001, "it rested before it moved")
    }

    func testTwoFingersSpreadingArePinchOut() throws {
        let (recorder, log, clock) = make()
        recorder.touch(touch(.down, 0.45, 0.45, second: TouchRatio(x: 0.55, y: 0.55)))
        clock.advance(0.3)
        recorder.touch(touch(.up, 0.3, 0.3, second: TouchRatio(x: 0.7, y: 0.7)))
        XCTAssertEqual(log.query(since: nil).entries.last?.title, "Pinch out")
    }

    func testAnUpWithoutADownRecordsNothing() {
        let (recorder, log, _) = make()
        recorder.touch(touch(.up, 0.5, 0.5))
        XCTAssertTrue(log.query(since: nil).entries.isEmpty)
    }

    func testABurstOfKeysIsOneTypeEntryThatGrows() throws {
        let (recorder, log, clock) = make()
        func press(_ code: String, _ character: String?) {
            let key = KeyboardKey(webCode: code)!
            recorder.key(LiveKeyEvent(key: key, isDown: true), character: character)
            recorder.key(LiveKeyEvent(key: key, isDown: false), character: nil)
            clock.advance(0.2)
        }
        press("ShiftLeft", nil)
        press("KeyH", "H")
        press("KeyI", "i")
        press("KeyX", "x")
        press("Backspace", nil)
        press("Enter", nil)
        var entries = log.query(since: nil).entries
        XCTAssertEqual(entries.count, 1, "one burst, one entry")
        XCTAssertEqual(entries.last?.kind, "type")
        XCTAssertEqual(entries.last?.actor, .viewer)
        XCTAssertEqual(entries.last?.title, "Type “Hi⏎”", "a backspace takes back what the burst typed")
        XCTAssertEqual(entries.last?.detail, "5 keys")

        clock.advance(3)
        press("KeyA", nil)
        entries = log.query(since: nil).entries
        XCTAssertEqual(entries.count, 2, "a pause starts another burst")
        XCTAssertEqual(entries.last?.title, "Type “a”", "without the viewer's character, the US layout's")
    }

    func testACommandChordIsNamedAsOne() throws {
        let (recorder, log, _) = make()
        recorder.key(LiveKeyEvent(key: KeyboardKey(webCode: "MetaLeft")!, isDown: true), character: nil)
        recorder.key(LiveKeyEvent(key: KeyboardKey(webCode: "KeyA")!, isDown: true), character: "a")
        XCTAssertEqual(log.query(since: nil).entries.last?.title, "Type “⌘A”")
    }

    func testWithoutAScreenATouchIsToldInFractions() throws {
        let log = DeviceActivityLog()
        let recorder = LiveInputActivity(log: log)
        recorder.touch(touch(.down, 0.5, 0.25))
        recorder.touch(touch(.up, 0.5, 0.25))
        let entry = try XCTUnwrap(log.query(since: nil).entries.last)
        XCTAssertEqual(entry.title, "Tap 50%, 25%")
        XCTAssertNil(entry.gesture, "nothing to draw it in")
    }

    func testTheChannelHandsTheTypedCharacterToItsObserver() {
        final class Heard: @unchecked Sendable {
            let lock = NSLock()
            var characters: [String?] = []
        }
        let heard = Heard()
        let channel = LiveInputChannel(emit: { _ in }, observe: { event, character in
            if case .key = event { heard.lock.withLock { heard.characters.append(character) } }
        })
        channel.receive(#"{"t":"keydown","code":"KeyQ","k":"q"}"#)
        channel.receive(#"{"t":"keyup","code":"KeyQ"}"#)
        channel.receive(#"{"t":"keydown","code":"Enter","k":"Enter"}"#)
        XCTAssertEqual(heard.lock.withLock { heard.characters }, ["q", nil, nil], "one character or none")
    }
}
