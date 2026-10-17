import AppKit

/// A pinned piece of text: what you get when the clipboard holds words instead
/// of a picture. Drag to move, scroll to change the type size, right click for
/// the rest. Styled like a pinned screenshot so the two read as the same thing.
final class PinTextWindow: NSPanel {
    static let padding: CGFloat = 14
    private static let maxWidth: CGFloat = 460

    var onClose: (() -> Void)?
    private let text: String
    private let surface: PinTextSurface
    private var fontSize: CGFloat = 14

    /// Size the window wants before it is placed on screen.
    var documentSize: NSSize {
        let body = surface.intrinsicSize(forWidth: Self.maxWidth, fontSize: fontSize)
        return NSSize(width: body.width + Self.padding * 2,
                      height: body.height + Self.padding * 2)
    }

    init(text: String) {
        self.text = text
        surface = PinTextSurface(text: text, fontSize: 14)
        let size = NSSize(width: Self.maxWidth, height: 120)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        surface.onZoom = { [weak self] delta in
            guard let self else { return }
            PinController.shared.noteZoom { [weak self] in self?.zoom(by: $0) }
            self.zoom(by: delta)
        }
        surface.onCloseWindow = { [weak self] in self?.close() }
        surface.onCopy = { [weak self] in
            guard let self else { return }
            Clip.copy(self.text)
        }
        contentView = surface
        setContentSize(documentSize)
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
            return
        }
        super.keyDown(with: event)
    }

    private func zoom(by delta: CGFloat) {
        guard delta != 0 else { return }
        let next = min(max(fontSize * (delta > 0 ? 1.08 : 0.92), 9), 40)
        guard next != fontSize else { return }
        let oldFrame = frame
        fontSize = next
        surface.fontSize = next
        let size = documentSize
        // Grow around the centre so the text does not jump away from the eye.
        let origin = CGPoint(x: oldFrame.midX - size.width / 2,
                             y: oldFrame.midY - size.height / 2)
        setFrame(CGRect(origin: origin, size: size), display: true)
        surface.needsDisplay = true
    }
}

/// Draws the card and hosts the selectable text. An NSTextView is used so the
/// user can select and copy out of the pin, which is half the point of pasting
/// a terminal dump.
final class PinTextSurface: NSView {
    var onZoom: ((CGFloat) -> Void)?
    var onCopy: (() -> Void)?
    var onCloseWindow: (() -> Void)?

    private let textView = NSTextView()
    private let text: String
    var fontSize: CGFloat {
        didSet { applyFont() }
    }

    init(text: String, fontSize: CGFloat) {
        self.text = text
        self.fontSize = fontSize
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        applyFont()
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private func applyFont() {
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor(calibratedWhite: 0.12, alpha: 1)
    }

    /// Height the text needs at a given width.
    func intrinsicSize(forWidth width: CGFloat, fontSize: CGFloat) -> NSSize {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes)
        let lines = max(1, ceil(bounding.height / font.ascender))
        let height = min(bounding.height + 4, max(60, lines * font.ascender + 8))
        return NSSize(width: width, height: max(48, height))
    }

    override func layout() {
        super.layout()
        textView.frame = bounds.insetBy(dx: PinTextWindow.padding, dy: PinTextWindow.padding)
    }

    override func draw(_ dirtyRect: NSRect) {
        let content = bounds.insetBy(dx: PinTextWindow.padding, dy: PinTextWindow.padding)
        let radius: CGFloat = 10

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
        NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius).fill()
        NSShadow().set()

        let outer = NSBezierPath(roundedRect: content.insetBy(dx: -0.5, dy: -0.5),
                                 xRadius: radius + 0.5, yRadius: radius + 0.5)
        outer.lineWidth = 1
        NSColor.white.withAlphaComponent(0.3).setStroke()
        outer.stroke()

        let edge = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)
        edge.lineWidth = 1
        NSColor.black.withAlphaComponent(0.2).setStroke()
        edge.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            onCloseWindow?()
            return
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onZoom?(event.scrollingDeltaY)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let copy = ClosureMenuItem(title: "复制文字") { [weak self] in self?.onCopy?() }
        menu.addItem(copy)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "关闭") { [weak self] in self?.onCloseWindow?() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
