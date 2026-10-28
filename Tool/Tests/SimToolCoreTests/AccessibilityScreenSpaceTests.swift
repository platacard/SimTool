import CoreGraphics
@testable import SimToolCore
import XCTest

/// An iPhone Duo's accessibility frames, put where a tap lands. Measured on
/// Xcode 27.2: an app built with the 27.0 SDK runs in a 469 × 669 window in
/// the middle of the open panel's 951 × 669 picture and in a 386 × 678 one at
/// the cover's leading edge; SpringBoard reports the open panel upright
/// (669 × 951) while its picture shows it on its side.
final class AccessibilityScreenSpaceTests: XCTestCase {
    private let inner = AccessibilityScreenSpace(screen: CGSize(width: 951, height: 669), rotation: 90, role: "inner")
    private let cover = AccessibilityScreenSpace(screen: CGSize(width: 466, height: 678), rotation: 0, role: "cover")

    private func node(_ id: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double, pid: Int = 1, children: [AccessibilityNode] = []) -> AccessibilityNode {
        AccessibilityNode(id: id, accessibilityIdentifier: id, pid: pid, frame: AccessibilityFrame(x: x, y: y, width: width, height: height), children: children)
    }

    private func frame(_ tree: AccessibilityTreePayload, _ id: String) -> [Double]? {
        func find(_ node: AccessibilityNode) -> AccessibilityNode? {
            node.accessibilityIdentifier == id ? node : node.children.lazy.compactMap(find).first
        }
        guard let found = tree.roots.lazy.compactMap(find).first, let rect = found.frame?.rect else { return nil }
        return [rect.minX, rect.minY, rect.width, rect.height]
    }

    func testAnAppInACompatibilityWindowIsMovedToWhereTheWindowIs() {
        let app = node("app", 0, 0, 469, 669, children: [node("HomeScreen-ProfileWidget", 0, 88, 449, 56)])
        let placed = inner.place(AccessibilityTreePayload(roots: [app])) { _, size in
            XCTAssertEqual(size, CGSize(width: 469, height: 669))
            return CGPoint(x: 241, y: 0)
        }
        XCTAssertEqual(frame(placed, "HomeScreen-ProfileWidget"), [241, 88, 449, 56], "a tap at its centre lands at 465.5, not 224.5")
    }

    func testWithoutAWordFromThePictureTheWindowSitsWhereTheDevicePutsIt() {
        let innerApp = node("app", 0, 0, 469, 669, children: [node("button", 10, 10, 20, 20)])
        XCTAssertEqual(frame(inner.place(AccessibilityTreePayload(roots: [innerApp])) { _, _ in nil }, "button"), [251, 10, 20, 20], "the middle of the open panel")
        let coverApp = node("app", 0, 0, 386, 678, children: [node("button", 10, 10, 20, 20)])
        XCTAssertEqual(frame(cover.place(AccessibilityTreePayload(roots: [coverApp])) { _, _ in nil }, "button"), [10, 10, 20, 20], "the cover's leading edge")
    }

    func testSpringBoardOnTheOpenPanelIsTurnedOntoItsPicture() {
        // The ATT alert's buttons as SpringBoard reports them on the open panel.
        let springBoard = node("sb", 0, 0, 466, 678, pid: 2, children: [
            node("switcher", 0, 0, 669, 951, pid: 2),
            node("alert", 137, 315, 361, 320, pid: 2, children: [
                node("deny", 378, 331, 48, 288, pid: 2),
                node("allow", 434, 331, 48, 288, pid: 2),
            ]),
        ])
        let placed = inner.place(AccessibilityTreePayload(roots: [springBoard])) { _, _ in
            XCTFail("SpringBoard is no compatibility window")
            return nil
        }
        XCTAssertEqual(frame(placed, "switcher"), [0, 0, 951, 669])
        XCTAssertEqual(frame(placed, "deny"), [332, 378, 288, 48], "Ask App Not to Track: above Allow, as the picture shows it")
        XCTAssertEqual(frame(placed, "allow"), [332, 434, 288, 48])
    }

    func testATreeOnThePictureAlreadyStaysAsItIs() {
        let native = node("app", 0, 0, 951, 669, children: [node("button", 100, 100, 50, 50)])
        XCTAssertEqual(inner.place(AccessibilityTreePayload(roots: [native])) { _, _ in CGPoint(x: 99, y: 99) }, AccessibilityTreePayload(roots: [native]))
        let phone = AccessibilityScreenSpace(screen: CGSize(width: 402, height: 874), rotation: 0, role: nil)
        let app = node("app", 0, 0, 402, 874, children: [node("button", 1, 2, 3, 4)])
        XCTAssertEqual(phone.place(AccessibilityTreePayload(roots: [app])) { _, _ in nil }, AccessibilityTreePayload(roots: [app]))
    }

    // MARK: - the window on the picture

    /// A picture of `screen` points at 2 px a point: black, with a window of `window` lit at `origin`.
    private func picture(screen: CGSize, window: CGRect, lit: CGFloat = 0.9) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(screen.width * 2), height: Int(screen.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: screen.width * 2, height: screen.height * 2))
        context.setFillColor(CGColor(gray: lit, alpha: 1))
        // CoreGraphics counts from the bottom.
        context.fill(CGRect(x: window.minX * 2, y: (screen.height - window.maxY) * 2, width: window.width * 2, height: window.height * 2))
        // The clock in the bar: the picture tells by its middle band.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: (screen.width - 60) * 2, y: (screen.height - 40) * 2, width: 80, height: 40))
        return try XCTUnwrap(context.makeImage())
    }

    func testTheWindowIsWhereThePictureLeavesTheRestBlack() throws {
        let screen = CGSize(width: 951, height: 669), window = CGSize(width: 469, height: 669)
        let middle = try picture(screen: screen, window: CGRect(x: 241, y: 0, width: 469, height: 669))
        XCTAssertEqual(AccessibilityScreenSpace.windowOrigin(in: middle, screen: screen, window: window), CGPoint(x: 241, y: 0))
        let coverScreen = CGSize(width: 466, height: 678), coverWindow = CGSize(width: 386, height: 678)
        let leading = try picture(screen: coverScreen, window: CGRect(x: 0, y: 0, width: 386, height: 678))
        XCTAssertEqual(AccessibilityScreenSpace.windowOrigin(in: leading, screen: coverScreen, window: coverWindow), .zero)
        let trailing = try picture(screen: coverScreen, window: CGRect(x: 80, y: 0, width: 386, height: 678))
        XCTAssertEqual(AccessibilityScreenSpace.windowOrigin(in: trailing, screen: coverScreen, window: coverWindow), CGPoint(x: 80, y: 0), "the strip on the other side")
    }

    func testAnAppAsDarkAsTheBarsLeavesThePlaceToTheDevice() throws {
        let screen = CGSize(width: 951, height: 669)
        let dark = try picture(screen: screen, window: CGRect(x: 241, y: 0, width: 469, height: 669), lit: 0)
        XCTAssertNil(AccessibilityScreenSpace.windowOrigin(in: dark, screen: screen, window: CGSize(width: 469, height: 669)))
    }
}
