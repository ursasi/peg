import AppKit

/// The clothesline: a rope that sags under the menu bar with shots pegged to
/// it. The look follows Tendedero's rope: a parabola, a dark pass for the
/// shadow, a mid-grey core and a faint highlight, fading out at both ends.
final class ShelfContentView: NSView {
    static let ropeTop: CGFloat = 22

    static var ropeSag: (CGFloat) -> CGFloat = { width in min(30, width * 0.018) }

    /// Panel height: rope + sag + peg + card + a little air.
    static let height: CGFloat = ropeTop + 26 + 18 + 92 + 10

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = min(1, max(0, x / width))
        return ropeTop + 4 * ropeSag(width) * f * (1 - f)
    }

    /// Radians, for tilting a card so it hangs perpendicular to the rope.
    static func ropeSlope(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let f = min(1, max(0, x / width))
        return 4 * ropeSag(width) * (1 - 2 * f) / width
    }

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
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: 1)
        header.attributedStringValue = NSAttributedString(
            string: "PEG",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
                .kern: 2.5,
                .shadow: shadow
            ])
        addSubview(header)

        hint.alignment = .right
        hint.attributedStringValue = Self.text("⌃⌥X 截图　·　点图复制　·　双击打开　·　拖出去用　·　⌃⌥S 收起",
                                               size: 10, alpha: 0.6)
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

        let rope = RopeView(frame: bounds)
        rope.autoresizingMask = [.width, .height]
        addSubview(rope)

        strip.host = self
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
        let side: CGFloat = 26
        header.sizeToFit()
        header.frame.origin = NSPoint(x: side, y: 4)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: bounds.width - hint.frame.width - side, y: 5)
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(
            x: bounds.midX - emptyLabel.frame.width / 2,
            y: Self.ropeY(x: bounds.midX, width: bounds.width) + 34)

        scroll.frame = bounds
        strip.setFrameSize(NSSize(width: max(strip.intrinsicContentSize.width, bounds.width),
                                  height: bounds.height))
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

}

/// The rope itself, drawn above the cards so nothing can cover it.
final class RopeView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width
        guard width > 0 else { return }
        let startX: CGFloat = -24
        let endX = width + 24
        let steps = 320
        let fadeSpan: CGFloat = 0.07

        var previous = NSPoint(x: startX, y: ShelfContentView.ropeY(x: startX, width: width))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let x = startX + (endX - startX) * t
            let current = NSPoint(x: x, y: ShelfContentView.ropeY(x: x, width: width))
            let alpha = min(1, min(t / fadeSpan, (1 - t) / fadeSpan))
            stroke(from: previous, to: current, alpha: alpha)
            previous = current
        }
    }

    /// One segment of the rope: shadow-bearing core plus a highlight above it.
    private func stroke(from: NSPoint, to: NSPoint, alpha: CGFloat) {
        guard alpha > 0.01 else { return }

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4 * alpha)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: 1.4)
        shadow.set()

        let core = NSBezierPath()
        core.move(to: from)
        core.line(to: to)
        core.lineWidth = 1.3
        core.lineWidth = 2.6
        NSColor.black.withAlphaComponent(0.30 * alpha).setStroke()
        core.stroke()

        core.lineWidth = 1.9
        NSColor(white: 0.58, alpha: 0.95 * alpha).setStroke()
        core.stroke()

        NSShadow().set()

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: from.x, y: from.y - 0.7))
        highlight.line(to: NSPoint(x: to.x, y: to.y - 0.7))
        highlight.lineWidth = 0.6
        NSColor.white.withAlphaComponent(0.65 * alpha).setStroke()
        highlight.stroke()


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
    private static let gap: CGFloat = 26

    weak var host: NSView?
    private var thumbs: [ThumbView] = []

    var onCopy: ((ShotItem) -> Void)?
    var onOpen: ((ShotItem) -> Void)?
    var onSaveToDesktop: ((ShotItem) -> Void)?
    var onReveal: ((ShotItem) -> Void)?
    var onTrash: ((ShotItem) -> Void)?
    var onOCR: ((ShotItem) -> Void)?

    override var isFlipped: Bool { true }

    func setItems(_ items: [ShotItem]) {
        let previous = Set(thumbs.map { $0.item.url })
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
            if !previous.isEmpty, !previous.contains(item.url) {
                view.dropIn()
            }
            return view
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let width = thumbs.reduce(0) { $0 + $1.intrinsicContentSize.width + Self.gap }
        return NSSize(width: max(0, width - Self.gap + 52), height: ShelfContentView.height)
    }

    override func layout() {
        super.layout()
        let total = intrinsicContentSize.width
        var x = max(26, (bounds.width - (intrinsicContentSize.width - 52)) / 2)
        x = max(26, x)
        for thumb in thumbs {
            let size = thumb.intrinsicContentSize
            let ropeX = x + size.width / 2
            let ropeY = ShelfContentView.ropeY(x: ropeX, width: bounds.width)
            let slope = atan(ShelfContentView.ropeSlope(x: ropeX, width: bounds.width))
            thumb.tilt = slope + thumb.item.tilt
            thumb.frame = NSRect(x: x, y: ropeY - ThumbView.pegHeight, width: size.width, height: size.height)
            x += size.width + Self.gap
        }
    }
}

extension ShotItem {
    /// A small, stable tilt so the line looks casually hung rather than laid out.
    var tilt: CGFloat {
        var hash: UInt64 = 1469598103934665603
        for byte in url.lastPathComponent.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        let unit = CGFloat(hash % 1000) / 1000 - 0.5
        return unit * 0.055   // about ±1.6°
    }
}

final class ThumbView: NSView, NSDraggingSource {
    static let pegHeight: CGFloat = 15
    static let frameInset: CGFloat = 5

    let item: ShotItem
    var tilt: CGFloat = 0 { didSet { needsDisplay = true } }
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
    private var dropOffset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    private var dropTimer: Timer?

    /// New shots fall onto the line.
    func dropIn() {
        dropTimer?.invalidate()
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, Date().timeIntervalSince(start) / 0.42)
            let remaining = (1 - progress) * (1 - progress)
            self.dropOffset = -46 * remaining
            if progress >= 1 {
                timer.invalidate()
                self.dropTimer = nil
                self.dropOffset = 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dropTimer = timer
    }

    init(item: ShotItem) {
        self.item = item
        super.init(frame: .zero)
        toolTip = item.url.lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let maxWidth: CGFloat = 210
        let maxHeight: CGFloat = 76
        let imageSize = item.thumb.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSSize(width: maxWidth, height: maxHeight + Self.pegHeight)
        }
        let aspect = imageSize.width / imageSize.height
        var height = maxHeight
        var width = height * aspect
        if width > maxWidth {
            width = maxWidth
            height = width / aspect
        }
        return NSSize(width: max(44, width) + Self.frameInset * 2,
                      height: max(26, height) + Self.frameInset * 2 + Self.pegHeight)
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
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let cardTop = Self.pegHeight
        let card = CGRect(x: 0, y: cardTop,
                          width: bounds.width,
                          height: bounds.height - cardTop)

        // Tilt around the point where the peg holds the card.
        context.saveGState()
        context.translateBy(x: card.midX, y: cardTop + dropOffset)
        context.rotate(by: tilt)
        context.translateBy(x: -card.midX, y: -cardTop)

        drawPeg(at: CGPoint(x: card.midX, y: cardTop))
        drawFrame(card)

        context.restoreGState()
    }

    /// A clothespin: two legs, a gap and a spring.
    private func drawPeg(at point: CGPoint) {
        let width: CGFloat = 9
        let height: CGFloat = 19
        let body = CGRect(x: point.x - width / 2, y: point.y - height + 2, width: width, height: height)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: 1.5)
        shadow.set()

        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        let pin = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
        pin.fill()

        NSShadow().set()
        NSColor(calibratedWhite: 0.25, alpha: 0.55).setStroke()
        pin.lineWidth = 0.6
        pin.stroke()

        // The slit between the legs.
        NSColor(calibratedWhite: 0.55, alpha: 0.9).setFill()
        NSBezierPath(rect: CGRect(x: body.midX - 0.5, y: body.minY + 5,
                                  width: 1, height: body.height - 8)).fill()

        // The spring.
        let spring = NSBezierPath(ovalIn: CGRect(x: body.midX - 2.4, y: body.minY + 7,
                                                 width: 4.8, height: 4.8))
        NSColor(calibratedWhite: 0.45, alpha: 1).setStroke()
        spring.lineWidth = 1
        spring.stroke()
    }

    private func drawFrame(_ card: CGRect) {
        let outward: CGFloat = hovering ? 1 : 0
        let frameRect = card.insetBy(dx: -outward, dy: -outward)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(hovering ? 0.5 : 0.38)
        shadow.shadowBlurRadius = hovering ? 14 : 9
        shadow.shadowOffset = NSSize(width: 0, height: hovering ? 6 : 4)
        shadow.set()

        // A paper-white frame, the way a print looks pegged to a line.
        NSColor(calibratedWhite: 0.97, alpha: 0.96).setFill()
        let frame = NSBezierPath(roundedRect: frameRect, xRadius: 8, yRadius: 8)
        frame.fill()

        NSShadow().set()

        let photo = frameRect.insetBy(dx: Self.frameInset, dy: Self.frameInset)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: photo, xRadius: 5, yRadius: 5).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        item.thumb.draw(in: photo)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(hovering ? 0.22 : 0.14).setStroke()
        let border = NSBezierPath(roundedRect: frameRect, xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()
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
