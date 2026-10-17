import AppKit

/// The frozen screen plus everything that makes a snip feel direct: dimming,
/// a live rectangle, corner handles, pixel size, and a magnifier that reads the
/// real pixels underneath.
final class SelectionView: NSView {
    let shot: Shot
    private let sampler: PixelSampler?
    weak var session: SnipSession?

    private lazy var frozen = NSImage(cgImage: shot.image,
                                      size: NSSize(width: shot.image.width, height: shot.image.height))
    private var cursor: CGPoint?
    /// Set only by the demo mode, which has no real pointer to follow.
    var demoCursor: CGPoint?

    private var activeCursor: CGPoint? { cursor ?? demoCursor }

    private let dim = NSColor.black.withAlphaComponent(0.38)
    private let accent = NSColor.systemBlue

    init(shot: Shot, sampler: PixelSampler?) {
        self.shot = shot
        self.sampler = sampler
        super.init(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - View plumbing

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private func takeFocus() {
        guard let window else { return }
        if !window.isKeyWindow { window.makeKey() }
        if window.firstResponder !== self { window.makeFirstResponder(self) }
    }

    // MARK: - Events

    override func mouseMoved(with event: NSEvent) {
        takeFocus()
        cursor = convert(event.locationInWindow, from: nil)
        session?.updateHover(on: shot.screen, at: cursor ?? .zero)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        takeFocus()
    }

    override func mouseExited(with event: NSEvent) {
        cursor = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        takeFocus()
        let point = convert(event.locationInWindow, from: nil)
        cursor = point

        if let rect = session?.selection(on: shot.screen), rect.contains(point) {
            // Clicking inside an existing selection keeps it; a double click
            // takes the snip straight to the clipboard.
            if event.clickCount == 2 {
                session?.commit(.copyAndSave)
            }
            return
        }

        session?.mouseDown(on: shot.screen, at: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        session?.mouseDragged(on: shot.screen, at: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        session?.mouseUp(on: shot.screen, at: point)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        session?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        if session?.keyDown(event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.imageInterpolation = .high
        frozen.draw(in: bounds)

        dim.setFill()
        bounds.fill()

        if let selection = session?.selection(on: shot.screen) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            frozen.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()

            drawBorder(selection)
            drawSizeLabel(for: selection)
        } else if let hover = session?.windowHover, hover.width > 8, hover.height > 8 {
            // Un-dim the window under the pointer and ring it: one click grabs it.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: hover).addClip()
            frozen.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()

            let path = NSBezierPath(roundedRect: hover.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
            path.lineWidth = 2.5
            accent.withAlphaComponent(0.95).setStroke()
            path.stroke()
            drawSizeLabel(for: hover)
            drawCrosshair()
        } else {
            drawCrosshair()
            drawHint()
        }

        if activeCursor != nil, session?.allowsMagnifier(on: shot.screen) != false {
            drawMagnifier()
        }
    }

    private func drawBorder(_ rect: CGRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1
        accent.setStroke()
        path.stroke()

        // Corner ticks.
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

    private func drawSizeLabel(for rect: CGRect) {
        let w = Int((rect.width * shot.scale).rounded())
        let h = Int((rect.height * shot.scale).rounded())
        let text = "\(w) × \(h)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding = NSSize(width: 8, height: 4)
        var origin = CGPoint(x: rect.minX, y: rect.minY - size.height - padding.height * 2 - 6)
        if origin.y < 4 { origin.y = rect.minY + 6 }

        let box = CGRect(x: origin.x, y: origin.y,
                         width: size.width + padding.width * 2,
                         height: size.height + padding.height * 2)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height),
                                withAttributes: attributes)
    }

    private func drawCrosshair() {
        guard let cursor = activeCursor else { return }
        let line = NSBezierPath()
        line.lineWidth = 0.5
        line.move(to: CGPoint(x: 0, y: cursor.y + 0.25))
        line.line(to: CGPoint(x: bounds.maxX, y: cursor.y + 0.25))
        line.move(to: CGPoint(x: cursor.x + 0.25, y: 0))
        line.line(to: CGPoint(x: cursor.x + 0.25, y: bounds.maxY))
        NSColor.white.withAlphaComponent(0.55).setStroke()
        line.stroke()
    }

    private func drawHint() {
        let text = "拖拽选区　⏎ 复制并保存　空格 标注　P 贴到屏幕\nT 识别文字　L 滚动长截图　Esc 取消"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGRect(x: bounds.midX - size.width / 2 - 18,
                         y: bounds.midY - size.height / 2 - 10,
                         width: size.width + 36,
                         height: size.height + 20)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(in: box.insetBy(dx: 18, dy: 10), withAttributes: attributes)
    }

    private func drawMagnifier() {
        guard let cursor = activeCursor, let sampler else { return }

        let sourceWidth: CGFloat = 16
        let sourceHeight: CGFloat = 11
        let zoom: CGFloat = 8
        let boxSize = NSSize(width: sourceWidth * zoom, height: sourceHeight * zoom)

        var origin = CGPoint(x: cursor.x + 24, y: cursor.y + 24)
        if origin.x + boxSize.width > bounds.maxX - 8 {
            origin.x = cursor.x - boxSize.width - 24
        }
        if origin.y + boxSize.height + 56 > bounds.maxY - 8 {
            origin.y = cursor.y - boxSize.height - 24
        }
        let box = CGRect(origin: origin, size: boxSize)

        // Colour under the pointer, at pixel resolution.
        let px = Int(cursor.x * shot.scale)
        let py = Int(cursor.y * shot.scale)
        let colour = sampler.rgb(x: px, y: py)

        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8).fill()

        let halfW = sourceWidth / 2 * shot.scale
        let halfH = sourceHeight / 2 * shot.scale
        var source = CGRect(x: CGFloat(px) - halfW,
                            y: CGFloat(py) - halfH,
                            width: halfW * 2,
                            height: halfH * 2).integral
        source = source.intersection(CGRect(x: 0, y: 0,
                                            width: CGFloat(shot.image.width),
                                            height: CGFloat(shot.image.height)))
        if let crop = shot.image.cropping(to: source), source.width > 0, source.height > 0 {
            let image = NSImage(cgImage: crop, size: NSSize(width: source.width, height: source.height))
            let previous = NSGraphicsContext.current?.imageInterpolation ?? .high
            NSGraphicsContext.current?.imageInterpolation = .none
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).addClip()
            image.draw(in: box)
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = previous
        }

        // Crosshair in the middle of the magnified patch.
        let cross = NSBezierPath()
        cross.lineWidth = 1
        cross.move(to: CGPoint(x: box.midX, y: box.minY))
        cross.line(to: CGPoint(x: box.midX, y: box.maxY))
        cross.move(to: CGPoint(x: box.minX, y: box.midY))
        cross.line(to: CGPoint(x: box.maxX, y: box.midY))
        NSColor.white.withAlphaComponent(0.55).setStroke()
        cross.stroke()

        // Swatch + hex + pixel coordinate.
        let swatch = CGRect(x: box.minX, y: box.maxY + 8, width: 16, height: 16)
        if let colour {
            NSColor(srgbRed: CGFloat(colour.0) / 255,
                    green: CGFloat(colour.1) / 255,
                    blue: CGFloat(colour.2) / 255,
                    alpha: 1).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).fill()
            NSColor.white.withAlphaComponent(0.25).setStroke()
            NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).stroke()
        }

        let hex = colour.map { String(format: "#%02X%02X%02X", $0.0, $0.1, $0.2) } ?? "—"
        let label = "\(hex)   \(px), \(py)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        (label as NSString).draw(at: CGPoint(x: swatch.maxX + 7, y: swatch.minY + 2),
                                 withAttributes: attributes)
    }
}
