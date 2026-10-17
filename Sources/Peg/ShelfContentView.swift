import AppKit

/// The line itself, in AppKit: a glass strip, a header, and a horizontally
/// scrollable row of hanging shots. No SwiftUI, so the Command Line Tools
/// toolchain (which ships no SwiftUI macro plugin) can build it.
final class ShelfContentView: NSView {
    private let effect = NSVisualEffectView()
    private let dim = NSView()
    private let header = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "⌃⌥X 截图　·　点图复制　·　双击打开　·　拖出去用　·　⌃⌥S 收起")
    private let emptyLabel = NSTextField(labelWithString: "按 ⌃⌥X 截一张，它就挂在这儿")
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
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = true

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        // The material follows whatever is behind it; without a solid tint the
        // white-on-white case makes the shelf unreadable.
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.82).cgColor
        addSubview(dim)

        header.attributedStringValue = NSAttributedString(
            string: "PEG",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                .kern: 2.5
            ])
        addSubview(header)

        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor.white.withAlphaComponent(0.45)
        hint.alignment = .right
        addSubview(hint)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.55)
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

    func setItems(_ items: [ShotItem]) {
        strip.setItems(items)
        emptyLabel.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 18
        effect.frame = bounds
        dim.frame = bounds
        header.sizeToFit()
        header.frame.origin = NSPoint(x: pad, y: bounds.height - 22)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: bounds.width - hint.frame.width - pad,
                                    y: bounds.height - 21)
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(x: pad, y: bounds.height - 62)

        let stripHeight = ThumbStrip.height
        scroll.frame = NSRect(x: pad - 2,
                              y: 8,
                              width: bounds.width - (pad - 2) * 2,
                              height: stripHeight)
        strip.setFrameSize(NSSize(width: max(strip.intrinsicContentSize.width, scroll.frame.width),
                                  height: stripHeight))
        strip.needsLayout = true
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
    static let height: CGFloat = 100
    private static let gap: CGFloat = 10

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
        return NSSize(width: max(0, width - Self.gap), height: Self.height)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for thumb in thumbs {
            let size = thumb.intrinsicContentSize
            thumb.frame = NSRect(x: x, y: Self.height - size.height - 1, width: size.width, height: size.height)
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
        let maxWidth: CGFloat = 240
        let maxHeight: CGFloat = 96
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
        return NSSize(width: max(48, width), height: max(32, height))
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

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = hovering ? 0.5 : 2.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.black.withAlphaComponent(0.35).setFill()
        rect.fill()
        item.thumb.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        (hovering ? NSColor.white.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.14)).setStroke()
        path.lineWidth = 1
        path.stroke()
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
        menu.addItem(ClosureMenuItem(title: "用「预览」打开") { [weak self] in self?.onOpen?() })
        menu.addItem(ClosureMenuItem(title: "识别文字") { [weak self] in self?.onOCR?() })
        menu.addItem(ClosureMenuItem(title: "保存到桌面") { [weak self] in self?.onSaveToDesktop?() })
        menu.addItem(ClosureMenuItem(title: "在访达中显示") { [weak self] in self?.onReveal?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "移入废纸篓") { [weak self] in self?.onTrash?() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
