import Foundation
import SimToolStream

/// One encoded frame on its way to the viewers: the envelopes to write, and
/// what kind of frame they carry — which decides whether a client that is
/// behind may skip it.
struct StreamFrame: Sendable {
    enum Kind: Sendable {
        /// The decoder's configuration: never skipped.
        case description
        /// Decodes on its own: what a client that skipped frames waits for.
        case keyframe
        /// Decodes only after every frame before it.
        case delta
    }

    var kind: Kind
    var envelope: Data
}

/// The viewers' video connections. Every client writes on its own queue, so
/// one that reads slowly — a browser tab the system throttles or froze, a
/// laptop on a poor link — costs only itself: frames it has no room for are
/// skipped until the next keyframe, which it asks for once it caught up,
/// and the others stream on at full rate.
final class ClientManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "simtool.clients")
    private let stateLock = NSLock()

    private var cachedDescription: Data?
    private var avccClients: [ObjectIdentifier: StreamClient] = [:]
    private var avccClientCount = 0
    private var nextID = 0

    var onAvccClientConnect: (() -> Void)?
    /// A client that skipped frames caught up and needs a keyframe to decode again.
    var onClientNeedsKeyframe: (() -> Void)?
    /// A client (its id) fell behind and skipped a frame.
    var onSkip: ((Int) -> Void)?
    /// A client stopped reading for `StreamClient.stallLimit` and was let go.
    var onStall: ((Int) -> Void)?

    func addAvccClient() -> StreamClient {
        let client = StreamClient(id: nextClientID())
        client.onNeedsKeyframe = { [weak self] in self?.onClientNeedsKeyframe?() }
        let id = client.id
        client.onSkip = { [weak self] in self?.onSkip?(id) }
        client.onStall = { [weak self] id in self?.onStall?(id) }
        let key = ObjectIdentifier(client)
        stateLock.lock(); avccClientCount += 1; stateLock.unlock()
        queue.async { self.avccClients[key] = client }
        return client
    }

    func removeAvccClient(_ client: StreamClient) {
        let key = ObjectIdentifier(client)
        stateLock.lock(); avccClientCount = max(0, avccClientCount - 1); stateLock.unlock()
        queue.async { self.avccClients.removeValue(forKey: key) }
    }

    func hasAvccClients() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return avccClientCount > 0
    }

    func clientCounts() -> StreamClientCounts {
        queue.sync {
            StreamClientCounts(avcc: avccClients.count)
        }
    }

    func sendInitialAvcc(to client: StreamClient) {
        queue.async {
            if let description = self.cachedDescription { client.send(StreamFrame(kind: .description, envelope: description)) }
        }
        onAvccClientConnect?()
    }

    /// Queues the frame for every client; `onSent` gets how many took it.
    /// Never waits for a client to write.
    func broadcastAvcc(_ frame: StreamFrame, onSent: ((Int) -> Void)? = nil) {
        queue.async {
            if frame.kind == .description { self.cachedDescription = frame.envelope }
            var sent = 0
            for client in self.avccClients.values where client.send(frame) == .queued {
                sent += 1
            }
            onSent?(sent)
        }
    }

    func closeAll() {
        queue.sync {
            for client in avccClients.values { client.close() }
            avccClients.removeAll()
        }
        stateLock.lock(); avccClientCount = 0; stateLock.unlock()
    }

    private func nextClientID() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }
}

final class StreamClient: @unchecked Sendable {
    /// Frames queued and not yet written that a client may hold: beyond it,
    /// frames are skipped — a screen a quarter of a second old is better
    /// than a growing backlog of stale ones.
    static let backlogLimit = 3
    /// A write blocked this long is a client that stopped reading: the
    /// connection is let go, and the page reconnects once it reads again.
    static let stallLimit: TimeInterval = 10

    enum Outcome: Equatable { case queued, skipped, closed }

    let id: Int
    var onNeedsKeyframe: (() -> Void)?
    var onSkip: (() -> Void)?
    var onStall: ((Int) -> Void)?
    private let lock = NSLock()
    private let writes: DispatchQueue
    private var writer: ((Data) -> Bool)?
    private var onClose: (() -> Void)?
    private var closed = false
    private var queued = 0
    /// When the write in progress began; nil between writes.
    private var writingSince: Date?
    /// Nothing decodes until a keyframe: at the start, and after a skip.
    private var needsKeyframe = true
    /// A keyframe was asked for since this client last needed one. A new
    /// client's comes with its connection (`onAvccClientConnect`).
    private var askedForKeyframe = true

    init(id: Int) {
        self.id = id
        writes = DispatchQueue(label: "simtool.client.\(id)")
    }

    /// `onClose` ends the response: the server closed the client — it
    /// stops, or its simulator went off.
    func setWriter(_ writer: @escaping (Data) -> Bool, onClose: @escaping () -> Void = {}) {
        let closeNow = lock.withLock {
            self.writer = writer
            self.onClose = onClose
            return closed
        }
        if closeNow { close() }
    }

    /// Queues the frame, or skips it while the client is behind.
    @discardableResult
    func send(_ frame: StreamFrame, now: Date = Date()) -> Outcome {
        lock.lock()
        guard !closed, writer != nil else { lock.unlock(); return .closed }
        if let since = writingSince, now.timeIntervalSince(since) > Self.stallLimit {
            lock.unlock()
            onStall?(id)
            close()
            return .closed
        }
        let behind = queued >= Self.backlogLimit
        let skip: Bool
        switch frame.kind {
        case .description:
            skip = false
        case .keyframe:
            skip = behind
            if !behind {
                needsKeyframe = false
                askedForKeyframe = false
            }
        case .delta:
            skip = behind || needsKeyframe
        }
        if skip {
            needsKeyframe = true
            // The keyframe it waited for went by: it asks again once caught up.
            if frame.kind == .keyframe { askedForKeyframe = false }
            // Caught up already (only deltas it cannot decode came): ask now.
            let ask = queued == 0 && !askedForKeyframe
            if ask { askedForKeyframe = true }
            lock.unlock()
            if behind { onSkip?() }
            if ask { onNeedsKeyframe?() }
            return .skipped
        }
        queued += 1
        lock.unlock()
        writes.async { self.write(frame.envelope) }
        return .queued
    }

    private func write(_ data: Data) {
        lock.lock()
        guard !closed, let writer else {
            queued = max(0, queued - 1)
            lock.unlock()
            return
        }
        writingSince = Date()
        lock.unlock()
        let written = writer(data)
        lock.lock()
        writingSince = nil
        queued = max(0, queued - 1)
        if !written { closed = true }
        let ask = written && queued == 0 && needsKeyframe && !askedForKeyframe
        if ask { askedForKeyframe = true }
        lock.unlock()
        if ask { onNeedsKeyframe?() }
    }

    func close() {
        let ended = lock.withLock {
            closed = true
            writer = nil
            defer { onClose = nil }
            return onClose
        }
        ended?()
    }
}
