import AppKit

/// A pinned piece of text: what you get when the clipboard holds words instead
/// of a picture. Drag to move, scroll to change the type size, right click for
/// the rest. Styled like a pinned screenshot so the two read as the same thing.
final class PinTextWindow: NSPanel {
    static let padding: CGFloat = 14

    var onClose: (() -> Void)?
    private let text: String
    private let surface: PinTextSurface
    private var fontSize: CGFloat = 14

    /// Size the window wants before it is placed on screen.
    var documentSize: NSSize {
        surface.documentSize(fontSize: fontSize)
    }

    init(text: String) {
        self.text = text
        surface = PinTextSurface(text: text, fontSize: 14)
        let size = NSSize(width: 480, height: 120)
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

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let text: String
    private let lines: [String]

    /// Room for the traffic lights at the top of the card.
    private static let titleHeight: CGFloat = 30
    private static let padding: CGFloat = 18
    private static let maxWidth: CGFloat = 900

    var fontSize: CGFloat {
        didSet { applyText() }
    }

    init(text: String, fontSize: CGFloat) {
        self.text = text
        self.lines = text.components(separatedBy: "\n")
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
        textView.isVerticallyResizable = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        addSubview(scrollView)

        applyText()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: - Metrics

    private var lineHeight: CGFloat { CodeStyle.lineHeight(size: fontSize) }

    /// Width of the widest line plus the gutter, capped so a long line wraps
    /// instead of pushing the card off the screen.
    private var contentWidth: CGFloat {
        let font = CodeStyle.font(size: fontSize)
        let widest = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(Self.maxWidth, ceil(widest) + 16)
    }

    private var gutterWidth: CGFloat {
        let font = CodeStyle.font(size: fontSize)
        let digits = max(2, String(lines.count).count)
        return ceil(("8" as NSString).size(withAttributes: [.font: font]).width) * CGFloat(digits) + 12
    }

    /// Pure measurement: it must not touch `fontSize` (whose observer redraws
    /// and re-highlights), or every zoom would highlight the text twice.
    /// Tall pastes are capped to the screen and scrolled inside the card.
    private var maxTextHeight: CGFloat {
        ((NSScreen.main?.visibleFrame.height ?? 900) * 0.72).rounded()
    }

    func documentSize(fontSize: CGFloat) -> NSSize {
        let font = CodeStyle.font(size: fontSize)
        let widest = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let content = min(Self.maxWidth, ceil(widest) + 16)
        let digits = max(2, String(lines.count).count)
        let gutter = ceil(("8" as NSString).size(withAttributes: [.font: font]).width) * CGFloat(digits) + 12
        let fullHeight = max(1, CGFloat(lines.count)) * CodeStyle.lineHeight(size: fontSize)
        let textHeight = min(fullHeight, maxTextHeight)
        let width = Self.padding * 2 + gutter + content + 8
        let height = Self.padding * 2 + Self.titleHeight + textHeight + 6
        return NSSize(width: min(width, Self.maxWidth + 80), height: height)
    }

    @objc private func textDidScroll() {
        needsDisplay = true
    }

    private func applyText() {
        textView.textStorage?.setAttributedString(CodeStyle.highlight(text, size: fontSize))
        textView.textColor = CodeStyle.plain
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let top = Self.padding + Self.titleHeight
        let frame = NSRect(x: Self.padding + gutterWidth,
                           y: top,
                           width: max(40, bounds.width - Self.padding * 2 - gutterWidth),
                           height: max(10, bounds.height - top - Self.padding))
        scrollView.frame = frame
        let contentWidth = max(40, frame.width - (scrollView.verticalScroller?.frame.width ?? 0))
        let needed = max(frame.height, CGFloat(lines.count) * lineHeight + 4)
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: needed)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: PinTextWindow.padding, dy: PinTextWindow.padding)
        let radius = max(8, min(14, card.width * 0.02))

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        CodeStyle.background.setFill()
        NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius).fill()
        NSShadow().set()

        CodeStyle.border.setStroke()
        let edge = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        edge.lineWidth = 1
        edge.stroke()

        drawTrafficLights(in: card)
        drawGutter(in: card)
    }

    private func drawTrafficLights(in card: CGRect) {
        let diameter = max(7, fontSize * 0.55)
        let gap = diameter * 0.55
        var x = card.minX + Self.padding
        let y = card.minY + Self.padding * 0.55
        for colour in CodeStyle.trafficLights {
            colour.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: y, width: diameter, height: diameter)).fill()
            x += diameter + gap
        }
    }

    /// Line numbers, placed from the layout manager's own line fragments so
    /// they follow wrapped lines and blank lines exactly.
    private func drawGutter(in card: CGRect) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)

        let font = CodeStyle.font(size: fontSize * 0.92)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CodeStyle.gutter
        ]
        let clip = scrollView.contentView
        let textOrigin = NSPoint(x: scrollView.frame.minX - clip.bounds.minX,
                                 y: scrollView.frame.minY - clip.bounds.minY)
        let columnRight = Self.padding + gutterWidth - 12
        var character = 0
        for (index, line) in lines.enumerated() {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(character, max(0, textView.string.utf16.count - 1)))
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let label = "\(index + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = textOrigin.y + fragment.minY + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: columnRight - size.width, y: y), withAttributes: attributes)
            character += (line as NSString).length + 1
            if character >= textView.string.utf16.count { break }
        }
    }

    /// A text pin has the same first-click problem as a picture pin: the
    /// press has to both focus it and start the drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The card drags as one piece; hold ⌥ to select text instead. Without
    /// this the text view swallowed every press and the pin could not be moved.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let card = bounds.insetBy(dx: PinTextWindow.padding, dy: PinTextWindow.padding)
        // Transparent padding is shadow, not card. Let clicks there reach a pin
        // that is visibly underneath.
        guard card.contains(local) else { return nil }
        if NSEvent.modifierFlags.contains(.option) {
            return super.hitTest(point)
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        window?.orderFrontRegardless()
        window?.makeKey()
        if event.clickCount == 2 {
            onCloseWindow?()
            return
        }
        if event.modifierFlags.contains(.option) {
            super.mouseDown(with: event)
            return
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌥ scrolls a long paste; a plain scroll still changes the type size.
        if event.modifierFlags.contains(.option) {
            scrollView.scrollWheel(with: event)
            return
        }
        onZoom?(event.scrollingDeltaY)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.orderFrontRegardless()
        let menu = NSMenu()
        let copy = ClosureMenuItem(title: "复制全部文字") { [weak self] in self?.onCopy?() }
        menu.addItem(copy)
        let hint = NSMenuItem(title: "按住 ⌥ 拖动可选中文字，⌥ 滚轮看全文", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "关闭") { [weak self] in self?.onCloseWindow?() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
