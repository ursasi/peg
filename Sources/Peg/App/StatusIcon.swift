import AppKit

/// Menu-bar mark: a sheet of paper with a peg on top, drawn as a template so
/// macOS tints it for light and dark menu bars. Matches the app icon instead of
/// borrowing a system symbol.
enum StatusIcon {
    static func make(height: CGFloat = 17) -> NSImage {
        let width = (height * 0.82).rounded()
        // Draw into a concrete bitmap: a lazy NSImage can fail to rasterise in
        // the status bar and leaves an invisible, zero-width item.
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(width * scale),
                                   pixelsHigh: Int(height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        NSColor.black.setFill()
        let rect = NSRect(x: 0, y: 0, width: width, height: height)

        // Sheet: a rounded card in the lower two thirds.
        let inset = width * 0.14
        let sheet = NSRect(x: inset, y: height * 0.06,
                           width: width - inset * 2, height: height * 0.64)
        NSBezierPath(roundedRect: sheet, xRadius: width * 0.13, yRadius: width * 0.13).fill()

        // Peg: a small round head above the sheet with a short shank.
        let headDiameter = width * 0.34
        let head = NSRect(x: (width - headDiameter) / 2,
                          y: height * 0.70,
                          width: headDiameter, height: headDiameter)
        NSBezierPath(ovalIn: head).fill()
        let shank = NSRect(x: width * 0.465, y: height * 0.64,
                           width: width * 0.07, height: height * 0.10)
        NSBezierPath(rect: shank).fill()

        // Two cut-outs read as lines of text at this size.
        context.cgContext.setBlendMode(.clear)
        for (index, factor) in [0.62, 0.44].enumerated() {
            let bar = NSRect(x: sheet.minX + width * 0.14,
                             y: sheet.maxY - height * (0.20 + CGFloat(index) * 0.15),
                             width: (sheet.width - width * 0.28) * factor,
                             height: max(1, height * 0.07))
            NSBezierPath(roundedRect: bar, xRadius: height * 0.035, yRadius: height * 0.035).fill()
        }
        context.cgContext.setBlendMode(.normal)

        NSGraphicsContext.restoreGraphicsState()
        _ = rect

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}
