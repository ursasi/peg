import AppKit

/// Hover preview: the shot, enlarged, next to the card it belongs to.
@MainActor
final class PreviewPanel {
    static let shared = PreviewPanel()

    private var panel: NSPanel?
    private var content: PreviewContentView?
    private var hideWork: DispatchWorkItem?

    func show(_ image: NSImage, near rect: CGRect, on screen: NSScreen) {
        hideWork?.cancel()

        let visible = screen.visibleFrame
        // Keep the preview small enough that the line above it stays visible:
        // a sheet filling half the display reads as a stray window.
        let maxWidth = visible.width * 0.5
        let maxHeight = visible.height * 0.45
        let source = image.size
        guard source.width > 0, source.height > 0 else { return }

        // Fit inside the allowed box, never enlarged past 1:1.
        let factor = min(maxWidth / source.width, maxHeight / source.height, 1)
        let size = NSSize(width: (source.width * factor).rounded() + 12,
                          height: (source.height * factor).rounded() + 12)

        // Below the card, or above it when there is no room.
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)
        var enterFromAbove = false
        if origin.y < visible.minY + 12 {
            origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + 10)
            enterFromAbove = true
        }
        origin.x = min(max(visible.minX + 12, origin.x), visible.maxX - size.width - 12)
        // Never creep up into the line itself, or the preview covers the very
        // sheet the pointer is on.
        let lineBottom = visible.maxY - ShelfContentView.height
        origin.y = min(max(visible.minY + 12, origin.y), lineBottom - size.height - 10)
        let target = CGRect(origin: origin, size: size)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        content?.image = image

        // The window is placed at its final size straight away, so the image is
        // laid out once. Only alpha and position animate — resizing the window
        // while the image view catches up is what made the first frame show a
        // cropped, wrongly scaled picture.
        let slide: CGFloat = enterFromAbove ? 8 : -8
        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: slide), display: false)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        guard let panel else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { panel.orderOut(nil) }
            })
        }
        hideWork = work
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work.perform()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = PreviewContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        content = view
        panel.contentView = view
        return panel
    }
}

/// Draws the picture itself instead of relying on NSImageView's scaling, which
/// painted the image at its natural size for the first frame after a resize.
final class PreviewContentView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    // Deliberately *not* flipped: NSImage draws top-row-first only in an
    // unflipped view, and a flipped one renders the picture upside down.
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.10, alpha: 0.96).setFill()
        rounded.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        rounded.lineWidth = 1
        rounded.stroke()

        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let box = bounds.insetBy(dx: 6, dy: 6)
        let aspect = image.size.width / image.size.height
        var rect = box
        if box.width / box.height > aspect {
            rect.size.width = box.height * aspect
            rect.origin.x = box.minX + (box.width - rect.width) / 2
        } else {
            rect.size.height = box.width / aspect
            rect.origin.y = box.minY + (box.height - rect.height) / 2
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}
