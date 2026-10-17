import AppKit

/// Hover preview: the shot, enlarged, next to the card it belongs to.
@MainActor
final class PreviewPanel {
    static let shared = PreviewPanel()

    private var panel: NSPanel?
    private var imageView: NSImageView?
    private var hideWork: DispatchWorkItem?

    func show(_ image: NSImage, near rect: CGRect, on screen: NSScreen) {
        hideWork?.cancel()

        let visible = screen.visibleFrame
        let maxWidth = visible.width * 0.62
        let maxHeight = visible.height * 0.62
        let source = image.size
        guard source.width > 0, source.height > 0 else { return }
        let factor = min(maxWidth / source.width, maxHeight / source.height, 1.4)
        let size = NSSize(width: (source.width * factor).rounded(),
                          height: (source.height * factor).rounded())

        // Below the card, or above it when there is no room.
        var origin = NSPoint(x: rect.midX - size.width / 2,
                             y: rect.minY - size.height - 12)
        if origin.y < visible.minY + 12 {
            origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + 12)
        }
        origin.x = min(max(visible.minX + 12, origin.x), visible.maxX - size.width - 12)
        origin.y = min(max(visible.minY + 12, origin.y), visible.maxY - size.height - 12)
        let target = CGRect(origin: origin, size: size)

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let inset: CGFloat = 6
        if let view = imageView {
            view.image = image
            view.frame = NSRect(x: inset, y: inset,
                                width: size.width - inset * 2,
                                height: size.height - inset * 2)
        }

        // Scale up from slightly smaller while fading in.
        let start = target.insetBy(dx: size.width * 0.04, dy: size.height * 0.04)
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
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

        let root = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let view = NSImageView(frame: root.bounds)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        root.addSubview(view)
        imageView = view

        panel.contentView = root
        return panel
    }
}
