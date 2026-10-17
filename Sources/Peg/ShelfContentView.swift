import AppKit

/// The clothesline: a taut line under the menu bar with the latest shots
/// hanging from it. No background panel — only the line and the cards are
/// drawn, so it reads as a line rather than a strip.
final class ShelfContentView: NSView {
    static let lineY: CGFloat = 30
    static let cardHeight: CGFloat = 92
    static let height: CGFloat = lineY + cardHeight + 12

    private let header = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let scroll = HorizontalScrollView()
    private let strip = ThumbStrip()

    var onCopy: ((ShotItem) -> Void)?
    var onOpen: ((ShotItem) -> Void)?
    var onSaveToDesktop: ((ShotItem) -> Void)?
    var onReveal: ((ShotItem) -> Void)?
    var onTrash: ((ShotItem) -> Void)?
    var onOCR: ((ShotItem) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: 1)
        header.attributedStringValue = NSAttributedString(
            string: "PEG",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
                .kern: 2.5,
                .shadow: shadow
            ])
        addSubview(header)

        hint.alignment = .right
        hint.attributedStringValue = Self.text("⌃⌥X 截图　·　点图复制　·　双击打开　·　拖出去用　·　⌃⌥S 收起",
                                               size: 10, alpha: 0.62)
        addSubview(hint)

        emptyLabel.attributedStringValue = Self.text("按 ⌃⌥X 截一张，它就挂在这根线上",
                                                     size: 12, alpha: 0.8)
        addSubview(emptyLabel)

        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.documentView = strip
        addSubview(scroll)

        strip.onCopy = { [weak self] item in self?.onCopy?(item) }
        strip.onOpen = { [weak self] item in self?.onOpen?(item) }
        strip.onSaveToDesktop = { [weak self] item in self?.onSaveToDesktop?(item) }
        strip.onReveal = { [weak self] item in self?.onReveal?(item) }
        strip.onTrash = { [weak self] item in self?.onTrash?(item) }
        strip.onOCR = { [weak self] item in self?.onOCR?(item) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func setItems(_ items: [ShotItem]) {
        strip.setItems(items)
        emptyLabel.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 24
        header.sizeToFit()
        header.frame.origin = NSPoint(x: side, y: 6)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: bounds.width - hint.frame.width - side, y: 7)
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(x: side, y: Self.lineY + 34)

        scroll.frame = NSRect(x: side - 2,
                              y: Self.lineY + 6,
                              width: bounds.width - (side - 2) * 2,
                              height: Self.cardHeight - 6)
        strip.setFrameSize(NSSize(width: max(strip.intrinsicContentSize.width, scroll.frame.width),
                                  height: Self.cardHeight - 6))
        strip.needsLayout = true
    }

    private static func text(_ string: String, size: CGFloat, alpha: CGFloat) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: 1)
        return NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .shadow: shadow
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 24
        let lineY = Self.lineY

        // Two passes: a dark underlay and a light top. Reads on a white page
        // and on a dark terminal without any background panel.
        let dark = NSBezierPath()
        dark.move(to: NSPoint(x: side, y: lineY))
        dark.line(to: NSPoint(x: bounds.maxX - side, y: lineY))
        dark.lineWidth = 3
        NSColor.black.withAlphaComponent(0.35).setStroke()
        dark.stroke()

        let light = NSBezierPath()
        light.move(to: NSPoint(x: side, y: lineY))
        light.line(to: NSPoint(x: bounds.maxX - side, y: lineY))
        light.lineWidth = 1.2
        NSColor.white.withAlphaComponent(0.85).setStroke()
        light.stroke()

        // Small hooks at both ends.
        NSColor.white.withAlphaComponent(0.8).setFill()
        for x in [side, bounds.maxX - side] {
            NSBezierPath(ovalIn: NSRect(x: x - 2.5, y: lineY - 2, width: 5, height: 5)).fill()
        }
    }
}

/// Vertical wheel scrolls the shelf sideways, which is what a plain mouse has.
final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            let clip = contentView
            let maxX = max(0, (documentView?.frame.width ?? 0) - clip.bounds.width)
            var origin = clip.bounds.origin
            origin.x = min(max(0, origin.x - event.scrollingDeltaY), maxX)
            clip.scroll(to: origin)
            reflectScrolledClipView(clip)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class ThumbStrip: NSView {
    private static let gap: CGFloat = 14
    private var thumbs: [ThumbView] = []

    var onCopy: ((ShotItem) -> Void)?
    var onOpen: ((ShotItem) -> Void)?
    var onSaveToDesktop: ((ShotItem) -> Void)?
    var onReveal: ((ShotItem) -> Void)?
    var onTrash: ((ShotItem) -> Void)?
    var onOCR: ((ShotItem) -> Void)?

    override var isFlipped: Bool { true }

    func setItems(_ items: [ShotItem]) {
        thumbs.forEach { $0.removeFromSuperview() }
        thumbs = items.map { item in
            let view = ThumbView(item: item)
            view.onCopy = { [weak self] in self?.onCopy?(item) }
            view.onOpen = { [weak self] in self?.onOpen?(item) }
            view.onSaveToDesktop = { [weak self] in self?.onSaveToDesktop?(item) }
            view.onReveal = { [weak self] in self?.onReveal?(item) }
            view.onTrash = { [weak self] in self?.onTrash?(item) }
            view.onOCR = { [weak self] in self?.onOCR?(item) }
            addSubview(view)
            return view
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let width = thumbs.reduce(0) { $0 + $1.intrinsicContentSize.width + Self.gap }
        return NSSize(width: max(0, width - Self.gap), height: ShelfContentView.cardHeight - 6)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for thumb in thumbs {
            let size = thumb.intrinsicContentSize
            thumb.frame = NSRect(x: x, y: 0, width: size.width, height: size.height)
            x += size.width + Self.gap
        }
    }
}

final class ThumbView: NSView, NSDraggingSource {
    let item: ShotItem
    var onCopy: (() -> Void)?
    var onOpen: (() -> Void)?
    var onSaveToDesktop: (() -> Void)?
    var onReveal: (() -> Void)?
    var onTrash: (() -> Void)?
    var onOCR: (() -> Void)?

    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var dragged = false

    init(item: ShotItem) {
        self.item = item
        super.init(frame: .zero)
        toolTip = item.url.lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let maxWidth: CGFloat = 230
        let maxHeight: CGFloat = 80
        let imageSize = item.thumb.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSSize(width: maxWidth, height: maxHeight)
        }
        let aspect = imageSize.width / imageSize.height
        var height = maxHeight
        var width = height * aspect
        if width > maxWidth {
            width = maxWidth
            height = width / aspect
        }
        return NSSize(width: max(46, width), height: max(28, height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = hovering ? 0.5 : 1.5
        let card = bounds.insetBy(dx: inset, dy: inset)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = hovering ? 14 : 7
        shadow.shadowOffset = NSSize(width: 0, height: hovering ? 5 : 3)
        shadow.set()

        let path = NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7)
        NSColor.black.withAlphaComponent(0.35).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        item.thumb.draw(in: card)
        NSGraphicsContext.restoreGraphicsState()

        (hovering ? NSColor.white.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.28)).setStroke()
        path.lineWidth = 1
        path.stroke()

        drawClip(at: card)
    }

    /// A little peg where the card meets the line.
    private func drawClip(at card: CGRect) {
        let width: CGFloat = 9
        let height: CGFloat = 13
        let peg = CGRect(x: card.midX - width / 2, y: card.minY - height * 0.55,
                         width: width, height: height)
        NSColor(calibratedWhite: 0.9, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: peg, xRadius: 2.5, yRadius: 2.5).fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let outline = NSBezierPath(roundedRect: peg, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 0.5
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        dragged = false
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged else { return }
        if event.clickCount >= 2 {
            onOpen?()
        } else {
            onCopy?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: item.thumb)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "复制") { [weak self] in self?.onCopy?() })
        menu.addItem(ClosureMenuItem(title: "识别文字") { [weak self] in self?.onOCR?() })
        menu.addItem(ClosureMenuItem(title: "用「预览」打开") { [weak self] in self?.onOpen?() })
        menu.addItem(ClosureMenuItem(title: "保存到桌面") { [weak self] in self?.onSaveToDesktop?() })
        menu.addItem(ClosureMenuItem(title: "在访达中显示") { [weak self] in self?.onReveal?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "移入废纸篓") { [weak self] in self?.onTrash?() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
