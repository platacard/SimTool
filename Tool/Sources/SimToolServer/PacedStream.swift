import CoreMedia
import CoreVideo
import Foundation
import SimToolCore
import SimToolStream

/// One viewer's own stream, at fixed settings, paced to its link (`StreamPacer`).
///
/// The viewer names its stream (`/stream.avcc?sid=…`, with its own `fps`,
/// `kbps` and `px` when it chose them) and says on its input channel how much
/// of it it has received. Its encoder works at those settings the whole time;
/// it takes the screen as it is whenever the link has room for a frame — never
/// a backlog of older ones — so a viewer across a slow VPN sees the device as
/// it is now at fewer frames a second, not half a minute ago at sixty, and a
/// viewer whose link carries the stream gets every frame.
final class PacedStream: @unchecked Sendable {
    let id: String
    let client: StreamClient

    private let encoder: H264Encoder
    private let queue: DispatchQueue
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    /// What the encoder works on: read on its callback thread.
    private var encodingRepeat = false
    private var encodedFrames = 0
    private var sentBytes = 0

    // On `queue`:
    private var pacer: StreamPacer
    private var latest: CVPixelBuffer?
    private var changedSinceEncode = false
    private var pending = false
    private var encoding = false
    private var forceKeyframe = false
    private var wakeArmed = false
    private var stopped = false
    private var lastEncodeAt: TimeInterval?
    private var presentationSeconds = 0.0
    private var announced: StreamPacer.Snapshot?
    /// The encoder's description, sent again before each keyframe: whatever
    /// the client missed, a keyframe decodes.
    private var description: Data?

    init(id: String, client: StreamClient, settings: StreamSettings = .standard, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.id = id
        self.client = client
        self.clock = clock
        queue = DispatchQueue(label: "simtool.paced-stream.\(client.id)", qos: .userInteractive)
        let pacer = StreamPacer(settings: settings, now: clock())
        self.pacer = pacer
        encoder = H264Encoder(fps: pacer.settings.fps, bitrate: pacer.settings.bitrate, maxDimension: pacer.settings.maxDimension)
        encoder.setExpectedFrameRate(Double(pacer.settings.fps))
        encoder.onEncoded = { [weak self] encoded in self?.deliver(encoded) }
        client.onNeedsKeyframe = { [weak self] in self?.requestKeyframe() }
    }

    /// A captured screen; `changed` false for the refresh of a still one.
    func offer(_ buffer: CVPixelBuffer, changed: Bool) {
        queue.async {
            guard !self.stopped else { return }
            self.latest = buffer
            if changed { self.changedSinceEncode = true }
            self.pending = true
            self.pump()
        }
    }

    /// The viewer has received `total` bytes of this stream. Returns what to
    /// tell the viewer of its stream the first time, and again when its link
    /// turns full or clears.
    func received(total: Int) -> StreamPacer.Snapshot? {
        let answer: StreamPacer.Snapshot? = queue.sync {
            guard !stopped else { return nil }
            let at = clock()
            pacer.received(total: total, at: at)
            let now = pacer.snapshot(at: at)
            if let said = announced, said.linkFull == now.linkFull { return nil }
            announced = now
            return now
        }
        // The encode the room it made allows runs on the stream's queue, not
        // on the socket's thread, which carries the viewer's touches too.
        queue.async { self.pump() }
        return answer
    }

    /// The client skipped a frame and caught up: the next frame decodes on its own.
    func requestKeyframe() {
        queue.async {
            self.forceKeyframe = true
            self.pending = self.latest != nil
            self.pump()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            latest = nil
        }
        encoder.stop()
    }

    func metrics() -> StreamViewerMetrics {
        let snapshot = queue.sync { pacer.snapshot(at: clock()) }
        let (frames, bytes) = lock.withLock { (encodedFrames, sentBytes) }
        return StreamViewerMetrics(
            id: String(id.prefix(8)),
            fps: snapshot.settings.fps,
            bitrate: snapshot.settings.bitrate,
            maxDimension: snapshot.settings.maxDimension,
            linkBitrate: snapshot.linkBitrate,
            delayMs: snapshot.delayMs,
            inFlightBytes: snapshot.inFlightBytes,
            encodedFrames: frames,
            skippedFrames: snapshot.skippedFrames,
            sentBytes: bytes
        )
    }

    // MARK: - On `queue`

    private func pump() {
        guard !stopped, !encoding, pending, let buffer = latest else { return }
        let now = clock()
        guard let next = pacer.nextEncode(at: now) else {
            // The link holds it: the viewer's next word pumps again.
            if lastEncodeAt.map({ now - $0 >= pacer.frameInterval }) ?? true { pacer.heldBack(at: now) }
            return
        }
        if next > now {
            guard !wakeArmed else { return }
            wakeArmed = true
            queue.asyncAfter(deadline: .now() + (next - now)) {
                self.wakeArmed = false
                self.pump()
            }
            return
        }
        encoding = true
        pending = false
        pacer.encoded(at: now)
        // The rate control's clock moves at most two frames between frames:
        // a frame after a wait for the link is no bigger than the others.
        let interval = pacer.frameInterval
        presentationSeconds += min(now - (lastEncodeAt ?? (now - interval)), 2 * interval)
        lastEncodeAt = now
        let repeats = !changedSinceEncode
        changedSinceEncode = false
        let force = forceKeyframe
        forceKeyframe = false
        lock.withLock { encodingRepeat = repeats }
        encoder.encode(buffer, forceKeyframe: force, presentationTime: CMTime(seconds: presentationSeconds, preferredTimescale: 60_000)) { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.encoding = false
                self.pump()
            }
        }
    }

    // MARK: - On the encoder's thread

    private func deliver(_ encoded: H264Encoder.Encoded) {
        // A still screen's refresh is marked, as on the shared stream.
        var envelope = lock.withLock { encodingRepeat } ? AVCCEnvelope.repeatsScreen() : Data()
        switch encoded.kind {
        case .keyframe: envelope.append(AVCCEnvelope.keyframe(avcc: encoded.avcc))
        case .delta: envelope.append(AVCCEnvelope.delta(avcc: encoded.avcc))
        }
        let frame = StreamFrame(kind: encoded.kind == .keyframe ? .keyframe : .delta, envelope: envelope)
        // Handed to the client on the stream's queue, in order, each frame
        // counted as sent before the viewer can say it got it; and before
        // the encode's completion pumps the next frame.
        queue.async {
            guard !self.stopped else { return }
            if let fresh = encoded.description { self.description = AVCCEnvelope.description(avcc: fresh) }
            var frames: [StreamFrame] = []
            if encoded.kind == .keyframe, let description = self.description {
                frames.append(StreamFrame(kind: .description, envelope: description))
            }
            frames.append(frame)
            var bytes = 0
            for frame in frames where self.client.send(frame) == .queued {
                bytes += frame.envelope.count
            }
            self.pacer.sent(bytes: bytes, at: self.clock())
            self.lock.withLock {
                self.encodedFrames += 1
                self.sentBytes += bytes
            }
        }
    }
}
