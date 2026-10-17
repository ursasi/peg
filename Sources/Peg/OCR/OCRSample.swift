import AppKit

enum OCRSample {
    /// A small rendered "screenshot" of text, for the demo mode and the
    /// headless OCR check.
    static func image(_ text: String, width: Int = 720, height: Int = 200) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 72, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(in: CGRect(x: 30, y: 50, width: width - 60, height: height - 80),
                                withAttributes: attributes)
        NSGraphicsContext.current = previous
        return context.makeImage()
    }
}
