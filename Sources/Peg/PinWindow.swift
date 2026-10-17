import AppKit
import CoreGraphics
import ImageIO

/// Screenshots that stay on screen. Drag to move, scroll to zoom, right click
/// for the rest. Kept above normal windows and visible on every Space.
@MainActor
final class PinController {
    static let shared = PinController()
    private var pins: [PinWindow] = []

    func pin(_ image: CGImage, at rect: CGRect) {
        let window = PinWindow(image: image, frame: rect)
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.pins.removeAll { $0 === window }
        }
        pins.append(window)
        window.orderFrontRegardless()
    }

    /// Pin whatever image is on the clipboard, centred on the active screen.
    @discardableResult
    func pinFromPasteboard() -> Bool {
        guard let image = PinController.imageFromPasteboard() else { return false }
        pinCentered(image, on: NSScreen.main)
        return true
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
        let rect = CGRect(x: visible.midX - size.width / 2,
                          y: visible.midY - size.height / 2,
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
        pins.removeAll()
    }
}

final class PinWindow: NSPanel {
    var onClose: (() -> Void)?
    private var pixelSize: NSSize
    private var scale: CGFloat = 1

    init(image: CGImage, frame: CGRect) {
        pixelSize = NSSize(width: image.width, height: image.height)
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let view = PinImageView(image: image)
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        view.onZoom = { [weak self] delta in self?.zoom(by: delta) }
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
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: bounds)
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
