import AppKit

/// The app mark: a pinned sheet of paper on a slate plate.
///
/// Everything is laid out in a 1024×1024 design space and scaled by the
/// destination rect with plain arithmetic — no CTM tricks, so it renders the
/// same at 400px and at 1024px. Shared by the icon and banner generators.
enum PegMark {
    static func draw(in rect: NSRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let s = rect.width / 1024
        let o = rect.origin

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: o.x + x * s, y: o.y + y * s)
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: o.x + x * s, y: o.y + y * s, width: w * s, height: h * s)
        }

        // Everything below is clipped to the plate, so the caller's state has to
        // be restored or later drawing gets cropped too.
        NSGraphicsContext.saveGraphicsState()

        // Slate plate.
        let plate = NSBezierPath(roundedRect: box(96, 96, 832, 832),
                                 xRadius: 186 * s, yRadius: 186 * s)
        plate.addClip()
        NSGradient(colors: [
            NSColor(calibratedRed: 0.33, green: 0.38, blue: 0.47, alpha: 1),
            NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.22, alpha: 1)
        ])!.draw(in: box(96, 96, 832, 832), angle: -90)

        // Sheet of paper.
        let sheet = box(262, 212, 500, 600)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 46 * s
        shadow.shadowOffset = NSSize(width: 0, height: -18 * s)
        shadow.set()
        NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
        NSBezierPath(roundedRect: sheet, xRadius: 34 * s, yRadius: 34 * s).fill()
        NSShadow().set()

        // Lines of text on the sheet.
        NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
        for (index, width) in [310, 240, 170].enumerated() {
            let y = 662 - CGFloat(index) * 92
            NSBezierPath(roundedRect: box(326, y, CGFloat(width), 34),
                         xRadius: 17 * s, yRadius: 17 * s).fill()
        }

        // The peg, biting the top edge.
        let knob = box(438, 738, 148, 148)
        let knobShadow = NSShadow()
        knobShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        knobShadow.shadowBlurRadius = 26 * s
        knobShadow.shadowOffset = NSSize(width: 0, height: -8 * s)
        knobShadow.set()
        NSGradient(colors: [
            NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.38, alpha: 1),
            NSColor(calibratedRed: 0.80, green: 0.16, blue: 0.18, alpha: 1)
        ])!.draw(in: NSBezierPath(ovalIn: knob), angle: -70)
        NSShadow().set()

        NSColor.white.withAlphaComponent(0.4).setFill()
        NSBezierPath(ovalIn: box(472, 790, 46, 34)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
