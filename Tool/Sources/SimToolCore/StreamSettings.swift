import Foundation

/// What a viewer's video stream is encoded at: frames a second, bits a second
/// and the picture's longest side. Fixed for the stream's life: neither the
/// link nor the screen changes them — a link slower than they need gets fewer
/// of the frames, each of them fresh (`StreamPacer`), never smaller or blurrier
/// ones.
///
/// The server's defaults come from `simtool serve --stream-fps / --stream-bitrate
/// / --stream-max-size`; a viewer may ask for its own on the stream's URL
/// (`/stream.avcc?sid=…&fps=30&kbps=3000&px=960`).
public struct StreamSettings: Codable, Equatable, Sendable {
    public var fps: Int
    /// Bits per second.
    public var bitrate: Int
    /// The picture's longest side in pixels; a screen smaller than this is
    /// sent as it is, never enlarged.
    public var maxDimension: Int

    public init(fps: Int, bitrate: Int, maxDimension: Int) {
        self.fps = fps
        self.bitrate = bitrate
        self.maxDimension = maxDimension
    }

    /// What a server streams without flags: every frame the screen makes, up
    /// to sixty a second, sharp on a near link.
    public static let standard = StreamSettings(fps: 60, bitrate: 6_000_000, maxDimension: 1280)

    public static let fpsRange = 1...60
    public static let bitrateRange = 100_000...50_000_000
    public static let maxDimensionRange = 240...4096

    /// These settings with each value brought into its range.
    public var clamped: StreamSettings {
        StreamSettings(
            fps: min(max(fps, Self.fpsRange.lowerBound), Self.fpsRange.upperBound),
            bitrate: min(max(bitrate, Self.bitrateRange.lowerBound), Self.bitrateRange.upperBound),
            maxDimension: min(max(maxDimension, Self.maxDimensionRange.lowerBound), Self.maxDimensionRange.upperBound)
        )
    }

    /// These settings with what a viewer asked for on the stream's URL over
    /// them — `fps`, `kbps`, `px`, each optional — brought into range. A value
    /// that is not a whole number is ignored.
    public func overridden(fps: String?, kbps: String?, px: String?) -> StreamSettings {
        var result = self
        if let value = fps.flatMap({ Int($0) }) { result.fps = value }
        if let value = kbps.flatMap({ Int($0) }), value <= Int.max / 1000 { result.bitrate = value * 1000 }
        if let value = px.flatMap({ Int($0) }) { result.maxDimension = value }
        return result.clamped
    }

    /// `6M`, `1.5M`, `800k`, `800K`, `6000000` → bits per second; nil for
    /// anything else.
    public static func parseBitrate(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return nil }
        let multiplier: Double
        let number: Substring
        switch last {
        case "k", "K": multiplier = 1_000; number = trimmed.dropLast()
        case "m", "M": multiplier = 1_000_000; number = trimmed.dropLast()
        default: multiplier = 1; number = Substring(trimmed)
        }
        guard !number.isEmpty, number.allSatisfy({ $0.isNumber || $0 == "." }),
              let value = Double(number), value.isFinite, value > 0 else { return nil }
        let bits = value * multiplier
        guard bits < Double(Int.max) else { return nil }
        return Int(bits.rounded())
    }

    /// `6 Mbit/s`, `800 kbit/s`.
    public static func describeBitrate(_ bitrate: Int) -> String {
        if bitrate >= 1_000_000 {
            let megabits = Double(bitrate) / 1_000_000
            return (megabits == megabits.rounded() ? String(Int(megabits)) : String(format: "%.1f", megabits)) + " Mbit/s"
        }
        return "\(bitrate / 1000) kbit/s"
    }

    /// `60 fps, 6 Mbit/s, 1280 px`.
    public var summary: String {
        "\(fps) fps, \(Self.describeBitrate(bitrate)), \(maxDimension) px"
    }
}
