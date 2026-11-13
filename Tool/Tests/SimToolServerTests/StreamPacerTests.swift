import SimToolCore
@testable import SimToolServer
import XCTest

final class StreamPacerTests: XCTestCase {
    /// A link with one bottleneck: bytes queue for it, cross it at
    /// `capacity` — which may change while they wait — and reach the viewer
    /// `oneWay` later, as they cross; the viewer's word comes back as late.
    private struct Link {
        var capacity: Double
        var oneWay: TimeInterval
        /// Frames waiting for the bottleneck: bytes left, and when each went.
        var queue: [(left: Double, sentAt: TimeInterval)] = []
        var crossed = 0.0
        var arrivals: [(at: TimeInterval, total: Int)] = []
        /// Each frame's trip, by when it went, once its last byte arrived.
        var trips: [(sentAt: TimeInterval, trip: TimeInterval)] = []

        mutating func send(_ bytes: Int, at now: TimeInterval) {
            queue.append((Double(bytes), now))
        }

        mutating func carry(for step: TimeInterval, at now: TimeInterval) {
            var budget = capacity * step
            while budget > 0, !queue.isEmpty {
                let take = min(budget, queue[0].left)
                queue[0].left -= take
                budget -= take
                crossed += take
                if queue[0].left <= 0 {
                    trips.append((queue[0].sentAt, now + oneWay - queue[0].sentAt))
                    queue.removeFirst()
                }
            }
            arrivals.append((now + oneWay, Int(crossed)))
        }
    }

    private struct Run {
        var latencies: [(at: TimeInterval, latency: TimeInterval)] = []
        var frames: [TimeInterval] = []
        var full: [(at: TimeInterval, full: Bool)] = []

        func latencies(after start: TimeInterval) -> [TimeInterval] {
            latencies.filter { $0.at >= start }.map(\.latency).sorted()
        }

        func p90(after start: TimeInterval) -> TimeInterval {
            let sorted = latencies(after: start)
            return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count) * 0.9)]
        }

        func fps(from start: TimeInterval, to end: TimeInterval) -> Double {
            Double(frames.filter { $0 >= start && $0 < end }.count) / (end - start)
        }

        func linkFull(at time: TimeInterval) -> Bool {
            full.last { $0.at <= time }?.full ?? false
        }
    }

    /// A screen streamed for `seconds` through `link` at `settings`: while
    /// `moving` (a list being dragged) a frame for every screen the device
    /// makes, sixty a second, each as big as the bitrate makes it times
    /// `content` — simple content takes less than the encoder may use —
    /// otherwise the still screen's small refresh five times a second; the
    /// first frame a keyframe; the viewer telling what it got every 25 ms
    /// unless `silent`.
    private func stream(
        through initial: Link,
        seconds: TimeInterval,
        settings: StreamSettings = .standard,
        silent: @escaping (TimeInterval) -> Bool = { _ in false },
        content: Double = 1,
        moving: @escaping (TimeInterval) -> Bool = { _ in true },
        change: ((TimeInterval, inout Link) -> Void)? = nil
    ) -> (Run, StreamPacer) {
        var link = initial
        var pacer = StreamPacer(settings: settings, now: 0)
        var run = Run()
        var reports: [(at: TimeInterval, total: Int)] = []
        var received = 0
        var lastReport = -1.0
        var lastFrame: TimeInterval?
        let step = 0.001
        var now = 0.0
        while now < seconds {
            change?(now, &link)
            while let report = reports.first, report.at <= now {
                reports.removeFirst()
                pacer.received(total: report.total, at: now)
            }
            let still = !moving(now)
            let due = !still || now - (lastFrame ?? -1) >= 0.2
            let next = due ? pacer.nextEncode(at: now) : now + 1
            if due, next == nil, now - (lastFrame ?? -1) >= pacer.frameInterval { pacer.heldBack(at: now) }
            if let next, next <= now {
                pacer.encoded(at: now)
                // The encoder's clock moves at most two frames between
                // frames (PacedStream): a frame after a wait is no bigger.
                let elapsed = min(2 * pacer.frameInterval, now - (lastFrame ?? (now - pacer.frameInterval)))
                var bytes = still ? 400 : max(400, Int(Double(pacer.settings.bitrate) / 8 * elapsed * content))
                if lastFrame == nil { bytes = bytes * 3 + 20_000 }
                lastFrame = now
                pacer.sent(bytes: bytes, at: now)
                link.send(bytes, at: now)
                run.frames.append(now)
            }
            link.carry(for: step, at: now)
            while let arrival = link.arrivals.first, arrival.at <= now {
                link.arrivals.removeFirst()
                received = arrival.total
            }
            if !silent(now), now - lastReport >= 0.025 {
                lastReport = now
                reports.append((now + link.oneWay, received))
            }
            let full = pacer.snapshot(at: now).linkFull
            if run.full.last?.full != full { run.full.append((now, full)) }
            now += step
        }
        run.latencies = link.trips.map { ($0.sentAt, $0.trip) }
        if ProcessInfo.processInfo.environment["PACER_DEBUG"] != nil {
            for second in stride(from: 0.0, to: seconds, by: 2.0) {
                let l = run.latencies.filter { $0.at >= second && $0.at < second + 2 }.map(\.latency).sorted()
                let p50 = l.isEmpty ? 0 : l[l.count / 2], p90 = l.isEmpty ? 0 : l[Int(Double(l.count) * 0.9)]
                print(String(format: "PACER t=%4.0f fps=%5.1f full=%d p50=%.3f p90=%.3f", second, run.fps(from: second, to: second + 2), run.linkFull(at: second + 2) ? 1 : 0, p50, p90))
            }
        }
        return (run, pacer)
    }

    func testAFastLinkGetsEveryFrame() {
        let (run, pacer) = stream(through: Link(capacity: 100_000_000 / 8, oneWay: 0.001), seconds: 12)
        XCTAssertGreaterThan(run.fps(from: 1, to: 12), 58)
        XCTAssertLessThan(run.latencies(after: 1).last ?? 1, 0.02)
        XCTAssertEqual(pacer.skippedFrames, 0)
        XCTAssertFalse(pacer.snapshot(at: 12).linkFull)
    }

    // The case pacing used to get wrong: a VPN across an ocean whose link has
    // room for the stream. Every frame goes, from the first second, at the
    // settings — nothing to earn first.
    func testAFarLinkWithRoomGetsEveryFrameAtOnce() {
        let (run, pacer) = stream(through: Link(capacity: 9_000_000 / 8, oneWay: 0.15), seconds: 20)
        XCTAssertGreaterThan(run.fps(from: 1, to: 20), 55)
        XCTAssertLessThan(run.p90(after: 1), 0.25)
        XCTAssertEqual(pacer.settings, .standard)
    }

    // A corporate VPN: the round trip swings between 300 and 540 ms. Its
    // swings are not taken for a slow link.
    func testAJitteryFarLinkWithRoomGetsEveryFrame() {
        let (run, _) = stream(through: Link(capacity: 9_000_000 / 8, oneWay: 0.15), seconds: 20) { now, link in
            link.oneWay = 0.15 + 0.06 * (sin(now * 7) + 1)
        }
        XCTAssertGreaterThan(run.fps(from: 2, to: 20), 55)
        XCTAssertLessThan(run.p90(after: 2), 0.4)
    }

    // A still screen for seconds between drags over a far link with room:
    // the still spells teach the pacer nothing and make it forget nothing, so
    // a drag after one is at the full rate from its first frames. (The first
    // drag of a far viewer's stream takes a moment to open the window.)
    func testADragAfterAStillSpellIsNotHeldBack() {
        let (run, _) = stream(
            through: Link(capacity: 20_000_000 / 8, oneWay: 0.17), seconds: 30, content: 0.6,
            moving: { now in Int(now / 5) % 2 == 1 }
        )
        XCTAssertGreaterThan(run.fps(from: 5, to: 6), 40, "the first drag")
        XCTAssertGreaterThan(run.fps(from: 6, to: 10), 55)
        for start in [15.0, 25.0] {
            XCTAssertGreaterThan(run.fps(from: start, to: start + 1), 55, "the drag at \(start) s")
        }
    }

    // A link slower than the stream: fewer frames, each fresh — the picture
    // a moment old, never a backlog — and the viewer is told the link is full.
    func testASlowFarLinkGetsFewerFreshFrames() {
        // A VPN across an ocean at 1 Mbit/s: a sixth of the stream's bitrate.
        let (run, pacer) = stream(through: Link(capacity: 1_000_000 / 8, oneWay: 0.17), seconds: 30)
        // A frame sized for 6 Mbit/s takes 0.2 s to cross this link alone.
        XCTAssertLessThan(run.p90(after: 5), 1.1, "within a round trip, the queue allowance and two frames' crossing")
        XCTAssertGreaterThan(run.fps(from: 5, to: 30), 3)
        XCTAssertLessThan(run.fps(from: 5, to: 30), 20)
        XCTAssertTrue(pacer.snapshot(at: 30).linkFull)
        XCTAssertGreaterThan(pacer.skippedFrames, 100)
        XCTAssertEqual(pacer.settings, .standard, "the settings never follow the link")
    }

    // Two minutes on that link: the window does not widen with its own queue
    // (a delay measured through the queue would), so the picture is as fresh
    // at the end as after the first seconds.
    func testASlowLinksLatencyDoesNotCreep() {
        let (run, _) = stream(through: Link(capacity: 1_000_000 / 8, oneWay: 0.17), seconds: 120)
        let early = run.latencies.filter { $0.at >= 10 && $0.at < 30 }.map(\.latency).sorted()
        let late = run.latencies.filter { $0.at >= 100 }.map(\.latency).sorted()
        XCTAssertLessThan(late[Int(Double(late.count) * 0.9)], early[Int(Double(early.count) * 0.9)] + 0.2)
        XCTAssertLessThan(late[Int(Double(late.count) * 0.9)], 1.1)
    }

    // The same link unpaced — what the viewer would watch without the gate
    // (a viewer that never says what it got): the backlog only grows.
    func testWithoutWordFromTheViewerASlowLinkFallsBehind() {
        let (run, _) = stream(through: Link(capacity: 1_000_000 / 8, oneWay: 0.17), seconds: 15, silent: { _ in true })
        XCTAssertGreaterThan(run.latencies.map(\.latency).max() ?? 0, 3)
    }

    func testALinkThatSlowsDownAndRecoversIsFollowed() {
        let (run, pacer) = stream(through: Link(capacity: 9_000_000 / 8, oneWay: 0.15), seconds: 40) { now, link in
            link.capacity = (15..<25).contains(now) ? 800_000 / 8 : 9_000_000 / 8
        }
        XCTAssertGreaterThan(run.fps(from: 2, to: 15), 55)
        XCTAssertLessThan(run.fps(from: 17, to: 25), 15)
        XCTAssertLessThan(run.p90(after: 18) , 1.0)
        XCTAssertTrue(run.linkFull(at: 24))
        XCTAssertGreaterThan(run.fps(from: 27, to: 40), 55, "every frame again once the link is back")
        XCTAssertFalse(run.linkFull(at: 40))
        XCTAssertEqual(pacer.settings, .standard)
    }

    // A VPN that stalls for a second and a half: frames wait out the stall,
    // and the stream is at full rate again a moment after the link is.
    func testALinkThatStallsIsBackAtOnce() {
        let (run, _) = stream(through: Link(capacity: 9_000_000 / 8, oneWay: 0.15), seconds: 20) { now, link in
            link.capacity = (10..<11.5).contains(now) ? 20_000 / 8 : 9_000_000 / 8
        }
        XCTAssertGreaterThan(run.fps(from: 2, to: 10), 55)
        XCTAssertLessThan(run.fps(from: 10.8, to: 11.5), 5, "the window filled: nothing more piles up")
        XCTAssertGreaterThan(run.fps(from: 13, to: 20), 55)
        XCTAssertLessThan(run.p90(after: 13), 0.25)
    }

    func testAViewersOwnFrameRateHolds() {
        let settings = StreamSettings(fps: 30, bitrate: 3_000_000, maxDimension: 960)
        let (run, pacer) = stream(through: Link(capacity: 100_000_000 / 8, oneWay: 0.001), seconds: 10, settings: settings)
        XCTAssertEqual(run.fps(from: 1, to: 10), 30, accuracy: 1)
        XCTAssertEqual(pacer.settings, settings)
    }

    // A viewer that stopped saying what it got — its socket dropped — gets a
    // frame now and then, not a flood nothing measures.
    func testAViewerThatFallsSilentGetsAFrameNowAndThen() {
        let (run, _) = stream(through: Link(capacity: 100_000_000 / 8, oneWay: 0.001), seconds: 16, silent: { $0 >= 4 })
        XCTAssertGreaterThan(run.fps(from: 1, to: 4), 55)
        XCTAssertLessThanOrEqual(run.fps(from: 7, to: 16), 1.01)
        XCTAssertGreaterThan(run.fps(from: 7, to: 16), 0.5)
    }

    // A viewer that never says anything — its socket never connects — gets
    // every frame after a few seconds, as before pacing.
    func testAViewerThatNeverSaysAnythingGetsEveryFrame() {
        let (run, _) = stream(through: Link(capacity: 100_000_000 / 8, oneWay: 0.001), seconds: 12, silent: { _ in true })
        XCTAssertLessThan(run.fps(from: 1, to: 4.5), 1.01)
        XCTAssertGreaterThan(run.fps(from: 6, to: 12), 55)
    }

    func testSettingsOutOfRangeAreBroughtIntoIt() {
        let pacer = StreamPacer(settings: StreamSettings(fps: 500, bitrate: 1, maxDimension: 10), now: 0)
        XCTAssertEqual(pacer.settings, StreamSettings(fps: 60, bitrate: 100_000, maxDimension: 240))
        XCTAssertEqual(pacer.frameInterval, 1 / 60, accuracy: 1e-9)
    }

    func testWhatTheViewerSaysBeyondWhatWasSentIsIgnored() {
        var pacer = StreamPacer(now: 0)
        pacer.sent(bytes: 1_000, at: 0)
        pacer.received(total: 5_000, at: 0.1)
        XCTAssertEqual(pacer.inFlight, 0)
        pacer.sent(bytes: 1_000, at: 0.2)
        XCTAssertEqual(pacer.inFlight, 1_000)
    }
}
