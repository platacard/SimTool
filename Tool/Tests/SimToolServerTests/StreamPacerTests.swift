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
        var bitrates: [(at: TimeInterval, bitrate: Int)] = []
        var dimensions: [(at: TimeInterval, dimension: Int)] = []

        func latencies(after start: TimeInterval) -> [TimeInterval] {
            latencies.filter { $0.at >= start }.map(\.latency).sorted()
        }

        func fps(from start: TimeInterval, to end: TimeInterval) -> Double {
            Double(frames.filter { $0 >= start && $0 < end }.count) / (end - start)
        }

        func bitrate(at time: TimeInterval) -> Int {
            bitrates.last { $0.at <= time }?.bitrate ?? 0
        }
    }

    /// A screen streamed for `seconds` through `link`: while `moving` (a list
    /// being dragged) frames as big as the bitrate makes them times
    /// `content` — simple content takes less than the encoder may use —
    /// otherwise the still screen's small refresh five times a second; the
    /// first frame a keyframe; the viewer telling what it got every 25 ms
    /// unless `silent`.
    private func stream(
        through initial: Link,
        seconds: TimeInterval,
        silent: @escaping (TimeInterval) -> Bool = { _ in false },
        content: Double = 1,
        moving: @escaping (TimeInterval) -> Bool = { _ in true },
        change: ((TimeInterval, inout Link) -> Void)? = nil
    ) -> (Run, StreamPacer) {
        var link = initial
        var pacer = StreamPacer(now: 0)
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
            if due, next == nil, now - (lastFrame ?? -1) >= 1 / pacer.fpsCap { pacer.heldBack(at: now) }
            if let next, next <= now {
                do {
                    pacer.encoded(at: now)
                    // The encoder's clock moves at most two frames between
                    // frames (PacedStream): a frame after a wait is no bigger.
                    let elapsed = min(2 / pacer.fpsCap, now - (lastFrame ?? (now - 1 / 60)))
                    var bytes = still ? 400 : max(400, Int(Double(pacer.bitrate) / 8 * elapsed * content))
                    if lastFrame == nil { bytes = bytes * 3 + 20_000 }
                    lastFrame = now
                    pacer.sent(bytes: bytes, at: now)
                    link.send(bytes, at: now)
                    run.frames.append(now)
                }
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
            if run.bitrates.last?.bitrate != pacer.bitrate { run.bitrates.append((now, pacer.bitrate)) }
            if run.dimensions.last?.dimension != pacer.maxDimension { run.dimensions.append((now, pacer.maxDimension)) }
            now += step
        }
        run.latencies = link.trips.map { ($0.sentAt, $0.trip) }
        if ProcessInfo.processInfo.environment["PACER_DEBUG"] != nil {
            for second in stride(from: 0.0, to: seconds, by: 2.0) {
                let l = run.latencies.filter { $0.at >= second && $0.at < second + 2 }.map(\.latency).sorted()
                let p50 = l.isEmpty ? 0 : l[l.count / 2], p90 = l.isEmpty ? 0 : l[Int(Double(l.count) * 0.9)]
                print(String(format: "PACER t=%4.0f fps=%5.1f bitrate=%7d p50=%.3f p90=%.3f", second, run.fps(from: second, to: second + 2), run.bitrate(at: second + 2), p50, p90))
            }
        }
        return (run, pacer)
    }

    func testAFastLinkGetsTheFullStream() {
        let (run, pacer) = stream(through: Link(capacity: 100_000_000 / 8, oneWay: 0.001), seconds: 12)
        XCTAssertEqual(pacer.bitrate, 6_000_000)
        XCTAssertEqual(pacer.maxDimension, 1280)
        XCTAssertGreaterThan(run.fps(from: 2, to: 12), 58)
        XCTAssertLessThan(run.latencies(after: 2).last ?? 1, 0.02)
    }

    func testASlowFarLinkTradesFramesForAFreshPicture() {
        // A VPN across an ocean: 1 Mbit/s, 340 ms round trip.
        let (run, pacer) = stream(through: Link(capacity: 1_000_000 / 8, oneWay: 0.17), seconds: 40)
        let latencies = run.latencies(after: 15)
        let p90 = latencies[Int(Double(latencies.count) * 0.9)]
        XCTAssertLessThan(p90, 0.8, "a frame reaches the viewer within a round trip and a frame's time")
        XCTAssertGreaterThan(run.fps(from: 15, to: 40), 8)
        XCTAssertGreaterThan(pacer.bitrate, 400_000)
        XCTAssertLessThan(pacer.bitrate, 1_400_000)
        let start = run.latencies.filter { $0.at < 5 }.map(\.latency).max() ?? 0
        XCTAssertLessThan(start, 1.2, "the first frames do not flood a link not yet measured")
        XCTAssertEqual(pacer.maxDimension, 960)
        XCTAssertLessThan(pacer.snapshot.delayMs ?? 0, 400)
    }

    func testALinkThatSlowsDownIsFollowed() {
        let (run, _) = stream(through: Link(capacity: 8_000_000 / 8, oneWay: 0.05), seconds: 40) { now, link in
            if now >= 15 { link.capacity = 600_000 / 8 }
        }
        XCTAssertGreaterThan(run.bitrate(at: 14.9), 4_000_000)
        XCTAssertLessThan(run.bitrate(at: 25), 800_000)
        let p90 = run.latencies(after: 22)[Int(Double(run.latencies(after: 22).count) * 0.9)]
        XCTAssertLessThan(p90, 0.6)
    }

    func testALinkThatRecoversGetsTheBitrateBack() {
        let (run, pacer) = stream(through: Link(capacity: 700_000 / 8, oneWay: 0.1), seconds: 50) { now, link in
            if now >= 20 { link.capacity = 50_000_000 / 8 }
        }
        XCTAssertLessThan(run.bitrate(at: 19.9), 800_000)
        XCTAssertEqual(pacer.bitrate, 6_000_000)
        XCTAssertEqual(pacer.maxDimension, 1280)
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
    // the stream unpaced after a few seconds, as before pacing.
    func testAViewerThatNeverSaysAnythingGetsTheStreamUnpaced() {
        let (run, _) = stream(through: Link(capacity: 100_000_000 / 8, oneWay: 0.001), seconds: 12, silent: { _ in true })
        XCTAssertLessThan(run.fps(from: 1, to: 4.5), 1.01)
        XCTAssertGreaterThan(run.fps(from: 6, to: 12), 55)
    }

    // How far the viewer is is learnt once: a stall long enough to forget the
    // link's delay does not start the stream over at the far bitrate.
    func testTheFarStartHappensOnce() {
        var pacer = StreamPacer(now: 0)
        pacer.sent(bytes: 1_000, at: 0)
        pacer.received(total: 1_000, at: 0.005)
        XCTAssertEqual(pacer.bitrate, 3_000_000, "near: no far start")
        pacer.sent(bytes: 1_000, at: 20)
        pacer.received(total: 2_000, at: 20.3)
        XCTAssertEqual(pacer.bitrate, 3_000_000, "a late frame after a long silence is not a first one")
    }

    func testTheSizeChangesOnlyOnceSettled() {
        // 300 kbit/s, 100 ms away: a far viewer starts smaller at once; the
        // bitrate then drops within seconds, and the picture shrinks again
        // only once that lasted, and the last change is old.
        let (run, pacer) = stream(through: Link(capacity: 300_000 / 8, oneWay: 0.05), seconds: 30)
        XCTAssertEqual(run.dimensions.map(\.dimension), [1280, 960, 720])
        XCTAssertLessThan(run.dimensions[1].at, 2, "the far start, once its first frame arrived")
        XCTAssertGreaterThanOrEqual(run.dimensions[2].at - run.dimensions[1].at, 6)
        XCTAssertEqual(pacer.maxDimension, 720)
    }

    // A VPN that stalls for a second and a half: one cut, not a fall to the
    // floor, and the bitrate is back soon after the link is.
    func testALinkThatStallsIsNotTakenForASlowOne() {
        let (run, _) = stream(through: Link(capacity: 5_000_000 / 8, oneWay: 0.17), seconds: 30) { now, link in
            link.capacity = (12..<13.5).contains(now) ? 20_000 / 8 : 5_000_000 / 8
        }
        let before = run.bitrate(at: 11.9)
        XCTAssertGreaterThan(before, 2_000_000)
        let lowest = run.bitrates.filter { $0.at >= 12 && $0.at < 20 }.map(\.bitrate).min() ?? 0
        XCTAssertGreaterThanOrEqual(lowest, before / 4, "no fall to the floor")
        XCTAssertGreaterThan(run.bitrate(at: 20), before * 8 / 10, "back once the link is")
    }

    // A still screen over a VPN that stalls now and then: the stalls are not
    // the bitrate's doing, and a drag after them starts where it was.
    func testAStillScreenOverAStallingLinkKeepsItsBitrate() {
        let (run, pacer) = stream(
            through: Link(capacity: 5_000_000 / 8, oneWay: 0.17), seconds: 20,
            moving: { now in now < 4 || now >= 18 }
        ) { now, link in
            link.capacity = (6..<8).contains(now) || (11..<14).contains(now) ? 4_000 / 8 : 5_000_000 / 8
        }
        let beforeStill = run.bitrate(at: 4)
        XCTAssertGreaterThanOrEqual(run.bitrate(at: 17.9), beforeStill, "no cut while still")
        XCTAssertGreaterThanOrEqual(pacer.bitrate, beforeStill)
    }

    // A far link with room to spare, a screen still for seconds between
    // drags, content simpler than the bitrate: nothing there says the link
    // is slow, so the bitrate is never cut, and a drag after a still spell
    // is not held back.
    func testAStillScreenSaysNothingAboutTheLink() {
        let (run, pacer) = stream(
            through: Link(capacity: 20_000_000 / 8, oneWay: 0.17), seconds: 40, content: 0.6,
            moving: { now in Int(now / 5) % 2 == 1 }
        )
        XCTAssertGreaterThanOrEqual(run.bitrates.dropFirst().map(\.bitrate).min() ?? 0, 1_000_000, "never below the far start")
        XCTAssertGreaterThan(pacer.bitrate, 1_500_000, "a drag that uses the bitrate raises it")
        XCTAssertGreaterThan(run.fps(from: 35, to: 40), 25)
        let moving = run.latencies.filter { Int($0.at / 5) % 2 == 1 && $0.at > 5 }.map(\.latency).sorted()
        XCTAssertLessThan(moving[Int(Double(moving.count) * 0.9)], 0.25)
    }

    func testTheFrameRateFollowsTheBitrate() {
        var tuning = StreamPacer.Tuning()
        tuning.startBitrate = 1_000_000
        XCTAssertEqual(StreamPacer(tuning: tuning, now: 0).fpsCap, 20)
        tuning.startBitrate = 6_000_000
        XCTAssertEqual(StreamPacer(tuning: tuning, now: 0).fpsCap, 60)
        tuning.startBitrate = 250_000
        XCTAssertEqual(StreamPacer(tuning: tuning, now: 0).fpsCap, 8)
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
