import AppKit
import CoreGraphics
import ImageIO

/// Screenshots that stay on screen. Drag to move, scroll to zoom, right click
/// for the rest. Kept above normal windows and visible on every Space.
@MainActor
final class PinController {
    static let shared = PinController()
    private var pins: [PinWindow] = []
    private var textPins: [PinTextWindow] = []
    private var cascade = 0
    private var historyCursor = 0
    private var lastHistoryPin = Date.distantPast
    private var scrollMonitor: Any?
    private var lastZoom: ((CGFloat) -> Void)?
    private var lastZoomTime = Date.distantPast

    func pin(_ image: CGImage, at rect: CGRect) {
        let window = PinWindow(image: image, frame: rect)
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.pins.removeAll { $0 === window }
        }
        pins.append(window)
        window.orderFrontRegardless()
    }

    /// Everything Peg copies is on the clipboard, so one command covers it:
    /// an image pins as a picture, text pins as a text card, and when the
    /// clipboard holds neither we walk back through the shots on disk.
    @discardableResult
    func pinFromPasteboard() -> Bool {
        // One walk: recent copies first, then the shots on disk that were never
        // copied. Pressing twice must not stack the same picture.
        guard let item = PinWalk.shared.next() else { return false }
        switch item {
        case .image(let data):
            guard let image = NSImage(data: data) else { return false }
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            else { return false }
            pinCentered(cgImage, on: NSScreen.main)
        case .text(let text):
            pinText(text)
        case .file(let url):
            pinFile(at: url)
        }
        return true
    }

    /// A new capture starts the walk over from the newest.
    func resetHistoryCursor() {
        historyCursor = 0
        lastHistoryPin = .distantPast
        PinWalk.shared.reset()
    }

    func pinText(_ text: String) {
        let screen = NSScreen.main
        let visible = (screen?.visibleFrame) ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = PinTextWindow(text: text)
        let size = window.documentSize
        let step = CGFloat(cascade % 6) * 22
        cascade += 1
        let origin = CGPoint(x: visible.midX - size.width / 2 + step,
                             y: visible.midY - size.height / 2 - step)
        window.setFrameOrigin(origin)
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.pins.removeAll { $0 === window }
            self.textPins.removeAll { $0 === window }
        }
        textPins.append(window)
        window.orderFrontRegardless()
    }

    static func textFromPasteboard() -> String? {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    /// Pin a file (used by the clothesline), at natural size, centred.
    func pinFile(at url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        pinCentered(image, on: NSScreen.main)
    }

    func pinCentered(_ image: CGImage, on screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let scale = (screen ?? NSScreen.main)?.backingScaleFactor ?? 2
        var size = NSSize(width: CGFloat(image.width) / scale,
                          height: CGFloat(image.height) / scale)
        // Never open a pin larger than the screen.
        let limit = NSSize(width: visible.width * 0.85, height: visible.height * 0.85)
        let factor = min(1, min(limit.width / max(1, size.width), limit.height / max(1, size.height)))
        size.width *= factor
        size.height *= factor
        // Cascade so a second and third pin do not hide the one before it.
        let step = CGFloat(cascade % 6) * 22
        cascade += 1
        let rect = CGRect(x: visible.midX - size.width / 2 + step,
                          y: visible.midY - size.height / 2 - step,
                          width: size.width,
                          height: size.height)
        pin(image, at: rect)
    }

    static func imageFromPasteboard() -> CGImage? {
        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard) {
            var rect = CGRect(origin: .zero, size: image.size)
            if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return cgImage
            }
        }
        // Fall back to a file copied in Finder.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return nil
    }

    func closeAll() {
        pins.forEach { $0.close() }
        textPins.forEach { $0.close() }
        pins.removeAll()
        textPins.removeAll()
        cascade = 0
    }

    /// Scrolling keeps zooming for a moment after the pointer slides off the
    /// picture, which is what a trackpad gesture feels like it should do: the
    /// window grows under the cursor and the cursor ends up outside it.
    func scrollMonitorInstalled() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let point = NSEvent.mouseLocation
            // Let the window itself handle the event when the pointer is on it.
            guard !self.pointerInsidePin(point) else { return event }
            guard Date().timeIntervalSince(self.lastZoomTime) < 0.7 else { return event }
            self.lastZoomTime = Date()
            self.lastZoom?(event.scrollingDeltaY)
            return nil
        }
    }

    private func pointerInsidePin(_ point: CGPoint) -> Bool {
        if pins.contains(where: { $0.frame.contains(point) }) { return true }
        return textPins.contains(where: { $0.frame.contains(point) })
    }

    /// Called by every pin after a scroll, so the monitor knows who to keep
    /// feeding when the pointer leaves.
    func noteZoom(_ target: @escaping (CGFloat) -> Void) {
        lastZoom = target
        lastZoomTime = Date()
    }
}

final class PinWindow: NSPanel {
    /// Room around the picture for the drop shadow and the corner outline.
    static let padding: CGFloat = 14

    var onClose: (() -> Void)?
    private var pixelSize: NSSize
    private var scale: CGFloat = 1

    init(image: CGImage, frame: CGRect) {
        pixelSize = NSSize(width: image.width, height: image.height)
        super.init(contentRect: frame.insetBy(dx: -Self.padding, dy: -Self.padding),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        // Our own shadow is drawn inside the view: the window shadow alone is
        // too soft to separate a white screenshot from a white background.
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let view = PinImageView(image: image)
        view.wantsLayer = true
        view.onZoom = { [weak self] delta in
            guard let self else { return }
            PinController.shared.noteZoom { [weak self] in self?.zoom(by: $0) }
            self.zoom(by: delta)
        }
        view.onCopy = { Clip.copy(image) }
        view.onCloseWindow = { [weak self] in self?.close() }
        view.onSave = {
            if let url = Storage.save(image) { Shelf.shared.insert(url) }
        }
        view.onDoubleClick = { [weak self] in self?.close() }
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // esc
            close()
            return
        }
        super.keyDown(with: event)
    }

    private func zoom(by delta: CGFloat) {
        guard delta != 0 else { return }
        let step: CGFloat = delta > 0 ? 1.08 : 0.92
        let next = min(max(scale * step, 0.2), 6)
        guard next != scale else { return }
        let ratio = next / scale
        scale = next

        var frame = self.frame
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        frame.size.width *= ratio
        frame.size.height *= ratio
        frame.origin = CGPoint(x: centre.x - frame.width / 2, y: centre.y - frame.height / 2)
        setFrame(frame, display: true)
    }
}

final class PinImageView: NSView {
    private let image: CGImage
    var onZoom: ((CGFloat) -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onCloseWindow: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let content = bounds.insetBy(dx: PinWindow.padding, dy: PinWindow.padding)
        guard content.width > 0, content.height > 0 else { return }
        let radius = max(4, min(12, content.width * 0.02))
        let shape = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)

        // The shadow comes from the picture's own alpha, so the rounded corners
        // stay transparent instead of sitting on a white plate.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: content)
        NSShadow().set()

        // Two hairlines, light outside and dark inside, so the edge shows up on
        // both a white page and a dark wallpaper.
        let outer = NSBezierPath(roundedRect: content.insetBy(dx: -0.5, dy: -0.5),
                                 xRadius: radius + 0.5, yRadius: radius + 0.5)
        outer.lineWidth = 1
        NSColor.white.withAlphaComponent(0.30).setStroke()
        outer.stroke()

        shape.lineWidth = 1
        NSColor.black.withAlphaComponent(0.28).setStroke()
        shape.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onZoom?(event.scrollingDeltaY)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(menuItem("复制") { [weak self] in self?.onCopy?() })
        menu.addItem(menuItem("保存到 Peg 文件夹") { [weak self] in self?.onSave?() })
        menu.addItem(.separator())
        menu.addItem(menuItem("关闭") { [weak self] in self?.onCloseWindow?() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func menuItem(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        return item
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
