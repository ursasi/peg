import AppKit

/// Hover preview: the shot, enlarged, next to the card it belongs to.
@MainActor
final class PreviewPanel {
    static let shared = PreviewPanel()

    /// Room around the picture for the shadow that replaces the old card.
    static let padding: CGFloat = 12

    private var panel: NSPanel?
    private var content: PreviewContentView?
    private var hideWork: DispatchWorkItem?
    /// Bumped by every show and hide, so a hide that was already running when a
    /// new preview arrives cannot order out the panel the show just put up.
    private var generation = 0

    func show(_ image: NSImage, url: URL, near rect: CGRect, on screen: NSScreen) {
        generation += 1
        hideWork?.cancel()
        hideWork = nil

        let visible = screen.visibleFrame
        // Keep the preview small enough that the line above it stays visible:
        // a sheet filling half the display reads as a stray window.
        let maxWidth = visible.width * 0.5
        let maxHeight = visible.height * 0.45
        let source = image.size
        guard source.width > 0, source.height > 0 else { return }

        // Fit inside the allowed box, never enlarged past 1:1.
        let factor = min(maxWidth / source.width, maxHeight / source.height, 1)
        let size = NSSize(width: (source.width * factor).rounded() + Self.padding * 2,
                          height: (source.height * factor).rounded() + Self.padding * 2)

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
        content?.show(url: url, still: image)

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

    /// The pointer moved to another sheet: keep the panel up instead of letting
    /// the hide that leaving the previous sheet scheduled run in between.
    func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        guard self.panel != nil else { return }
        generation += 1
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            guard token == self.generation else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    // A preview that arrived while the fade was running wins;
                    // ordering the panel out here is what kept every sheet but
                    // the first one from previewing when moving along the line.
                    guard token == self.generation else { return }
                    panel.orderOut(nil)
                }
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
        panel.hasShadow = false
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
    private var image: NSImage?
    private var frames: [CGImage] = []
    private var frameDelays: [Double] = []
    private var frameIndex = 0
    private var frameTimer: Timer?

    /// A GIF plays here; anything else is a still.
    func show(url: URL, still: NSImage) {
        stopAnimation()
        image = still
        frameIndex = 0
        needsDisplay = true

        guard GIFFile.isAnimated(url) else { return }
        let (frames, delays) = GIFFile.cachedFrames(url)
        guard frames.count > 1 else { return }
        self.frames = frames
        frameDelays = delays
        scheduleNextFrame()
    }

    private func scheduleNextFrame() {
        frameTimer?.invalidate()
        guard !frames.isEmpty else { return }
        let delay = frameIndex < frameDelays.count ? frameDelays[frameIndex] : 0.1
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.frames.isEmpty else { return }
                self.frameIndex = (self.frameIndex + 1) % self.frames.count
                self.needsDisplay = true
                self.scheduleNextFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopAnimation() {
        frameTimer?.invalidate()
        frameTimer = nil
        frames = []
        frameDelays = []
    }


    // Deliberately *not* flipped: NSImage draws top-row-first only in an
    // unflipped view, and a flipped one renders the picture upside down.
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let current: NSImage? = {
            if !frames.isEmpty, frameIndex < frames.count {
                let frame = frames[frameIndex]
                return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
            return image
        }()
        guard let image = current, image.size.width > 0, image.size.height > 0 else { return }
        let box = bounds.insetBy(dx: PreviewPanel.padding, dy: PreviewPanel.padding)
        let aspect = image.size.width / image.size.height
        var rect = box
        if box.width / box.height > aspect {
            rect.size.width = box.height * aspect
            rect.origin.x = box.minX + (box.width - rect.width) / 2
        } else {
            rect.size.height = box.width / aspect
            rect.origin.y = box.minY + (box.height - rect.height) / 2
        }

        // Nothing is painted behind the picture. A screenshot with rounded
        // corners carries its own transparency, and on a near-black card those
        // corners read as black wedges; the card's edge read as a black frame
        // around the whole preview. A shadow alone lifts the picture off what is
        // behind it, the same way a pin does.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSShadow().set()
    }
}
