import Foundation

/// The pace of one viewer's own stream: how much of it is on its way, how
/// fast the viewer's link carries it, and so how often, how big and how
/// sharp its next frames may be.
///
/// The server cannot see a slow link from its side: what it writes lands in
/// socket buffers at once — the kernel's, an SSH tunnel's, a VPN's — and
/// waits there, so the frames of a changing screen pile up seconds deep
/// before a write ever blocks, and the viewer watches the past. A viewer that
/// says how many bytes of its stream it has received (`{"t": "got"}` on its
/// input channel) shows what is really on its way, and how long each frame
/// took to arrive.
///
/// Two things follow from that. What may be in flight is what the bitrate —
/// or the link, when it delivered more — carries in the link's own delay and
/// a little more: past it, the next frame waits to be encoded rather than in
/// a queue, so the viewer sees the screen as it is now, at a lower frame
/// rate. And the bitrate drops only when the link proves too slow for it —
/// frames had to wait for the link, or waited on the way, arriving later
/// than the link's delay and their own size explain — to what the link
/// delivered then, by half at most and once for each such spell (a VPN that
/// stalls for a second is not a slow link); while nothing waits and the
/// stream uses what it has, it rises again — fast on a near link, at once
/// to what the link has shown it delivers. A still screen sends little, and says
/// nothing about the link: it never lowers the bitrate. A far link starts at
/// a modest bitrate. A low bitrate also lowers the frame rate and, further
/// down, the picture's size: fewer, clearer frames read better than many
/// smeared ones.
///
/// Times are seconds on one monotonic clock; nothing here reads a clock.
struct StreamPacer: Sendable {
    struct Tuning: Sendable {
        /// The stream at full quality: what a viewer on this Mac gets.
        var maxBitrate = 6_000_000
        var minBitrate = 250_000
        /// Where a new stream starts: full quality within a second on a near
        /// link, a first keyframe that does not take long on a far one —
        /// which then goes on from `farStartBitrate`.
        var startBitrate = 3_000_000
        var farStartBitrate = 1_000_000
        /// The share of the delivered rate the encoder aims at after frames
        /// had to wait: room for the queue to drain, and for the link to vary.
        var headroom = 0.8
        /// A cut keeps at least this share of the bitrate.
        var deepestCut = 0.5
        /// Bits per second each frame per second needs: the frame rate cap
        /// is the bitrate over this — 60 fps from 3 Mbit/s, 20 from 1.
        var bitsPerFrame = 50_000.0
        var maxFPS = 60.0
        var minFPS = 8.0
        /// In flight, besides what the link carries in its delay.
        var queueAllowance: TimeInterval = 0.15
        /// In flight at least, whatever the link measures.
        var minInFlight = 16 * 1024
        /// A frame that waited on the way this long: the stream outruns the link.
        var congested: TimeInterval = 0.12
        /// Below this nothing waits, and the bitrate may rise.
        var clear: TimeInterval = 0.04
        /// Delivery is measured over this window, or two delays if longer…
        var rateWindow: TimeInterval = 0.5
        /// …and the best of those measures stands for the link this long.
        var rateMemory: TimeInterval = 2
        /// The link's own delay is the least seen this long.
        var delayMemory: TimeInterval = 10
        /// The bitrate rises by this factor each `riseEvery` while nothing
        /// waits and the encoder uses what it has — by `nearRiseFactor` on a
        /// link nearer than `nearDelay` (this Mac, a LAN).
        var riseFactor = 1.12
        var nearRiseFactor = 1.5
        var riseEvery: TimeInterval = 0.5
        var nearDelay: TimeInterval = 0.03
        /// Without word from the viewer this long, frames only trickle: one
        /// each `trickleEvery`…
        var silence: TimeInterval = 2
        var trickleEvery: TimeInterval = 1
        /// …unless no word ever came this long after the first frame: a
        /// viewer that cannot say (its socket never connects) gets the
        /// stream unpaced, as before pacing.
        var deafAfter: TimeInterval = 5
        /// The picture's longest side at each bitrate, highest first.
        var dimensions: [(minBitrate: Int, maxDimension: Int)] = [(1_200_000, 1280), (500_000, 960), (0, 720)]
        /// A new size has to be due this long, and the last change this old.
        var dimensionSettle: TimeInterval = 2
        var dimensionGap: TimeInterval = 6
    }

    /// What the pacer reads now, for the status route and the viewer.
    struct Snapshot: Equatable, Sendable {
        var bitrate: Int
        var maxDimension: Int
        var fpsCap: Int
        /// What the link delivered at best lately, bits per second.
        var linkBitrate: Int?
        /// The least time a frame took to reach the viewer and be told of.
        var delayMs: Int?
        var inFlightBytes: Int
        var heard: Bool
        /// The full stream: the top bitrate and size.
        var full: Bool
    }

    let tuning: Tuning
    private(set) var bitrate: Int
    private(set) var maxDimension: Int

    private let startedAt: TimeInterval
    private var firstSentAt: TimeInterval?
    /// Whether the first word told how far the viewer is.
    private var distanceKnown = false
    /// Bytes handed to the connection, and how many the viewer said it got.
    private var written = 0
    private var acked = 0
    /// Frames on their way: where each ends in the stream, how big it is,
    /// and when it went.
    private var unacked: [(end: Int, bytes: Int, at: TimeInterval)] = []
    private var delays: [(at: TimeInterval, delay: TimeInterval)] = []
    /// How long the last frame the viewer got waited on the way.
    private var waited: TimeInterval?
    private var ackHistory: [(at: TimeInterval, total: Int)] = []
    private var rates: [(at: TimeInterval, bytesPerSecond: Double)] = []
    private var encodedHistory: [(at: TimeInterval, bytes: Int)] = []
    private var lastHeard: TimeInterval?
    /// When a frame last waited for the link rather than for the frame rate.
    private var heldBackAt: TimeInterval?
    private var lastEncodeAt: TimeInterval?
    private var lastRise: TimeInterval
    private var lastCut: TimeInterval = -.infinity
    /// What had been written when the bitrate was last cut: until the viewer
    /// got that far, what it gets was sent before the cut.
    private var cutAt = 0
    private var dimensionDue: (dimension: Int, since: TimeInterval)?
    private var lastDimensionChange: TimeInterval

    init(tuning: Tuning = Tuning(), now: TimeInterval) {
        self.tuning = tuning
        startedAt = now
        lastRise = now
        lastDimensionChange = now
        bitrate = min(tuning.maxBitrate, max(tuning.minBitrate, tuning.startBitrate))
        maxDimension = 0
        maxDimension = dimension(for: bitrate)
    }

    var inFlight: Int { written - acked }

    /// Frames per second the bitrate affords.
    var fpsCap: Double {
        min(tuning.maxFPS, max(tuning.minFPS, Double(bitrate) / tuning.bitsPerFrame))
    }

    /// The link's own delay: the quickest a frame went to the viewer and the
    /// word came back, lately.
    var minDelay: TimeInterval? { delays.map(\.delay).min() }

    /// The most the link delivered lately, bytes per second.
    var linkRate: Double? { rates.map(\.bytesPerSecond).max() }

    /// What may be in flight before the next frame waits: what the bitrate,
    /// or the link when it delivered more, carries in the link's delay, and a
    /// little more. Held back past it, the link is too slow for the bitrate.
    func inFlightLimit(at now: TimeInterval) -> Int {
        let carry = max(Double(bitrate) / 8, linkRate ?? 0)
        return max(tuning.minInFlight, Int(carry * ((minDelay ?? 0) + tuning.queueAllowance)))
    }

    /// When the next frame may be encoded: now or later, or nil while the
    /// link holds it back — until the viewer says it got more.
    func nextEncode(at now: TimeInterval) -> TimeInterval? {
        let earliest = lastEncodeAt.map { $0 + 1 / fpsCap } ?? now
        if lastHeard == nil, let firstSentAt, now - firstSentAt > tuning.deafAfter {
            return max(now, earliest)
        }
        if inFlight > 0, now - (lastHeard ?? startedAt) > tuning.silence {
            // No word from the viewer: a frame now and then keeps its
            // picture alive without filling a link nothing measures.
            return max(earliest, (lastEncodeAt ?? now) + tuning.trickleEvery)
        }
        // The first frame alone until the viewer says it got some: how far
        // the viewer is, nothing tells before.
        if inFlight > 0, acked == 0 { return nil }
        if inFlight > 0, inFlight >= inFlightLimit(at: now) { return nil }
        return max(now, earliest)
    }

    /// A frame was due but the link held it back (`nextEncode` said nil).
    /// The wait for the first word is not the link's doing.
    mutating func heldBack(at now: TimeInterval) {
        guard acked > 0 else { return }
        heldBackAt = now
    }

    /// The encoder took a frame.
    mutating func encoded(at now: TimeInterval) {
        lastEncodeAt = now
    }

    /// A frame of `bytes` went to the connection.
    mutating func sent(bytes: Int, at now: TimeInterval) {
        guard bytes > 0 else { return }
        if firstSentAt == nil { firstSentAt = now }
        written += bytes
        unacked.append((written, bytes, now))
        encodedHistory.append((now, bytes))
        encodedHistory.removeAll { now - $0.at > 1 }
    }

    /// The viewer has received `total` bytes of its stream.
    mutating func received(total: Int, at now: TimeInterval) {
        lastHeard = now
        let total = min(total, written)
        guard total > acked else { return }
        acked = total
        var arrived: [(bytes: Int, delay: TimeInterval)] = []
        while let first = unacked.first, first.end <= total {
            unacked.removeFirst()
            arrived.append((first.bytes, now - first.at))
        }
        for frame in arrived { delays.append((now, frame.delay)) }
        delays.removeAll { now - $0.at > tuning.delayMemory }
        if !distanceKnown, let least = minDelay {
            // Once: a far viewer whose first frame showed how far, not how fast.
            distanceKnown = true
            if least >= tuning.nearDelay, bitrate > tuning.farStartBitrate {
                setBitrate(tuning.farStartBitrate)
                maxDimension = dimension(for: bitrate)
                lastDimensionChange = now
            }
        }
        measureRate(total: total, at: now)
        if let last = arrived.last, let least = minDelay {
            // Late by more than the link's delay and the frame's own size:
            // it waited behind others.
            let carrying = linkRate.map { Double(last.bytes) / $0 } ?? 0
            waited = max(0, last.delay - least - carrying)
        }
        adjust(at: now)
    }

    var snapshot: Snapshot {
        Snapshot(
            bitrate: bitrate,
            maxDimension: maxDimension,
            fpsCap: Int(fpsCap.rounded()),
            linkBitrate: linkRate.map { Int($0 * 8) },
            delayMs: minDelay.map { Int(($0 * 1000).rounded()) },
            inFlightBytes: inFlight,
            heard: lastHeard != nil,
            full: bitrate >= tuning.maxBitrate && maxDimension == (tuning.dimensions.first?.maxDimension ?? maxDimension)
        )
    }

    private mutating func measureRate(total: Int, at now: TimeInterval) {
        ackHistory.append((now, total))
        let window = max(tuning.rateWindow, 2 * (minDelay ?? 0))
        ackHistory.removeAll { now - $0.at > window * 2 }
        if let base = ackHistory.last(where: { now - $0.at >= window }), now > base.at {
            rates.append((now, Double(total - base.total) / (now - base.at)))
        }
        rates.removeAll { now - $0.at > tuning.rateMemory }
    }

    private mutating func adjust(at now: TimeInterval) {
        guard let waited, let least = minDelay else { return }
        let window = max(tuning.rateWindow, 2 * least)
        // Held back past what the bitrate carries in the link's delay: the
        // link is slower than the bitrate. Or frames waited on the way.
        let held = heldBackAt.map { now - $0 <= window } ?? false
        // Only a stream that uses its bitrate — or would, were it not held
        // back — learns about it from the link: a still screen sends little
        // whatever the bitrate, and a link that stalls under it is not too
        // slow for the bitrate.
        let used = Double(encodedHistory.reduce(0) { $0 + $1.bytes }) * 8 >= Double(bitrate) * 0.5
        if held || (waited > tuning.congested && used) {
            // Once per spell: what was sent before the last cut tells
            // nothing of the cut.
            guard acked >= cutAt, now - lastCut > least + tuning.queueAllowance else { return }
            lastCut = now
            cutAt = written
            // What the link delivered while it was too slow: the best of the
            // last window, not a still screen's trickle before it.
            let delivered = rates.filter { now - $0.at <= window }.map(\.bytesPerSecond).max()
            let target = delivered.map { Int($0 * 8 * tuning.headroom) } ?? Int(Double(bitrate) * tuning.headroom)
            setBitrate(min(bitrate, max(target, Int(Double(bitrate) * tuning.deepestCut))))
            // What the link carried before no longer holds.
            rates.removeAll { now - $0.at > window }
        } else if !held, waited < tuning.clear, acked >= cutAt, now - lastRise >= tuning.riseEvery, now - lastCut >= tuning.riseEvery {
            lastRise = now
            if used {
                let near = least < tuning.nearDelay
                let step = Int(Double(bitrate) * (near ? tuning.nearRiseFactor : tuning.riseFactor))
                // What the link has just shown it delivers, at once.
                let shown = linkRate.map { Int($0 * 8 * tuning.headroom) } ?? 0
                setBitrate(max(step, shown))
            }
        }
        settleDimension(at: now)
    }

    private mutating func setBitrate(_ value: Int) {
        bitrate = min(tuning.maxBitrate, max(tuning.minBitrate, value))
    }

    private mutating func settleDimension(at now: TimeInterval) {
        let wanted = dimension(for: bitrate)
        guard wanted != maxDimension else { dimensionDue = nil; return }
        if dimensionDue?.dimension != wanted { dimensionDue = (wanted, now) }
        guard let due = dimensionDue, now - due.since >= tuning.dimensionSettle,
              now - lastDimensionChange >= tuning.dimensionGap else { return }
        maxDimension = wanted
        lastDimensionChange = now
        dimensionDue = nil
    }

    private func dimension(for bitrate: Int) -> Int {
        tuning.dimensions.first { bitrate >= $0.minBitrate }?.maxDimension ?? tuning.dimensions.last?.maxDimension ?? 1280
    }
}
