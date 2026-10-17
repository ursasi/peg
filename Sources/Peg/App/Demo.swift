import AppKit
import CoreGraphics

/// A stand-in frozen screen, used by `PEG_DEMO=overlay` to review the selection
/// UI without needing the Screen Recording permission.
enum DemoImage {
    static func make(size: CGSize, scale: CGFloat) -> CGImage {
        let width = max(1, Int(size.width * scale))
        let height = max(1, Int(size.height * scale))
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        // Background wash.
        let colors = [CGColor(red: 0.10, green: 0.13, blue: 0.20, alpha: 1),
                      CGColor(red: 0.25, green: 0.36, blue: 0.52, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero,
                               end: CGPoint(x: CGFloat(width), y: CGFloat(height)),
                               options: [])

        // Grid.
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
        ctx.setLineWidth(1)
        for x in stride(from: 0, to: width, by: 48) {
            ctx.move(to: CGPoint(x: CGFloat(x), y: 0))
            ctx.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(height)))
        }
        for y in stride(from: 0, to: height, by: 48) {
            ctx.move(to: CGPoint(x: 0, y: CGFloat(y)))
            ctx.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(y)))
        }
        ctx.strokePath()

        // Bars that read like text, so the magnifier and the pixel readout have
        // something with edges to show.
        let palette: [CGColor] = [
            CGColor(red: 0.98, green: 0.82, blue: 0.35, alpha: 1),
            CGColor(red: 0.55, green: 0.85, blue: 0.95, alpha: 1),
            CGColor(red: 0.95, green: 0.55, blue: 0.60, alpha: 1),
            CGColor(red: 0.65, green: 0.95, blue: 0.70, alpha: 1)
        ]
        for row in 0..<18 {
            let y = 90 + row * 52
            var x = 120
            var index = row
            while x < width - 160 {
                let w = 60 + ((row * 37 + index * 53) % 190)
                ctx.setFillColor(palette[index % palette.count])
                ctx.fill(CGRect(x: x, y: y, width: w, height: 14))
                x += w + 22
                index += 1
                if index > 900 { break }
            }
        }

        return ctx.makeImage()!
    }
}
