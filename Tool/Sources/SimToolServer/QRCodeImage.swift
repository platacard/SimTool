import CoreImage
import Foundation

/// A QR code as a PNG, sharp at any size: each module scaled up without
/// smoothing. The page around it keeps the quiet zone a camera needs.
enum QRCodeImage {
    static func png(for text: String, scale: CGFloat = 8) -> Data? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        let scaled = code.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.pngRepresentation(of: scaled, format: .RGBA8, colorSpace: space)
    }
}
