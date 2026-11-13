import Foundation
import SimToolCore

/// When one viewer's next frame may go: at its stream's frame rate, unless the
/// link is still carrying earlier frames.
///
/// The stream is encoded at fixed settings (`StreamSettings`): nothing here
/// changes its frame rate, bitrate or picture size — not the link, not what
/// the screen shows. What follows the link is only whether a frame goes at
/// all. The server cannot see a slow link from its side: what it writes lands
/// in socket buffers at once — the kernel's, an SSH tunnel's, a VPN's — and
/// waits there, so frames would pile up seconds deep before a write ever
/// blocked, and the viewer would watch the past. A viewer that says how many
/// bytes of its stream it has received (`{"t": "got"}` on its input channel)
/// shows what is really on its way, and how long each frame took to arrive.
///
/// So at most a window of bytes is on its way: what the link carries in its
/// own delay and a little more. A frame due while the window is full is not
/// encoded; the next one is, from the screen as it is then. A link that
/// carries the stream gets every frame the screen makes, up to the frame rate;
/// a slower one gets fewer, each of them fresh, never a backlog — and the
/// viewer is told its link is full, so a person can choose lighter settings.
///
/// What the link carries is learnt from the link alone, never from the
/// screen, and only while the window is what holds frames back. It drops to
/// what the link delivered — by half at most — when frames waited on the way
/// and the link delivered less than the window allowed; a VPN whose round trip
/// swings, delivering all it is given, is not slower for it. Otherwise it
/// rises: doubling until the link first proved slower, and after that while
/// frames cross with no wait or the link delivered more than expected; by a
/// little while they wait some. A still screen teaches nothing and forgets
/// nothing, so a drag after it goes at the rate the link last carried. A far
/// viewer starts at a modest window.
///
/// Every few seconds a stream the window holds back lets its frames drain
/// before the next one goes: that frame crosses an empty link, and its trip
/// is the link's own delay again — without it, a delay measured through the
/// window's own queue would widen the window, and the queue with it.
///
/// Times are seconds on one monotonic clock; nothing here reads a clock.
struct StreamPacer: Sendable {
    struct Tuning: Sendable {
        /// On the way besides the link's own delay: what may wait in its
        /// queue, and how long a frame may wait before the link counts as slower.
        var queueAllowance: TimeInterval = 0.15
        /// In flight at least, however slow the link.
        var minInFlight = 16 * 1024
        /// What a link nearer than `nearDelay` (this Mac, a LAN) starts at is
        /// the stream's bitrate; a farther one starts at `farStart` bits a
        /// second, if that is less.
        var farStart = 2_000_000
        var nearDelay: TimeInterval = 0.03
        /// What the link carries is never taken for more than this many times
        /// the stream's bitrate — past it the window is never what holds a
        /// frame back — nor less than `minRate`.
        var headroom = 1.25
        var minRate = 16 * 1024.0
        /// How much more the link may carry each window once it proved slower,
        /// while frames waited a little but less than the allowance…
        var riseFactor = 1.15
        /// …and below this, frames crossing with no wait: twice as much.
        var clear: TimeInterval = 0.04
        /// The link's own delay is the least seen this long…
        var delayMemory: TimeInterval = 10
        /// …and a stream the window holds back drains this often, so that
        /// a frame measures it across an empty link.
        var drainEvery: TimeInterval = 8
        /// What the link carries is judged once each window: this long, or two
        /// delays if longer.
        var rateWindow: TimeInterval = 0.5
        /// The best delivery measured stands this long — for the metrics only.
        var rateMemory: TimeInterval = 2
        /// Without word from the viewer this long, frames only trickle: one
        /// each `trickleEvery`…
        var silence: TimeInterval = 2
        var trickleEvery: TimeInterval = 1
        /// …unless no word ever came this long after the first frame: a viewer
        /// that cannot say (its socket never connects) gets every frame.
        var deafAfter: TimeInterval = 5
        /// A frame held back for a link slower than the stream this recently:
        /// the link is full.
        var fullFor: TimeInterval = 2
    }

    /// What the pacer reads now, for the status route and the viewer.
    struct Snapshot: Equatable, Sendable {
        var settings: StreamSettings
        /// What the link delivered at best lately, bits per second.
        var linkBitrate: Int?
        /// The least time a frame took to reach the viewer and be told of.
        var delayMs: Int?
        var inFlightBytes: Int
        var heard: Bool
        /// Screens not encoded because the link still carried earlier frames.
        var skippedFrames: Int
        /// Frames were held back lately, for a link slower than the stream.
        var linkFull: Bool
    }

    let tuning: Tuning
    let settings: StreamSettings

    private let startedAt: TimeInterval
    private var firstSentAt: TimeInterval?
    /// Bytes handed to the connection, and how many the viewer said it got.
    private var written = 0
    private var acked = 0
    /// Frames on their way: where each ends in the stream, how big it is, and when it went.
    private var unacked: [(end: Int, bytes: Int, at: TimeInterval)] = []
    private var delays: [(at: TimeInterval, delay: TimeInterval)] = []
    private var ackHistory: [(at: TimeInterval, total: Int)] = []
    private var rates: [(at: TimeInterval, bytesPerSecond: Double)] = []
    private var lastHeard: TimeInterval?
    private var lastEncodeAt: TimeInterval?
    /// What the link carries, bytes a second: the window is what it carries
    /// in its delay and the allowance.
    private(set) var carries: Double
    private var distanceKnown = false
    /// This judging window: since when, what had been acknowledged then, and
    /// whether frames were held back by the window or waited on the way.
    private var windowStart: TimeInterval
    private var windowAcked = 0
    private var heldInWindow = false
    /// The longest a frame waited on the way in this window, beyond the link's
    /// delay and its own crossing.
    private var waitedInWindow: TimeInterval = 0
    /// The link has proved slower than the window once: it rises slowly since.
    private var slowedOnce = false
    /// Frames on their way drain before the next goes, and since when that was last done.
    private var draining = false
    private var drainedAt: TimeInterval
    /// When a frame was last held back, and last counted as skipped.
    private var heldAt: TimeInterval = -.infinity
    private var skipCountedAt: TimeInterval = -.infinity
    private(set) var skippedFrames = 0

    init(settings: StreamSettings = .standard, tuning: Tuning = Tuning(), now: TimeInterval) {
        self.settings = settings.clamped
        self.tuning = tuning
        startedAt = now
        windowStart = now
        drainedAt = now
        carries = Double(self.settings.bitrate) / 8
    }

    var inFlight: Int { written - acked }

    /// The time between frames at the stream's frame rate.
    var frameInterval: TimeInterval { 1 / Double(settings.fps) }

    /// The link's own delay: the quickest a frame went to the viewer and the
    /// word came back, lately.
    var minDelay: TimeInterval? { delays.map(\.delay).min() }

    /// The most the link delivered lately, bytes per second.
    var linkRate: Double? { rates.map(\.bytesPerSecond).max() }

    /// What may be in flight before the next frame waits.
    var inFlightLimit: Int {
        max(tuning.minInFlight, Int(carries * ((minDelay ?? 0) + tuning.queueAllowance)))
    }

    /// When the next frame may be encoded: now or later, or nil while the
    /// link holds it back — until the viewer says it got more.
    func nextEncode(at now: TimeInterval) -> TimeInterval? {
        let earliest = lastEncodeAt.map { $0 + frameInterval } ?? now
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
        if inFlight > 0, draining || inFlight >= inFlightLimit { return nil }
        return max(now, earliest)
    }

    /// A frame was due but the link held it back (`nextEncode` said nil): the
    /// screen it would have carried is skipped. The wait for the first word is
    /// not the link's doing.
    mutating func heldBack(at now: TimeInterval) {
        guard acked > 0 else { return }
        heldAt = now
        heldInWindow = true
        if now - skipCountedAt >= frameInterval {
            skipCountedAt = now
            skippedFrames += 1
        }
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
        if draining, inFlight == 0 { draining = false }
        if !distanceKnown, let least = minDelay {
            // Once: a far viewer starts at a modest window, not a flood.
            distanceKnown = true
            if least >= tuning.nearDelay { carries = min(carries, Double(tuning.farStart) / 8) }
        }
        if let least = minDelay {
            // Late by more than the link's delay, the frame's own crossing
            // and the allowance: it waited behind others.
            for frame in arrived {
                waitedInWindow = max(waitedInWindow, frame.delay - least - Double(frame.bytes) / carries)
            }
        }
        measureRate(total: total, at: now)
        judge(at: now)
    }

    func snapshot(at now: TimeInterval) -> Snapshot {
        Snapshot(
            settings: settings,
            linkBitrate: linkRate.map { Int($0 * 8) },
            delayMs: minDelay.map { Int(($0 * 1000).rounded()) },
            inFlightBytes: inFlight,
            heard: lastHeard != nil,
            skippedFrames: skippedFrames,
            linkFull: now - heldAt <= tuning.fullFor && carries * 8 < Double(settings.bitrate) * 0.9
        )
    }

    /// Once each window in which the window held frames back: frames that
    /// waited on the way while the link delivered less than allowed say it
    /// carries less — what it delivered, at most half less; anything else says
    /// it may carry more — twice as much until the link first proved slower,
    /// and while frames crossed with no wait or the link delivered more than
    /// expected; a little more otherwise.
    private mutating func judge(at now: TimeInterval) {
        let window = max(tuning.rateWindow, 2 * (minDelay ?? 0))
        guard now - windowStart >= window else { return }
        let delivered = Double(acked - windowAcked) / (now - windowStart)
        let most = Double(settings.bitrate) / 8 * tuning.headroom
        if heldInWindow {
            if waitedInWindow > tuning.queueAllowance, delivered < carries * 0.9 {
                carries = min(carries, max(delivered, carries / 2))
                slowedOnce = true
            } else {
                let clean = !slowedOnce || waitedInWindow < tuning.clear || delivered > carries
                carries *= clean ? 2 : tuning.riseFactor
            }
            if now - drainedAt >= tuning.drainEvery {
                drainedAt = now
                draining = true
            }
        }
        carries = min(most, max(tuning.minRate, carries))
        windowStart = now
        windowAcked = acked
        heldInWindow = false
        waitedInWindow = 0
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
}
