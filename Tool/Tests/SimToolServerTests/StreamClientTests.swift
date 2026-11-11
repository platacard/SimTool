import Foundation
import SimToolStream
@testable import SimToolServer
import XCTest

// Every viewer's video connection keeps its own pace: one that reads slowly
// or stops reading skips frames — never the others'.
final class StreamClientTests: XCTestCase {
    private func frame(_ kind: StreamFrame.Kind, _ byte: UInt8) -> StreamFrame {
        StreamFrame(kind: kind, envelope: Data([byte]))
    }

    /// A writer that blocks until released, recording what it wrote.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let open = DispatchSemaphore(value: 0)
        private var _written: [UInt8] = []
        var written: [UInt8] { lock.withLock { _written } }
        func write(_ data: Data) -> Bool {
            open.wait()
            lock.withLock { _written.append(contentsOf: data) }
            return true
        }
        func release(_ count: Int) { for _ in 0..<count { open.signal() } }
    }

    private func settle(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { usleep(5_000) }
    }

    func testANewClientStartsFromAKeyframe() {
        let client = StreamClient(id: 1)
        var written: [UInt8] = []
        let lock = NSLock()
        client.setWriter { data in lock.withLock { written.append(contentsOf: data) }; return true }
        XCTAssertEqual(client.send(frame(.description, 1)), .queued)
        XCTAssertEqual(client.send(frame(.delta, 2)), .skipped, "a delta before any keyframe cannot be decoded")
        XCTAssertEqual(client.send(frame(.keyframe, 3)), .queued)
        XCTAssertEqual(client.send(frame(.delta, 4)), .queued)
        settle(lock.withLock { written.count } == 3)
        XCTAssertEqual(lock.withLock { written }, [1, 3, 4])
    }

    func testAClientThatFallsBehindSkipsToTheNextKeyframeAndAsksForOne() {
        let client = StreamClient(id: 1)
        let gate = Gate()
        let asked = expectation(description: "it asks for a keyframe once caught up")
        client.onNeedsKeyframe = { asked.fulfill() }
        var skips = 0
        client.onSkip = { skips += 1 }
        client.setWriter(gate.write)
        XCTAssertEqual(client.send(frame(.keyframe, 1)), .queued)
        XCTAssertEqual(client.send(frame(.delta, 2)), .queued)
        XCTAssertEqual(client.send(frame(.delta, 3)), .queued)
        XCTAssertEqual(client.send(frame(.delta, 4)), .skipped, "three in hand: no room for a fourth")
        XCTAssertEqual(skips, 1)
        gate.release(3)
        settle(gate.written.count == 3)
        XCTAssertEqual(client.send(frame(.delta, 5)), .skipped, "after a gap, deltas would decode into garbage")
        wait(for: [asked], timeout: 2)
        XCTAssertEqual(skips, 1, "only frames it had no room for count as slow")
        XCTAssertEqual(client.send(frame(.keyframe, 6)), .queued)
        XCTAssertEqual(client.send(frame(.delta, 7)), .queued)
        gate.release(2)
        settle(gate.written.count == 5)
        XCTAssertEqual(gate.written, [1, 2, 3, 6, 7])
    }

    func testOneClientThatStoppedReadingDoesNotHoldBackAnother() {
        let manager = ClientManager()
        let stuck = manager.addAvccClient()
        let gate = Gate()
        stuck.setWriter(gate.write)
        let fast = manager.addAvccClient()
        let lock = NSLock()
        var received: [UInt8] = []
        fast.setWriter { data in lock.withLock { received.append(contentsOf: data) }; return true }
        settle(manager.clientCounts().avcc == 2)
        // A frame every few milliseconds, as the screen sends them (16 ms at 60 fps).
        manager.broadcastAvcc(frame(.keyframe, 0))
        for byte in UInt8(1)...UInt8(60) {
            usleep(3_000)
            manager.broadcastAvcc(frame(.delta, byte))
        }
        settle(lock.withLock { received.count } == 61)
        XCTAssertEqual(lock.withLock { received.count }, 61, "every frame reaches the client that reads")
        XCTAssertEqual(manager.clientCounts().avcc, 2, "the counts answer while a client is stuck")
        gate.release(100)
    }

    func testAClientStuckInAWriteForTooLongIsLetGo() {
        let client = StreamClient(id: 9)
        let gate = Gate()
        let ended = expectation(description: "its response ends")
        var stalled: Int?
        client.onStall = { stalled = $0 }
        client.setWriter(gate.write, onClose: { ended.fulfill() })
        XCTAssertEqual(client.send(frame(.keyframe, 1)), .queued)
        settle(false, timeout: 0.1)
        XCTAssertEqual(client.send(frame(.delta, 2), now: Date().addingTimeInterval(StreamClient.stallLimit + 1)), .closed)
        wait(for: [ended], timeout: 1)
        XCTAssertEqual(stalled, 9)
        XCTAssertEqual(client.send(frame(.keyframe, 3)), .closed)
        gate.release(5)
    }

    // The idle refresh of a still screen is marked by an envelope of its own,
    // which an older viewer skips while it decodes the frame after it.
    func testARepeatOfTheScreenIsMarkedAheadOfItsFrame() {
        var reader = AVCCEnvelopeReader()
        let envelopes = reader.push(AVCCEnvelope.repeatsScreen() + AVCCEnvelope.delta(avcc: Data([9, 9])))
        XCTAssertEqual(envelopes.map(\.tag), [AVCCEnvelope.repeatTag, AVCCEnvelope.deltaTag])
        XCTAssertEqual(envelopes[0].payload, Data())
        XCTAssertEqual(AVCCEnvelope.repeatTag, 0x05)
    }
}
