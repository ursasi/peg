import AppKit

/// The frame Peg draws around a live selection. Snip, annotate, scroll capture
/// and the GIF recorder all wear the same outline, so the gesture reads the
/// same whichever mode started it.
enum FrameStyle {
    static let accent = NSColor.systemBlue

    /// A hairline box with heavier ticks at the corners. The ticks make the
    /// frame readable over busy wallpaper without turning it into a solid bar.
    static func draw(in rect: CGRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1
        accent.setStroke()
        path.stroke()

        let arm: CGFloat = 12
        let tick = NSBezierPath()
        tick.lineWidth = 2
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)
        ]
        for (point, dx, dy) in corners {
            tick.move(to: CGPoint(x: point.x + dx * arm, y: point.y))
            tick.line(to: point)
            tick.line(to: CGPoint(x: point.x, y: point.y + dy * arm))
        }
        accent.setStroke()
        tick.stroke()
    }
}
