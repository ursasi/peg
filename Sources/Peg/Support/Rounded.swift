import AppKit
import CoreGraphics

/// Screenshots come out with rounded corners: a few pixels off each corner so a
/// capture does not read as a hard rectangle when it is pasted into a document
/// or a chat. Switchable in settings; JPEG has no alpha, so it gets the corners
/// painted white instead of transparent.
enum Rounded {
    /// Radius in image pixels. Comfortably visible at 2x without eating content.
    static func radius(for image: CGImage) -> CGFloat {
        let short = min(image.width, image.height)
        return max(12, min(28, CGFloat(short) * 0.03))
    }

    static func apply(_ image: CGImage, background: CGColor? = nil) -> CGImage {
        guard Prefs.roundedCorners else { return image }
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else { return image }
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            context.setFillColor(background)
            context.fill(rect)
        }
        context.addPath(CGPath(roundedRect: rect,
                               cornerWidth: radius(for: image),
                               cornerHeight: radius(for: image),
                               transform: nil))
        context.clip()
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// A JPEG cannot carry transparency: paint the corners white first.
    static func flattenedForOpaqueFormats(_ image: CGImage) -> CGImage {
        guard Prefs.format == .jpeg, Prefs.roundedCorners else { return image }
        return apply(image, background: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    }
}
