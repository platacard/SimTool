import Foundation

/// SimTool's own log: what it does and what goes wrong inside it, by area
/// (`tag`). Lines go to stderr when the CLI runs with `--verbose`, and to
/// every sink — a server shows them in its viewer's Logs tab, apart from the
/// app's, whether or not it is verbose.
public enum DebugLog {
    public enum Level: String, Codable, Equatable, Sendable {
        /// Diagnostics: what a helper said, a request refused.
        case debug = "Debug"
        /// Something SimTool did: the simulator off and on, an app relaunched.
        case info = "Info"
        /// Something that failed and was not reported anywhere else.
        case error = "Error"
    }

    public struct Line: Equatable, Sendable {
        public var level: Level
        public var tag: String
        public var message: String
        public var date: Date

        public init(level: Level, tag: String, message: String, date: Date = Date()) {
            self.level = level
            self.tag = tag
            self.message = message
            self.date = date
        }
    }

    /// Whether lines go to stderr; the CLI's `--verbose`.
    public static var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var enabled = false
    private nonisolated(unsafe) static var sinks: [UUID: @Sendable (Line) -> Void] = [:]

    public static func write(_ tag: String, _ message: String) {
        emit(Line(level: .debug, tag: tag, message: message))
    }

    public static func info(_ tag: String, _ message: String) {
        emit(Line(level: .info, tag: tag, message: message))
    }

    public static func error(_ tag: String, _ message: String) {
        emit(Line(level: .error, tag: tag, message: message))
    }

    /// Hands every line from now on to `sink`, on the thread that wrote it.
    @discardableResult
    public static func addSink(_ sink: @escaping @Sendable (Line) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { sinks[id] = sink }
        return id
    }

    public static func removeSink(_ id: UUID) {
        lock.withLock { _ = sinks.removeValue(forKey: id) }
    }

    static func emit(_ line: Line) {
        let (verbose, targets) = lock.withLock { (enabled, Array(sinks.values)) }
        if verbose {
            FileHandle.standardError.write(Data("[\(line.tag)] \(line.message)\n".utf8))
        }
        for sink in targets { sink(line) }
    }
}
