import CoreGraphics
import Foundation
import ImageIO

/// Where an accessibility tree's frames lie on the screen SimTool touches —
/// the picture in points, as `simtool input` and the viewer read it.
///
/// AXe reports each process's frames in that process's own space. On a phone
/// that is the screen. On an iPhone Duo it is not, two ways:
///
/// - An app built against an older SDK runs in a compatibility window: on the
///   inner panel a portrait window in the middle of the landscape picture
///   (469 × 669 of 951 × 669), on the cover a narrower one at its leading edge
///   with the system strip beside it (386 × 678 of 466 × 678). Its frames start
///   at the window's corner, so a tap by id landed 241 pt left of the element.
/// - SpringBoard lays out its own elements — alerts, the home screen — on the
///   panel as it scans out: the inner panel upright, while its picture shows
///   it on its side. A tap on an alert's button landed on another button.
///
/// Both are moved onto the picture here, before anything matches or taps.
public struct AccessibilityScreenSpace: Equatable, Sendable {
    /// The picture in points.
    public var screen: CGSize
    /// How the picture is turned on its panel (`SimulatorDisplayRotation`).
    public var rotation: Int
    /// `cover` or `inner`: where a compatibility window sits when the picture
    /// cannot tell.
    public var role: String?

    public init(screen: CGSize, rotation: Int, role: String?) {
        self.screen = screen
        self.rotation = SimulatorDisplayRotation.normalized(rotation)
        self.role = role
    }

    /// The panel as it scans out, in points.
    var panel: CGSize {
        SimulatorDisplayRotation.isQuarterTurn(rotation) ? CGSize(width: screen.height, height: screen.width) : screen
    }

    /// The tree on the picture. `windowOrigin` places a compatibility window of
    /// the given size, nil when it cannot tell — then the window sits where the
    /// device puts it: in the middle of the inner panel, at the cover's leading
    /// edge.
    public func place(_ tree: AccessibilityTreePayload, windowOrigin: (AccessibilityNode, CGSize) -> CGPoint?) -> AccessibilityTreePayload {
        AccessibilityTreePayload(roots: tree.roots.map { root in
            if laysOutOnThePanel(root) { return root.mapFrames(turnedOntoThePicture) }
            guard let size = compatibilityWindow(root) else { return root }
            let origin = windowOrigin(root, size) ?? fallbackOrigin(of: size)
            return root.mapFrames { $0.offsetBy(dx: origin.x, dy: origin.y) }
        })
    }

    /// SpringBoard's tree, on a picture turned a quarter: a group the size of
    /// the upright panel near its root.
    func laysOutOnThePanel(_ root: AccessibilityNode) -> Bool {
        guard SimulatorDisplayRotation.isQuarterTurn(rotation) else { return false }
        func panelSized(_ node: AccessibilityNode, depth: Int) -> Bool {
            if let frame = node.frame?.rect, abs(frame.minX) < 1, abs(frame.minY) < 1,
               abs(frame.width - panel.width) < 1, abs(frame.height - panel.height) < 1 { return true }
            return depth < 2 && node.children.contains { panelSized($0, depth: depth + 1) }
        }
        return panelSized(root, depth: 0)
    }

    /// The size of an app's compatibility window: its root framed at the
    /// corner, smaller than the picture.
    func compatibilityWindow(_ root: AccessibilityNode) -> CGSize? {
        guard let frame = root.frame?.rect, abs(frame.minX) < 1, abs(frame.minY) < 1,
              frame.width > 0, frame.height > 0,
              frame.width <= screen.width + 1, frame.height <= screen.height + 1,
              frame.width < screen.width - 1 || frame.height < screen.height - 1 else { return nil }
        return frame.size
    }

    func fallbackOrigin(of window: CGSize) -> CGPoint {
        CGPoint(x: role == "cover" ? 0 : ((screen.width - window.width) / 2).rounded(), y: ((screen.height - window.height) / 2).rounded())
    }

    /// A rect of the upright panel on the picture: turned 90° clockwise, the
    /// panel's bottom-left corner is the picture's top-left.
    func turnedOntoThePicture(_ rect: CGRect) -> CGRect {
        switch rotation {
        case 90: CGRect(x: panel.height - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 180: CGRect(x: panel.width - rect.maxX, y: panel.height - rect.maxY, width: rect.width, height: rect.height)
        case 270: CGRect(x: rect.minY, y: panel.width - rect.maxX, width: rect.height, height: rect.width)
        default: rect
        }
    }

    /// Where a window of `window` points sits on `image`, a picture of `screen`
    /// points: the one place — the middle, the leading or the trailing edge,
    /// along each side it is shorter — that leaves the rest of the picture
    /// black. Nil when that does not single one out (an app as dark as the
    /// bars around it).
    public static func windowOrigin(in image: CGImage, screen: CGSize, window: CGSize) -> CGPoint? {
        guard screen.width > 0, screen.height > 0, let pixels = Pixels(image, width: 320) else { return nil }
        let toPixels = Double(pixels.width) / screen.width
        func places(_ length: CGFloat, _ room: CGFloat) -> [CGFloat] {
            room - length < 1 ? [0] : Array(Set([0, ((room - length) / 2).rounded(), room - length]))
        }
        var verdicts: [(origin: CGPoint, inside: Double)] = []
        for x in places(window.width, screen.width) {
            for y in places(window.height, screen.height) {
                let rect = CGRect(x: x, y: y, width: window.width, height: window.height)
                var outside = 0, dark = 0, edge = 0, lit = 0
                // The middle band only: the status bar and the home indicator sit on the bars.
                for py in stride(from: Int(Double(pixels.height) * 0.3), to: Int(Double(pixels.height) * 0.8), by: 2) {
                    for px in stride(from: 0, to: pixels.width, by: 2) {
                        let point = CGPoint(x: Double(px) / toPixels, y: Double(py) / toPixels)
                        if !rect.insetBy(dx: -2, dy: -2).contains(point) {
                            outside += 1
                            if pixels.isBlack(px, py) { dark += 1 }
                        } else if rect.insetBy(dx: 2, dy: 2).contains(point),
                                  point.x - rect.minX < window.width * 0.08 || rect.maxX - point.x < window.width * 0.08 {
                            edge += 1
                            if !pixels.isBlack(px, py) { lit += 1 }
                        }
                    }
                }
                guard outside == 0 || Double(dark) / Double(outside) >= 0.97 else { continue }
                verdicts.append((CGPoint(x: x, y: y), edge == 0 ? 0 : Double(lit) / Double(edge)))
            }
        }
        if verdicts.count == 1 { return verdicts[0].origin }
        let ranked = verdicts.sorted { $0.inside > $1.inside }
        guard ranked.count > 1, ranked[0].inside >= 0.3, ranked[0].inside - ranked[1].inside >= 0.2 else { return nil }
        return ranked[0].origin
    }

    /// A picture shrunk to `width` pixels, read as RGBA.
    struct Pixels {
        let width: Int, height: Int
        private let data: [UInt8]

        init?(_ image: CGImage, width: Int) {
            let width = min(width, image.width)
            let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            self.data = data
        }

        /// x, y from the top-left.
        func isBlack(_ x: Int, _ y: Int) -> Bool {
            let index = (y * width + x) * 4
            return max(data[index], data[index + 1], data[index + 2]) <= 12
        }
    }
}

extension AccessibilityFrame {
    var rect: CGRect? {
        guard let x, let y, let width, let height else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension AccessibilityNode {
    func mapFrames(_ transform: (CGRect) -> CGRect) -> AccessibilityNode {
        var node = self
        if let rect = frame?.rect {
            let moved = transform(rect)
            node.frame = AccessibilityFrame(x: moved.minX, y: moved.minY, width: moved.width, height: moved.height)
        }
        node.children = children.map { $0.mapFrames(transform) }
        return node
    }
}

/// Puts a device's accessibility trees on its picture: a one-screen device's
/// as they come, a foldable's through `AccessibilityScreenSpace`. Reads the
/// device type once, the lit panel as touches do, and a compatibility window's
/// place once per app process and panel, from a screenshot.
public actor AccessibilityScreenSpaceResolver {
    public static let shared = AccessibilityScreenSpaceResolver()

    private var layouts: [String: SimulatorDisplayLayout?] = [:]
    private var windows: [String: CGPoint?] = [:]

    public init() {}

    public func onScreen(_ tree: AccessibilityTreePayload, deviceUDID: String) async -> AccessibilityTreePayload {
        guard let layout = await layout(deviceUDID: deviceUDID), layout.isFoldable,
              let state = try? await SimulatorDirectInputClient.shared.displayState(deviceUDID: deviceUDID, layout: layout),
              let display = layout.display(named: state.active) else { return tree }
        let rotation = state.rotation(of: display.id)
        let points = display.points(rotation: rotation)
        let space = AccessibilityScreenSpace(screen: CGSize(width: points.width, height: points.height), rotation: rotation, role: display.role)
        var origins: [AccessibilityNode.ID: CGPoint?] = [:]
        for root in tree.roots {
            guard let window = space.compatibilityWindow(root), !space.laysOutOnThePanel(root) else { continue }
            let key = [deviceUDID, display.id, String(rotation), "\(window.width)x\(window.height)", String(root.pid ?? 0)].joined(separator: "|")
            if let known = windows[key] {
                origins[root.id] = known
                continue
            }
            let found = await Self.windowOrigin(deviceUDID: deviceUDID, display: display, space: space, window: window)
            // Only a place the picture told is kept: a guess is tried again next time.
            if found != nil { windows[key] = found }
            origins[root.id] = found
        }
        return space.place(tree) { root, _ in origins[root.id] ?? nil }
    }

    private static func windowOrigin(deviceUDID: String, display: SimulatorDisplay, space: AccessibilityScreenSpace, window: CGSize) async -> CGPoint? {
        guard let png = try? await SimulatorScreenshotClient.png(deviceUDID: deviceUDID, display: display.id),
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // A picture of the panel before the fold settled is not this one.
        guard (image.width > image.height) == (space.screen.width > space.screen.height) else { return nil }
        return AccessibilityScreenSpace.windowOrigin(in: image, screen: space.screen, window: window)
    }

    /// Read once a device is found; a failed read is tried again next time.
    private func layout(deviceUDID: String) async -> SimulatorDisplayLayout? {
        if let known = layouts[deviceUDID] { return known }
        guard let device = try? await SimulatorDeviceClient.listDevices().first(where: { $0.udid == deviceUDID }) else { return nil }
        var layout: SimulatorDisplayLayout?
        if let type = device.deviceTypeIdentifier { layout = await SimulatorDisplayLayout.load(deviceType: type) }
        layouts[deviceUDID] = .some(layout)
        return layout
    }
}
