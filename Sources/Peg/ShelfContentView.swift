import AppKit

/// Sizes for the line, from the menu bar.
enum LineSize: String, CaseIterable {
    case small, medium, large

    var scale: CGFloat {
        switch self {
        case .small: return 0.8
        case .medium: return 1
        case .large: return 1.35
        }
    }

    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }
}

enum ShelfMetrics {
    /// Small / medium / large, remembered between launches.
    static var lineSize: LineSize {
        get { LineSize(rawValue: UserDefaults.standard.string(forKey: "lineSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lineSize") }
    }

    static var scale: CGFloat { lineSize.scale }
    static var cardMaxHeight: CGFloat { (76 * scale).rounded() }
    static var cardMaxWidth: CGFloat { (210 * scale).rounded() }
    static var pegHeight: CGFloat { (15 * scale).rounded() }
    static var inset: CGFloat { max(3, (5 * scale).rounded()) }
    static var gap: CGFloat { (30 * scale).rounded() }
    /// How far below the rope the top edge of the paper sits. The peg grips
    /// across this gap, which is what makes it read as "hung" rather than
    /// "floating in front of a line".
    static var ropeOffset: CGFloat { (4 * scale).rounded() }
    static var side: CGFloat { (26 * scale).rounded() }
}

/// The clothesline: a rope that sags under the menu bar with shots pegged to
/// it. The look follows Tendedero's rope: a parabola, a dark pass for the
/// shadow, a mid-grey core and a faint highlight, fading out at both ends.
final class ShelfContentView: NSView {
    static let ropeTop: CGFloat = 22
    static var ropeSag: (CGFloat) -> CGFloat = { width in min(30, width * 0.018) }

    static var height: CGFloat {
        ropeTop + 30 + ShelfMetrics.pegHeight + ShelfMetrics.cardMaxHeight
            + ShelfMetrics.inset * 2 + 10
    }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = min(1, max(0, x / width))
        return ropeTop + 4 * ropeSag(width) * f * (1 - f)
    }

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
    var onPin: ((ShotItem) -> Void)?

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
        hint.attributedStringValue = Self.text("⌃⌥X 截图　·　点图复制　·　悬浮预览　·　拖出去用　·　⌃⌥S 收起",
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
        scroll.onScroll = { [weak self] in self?.previewClosed() }
        addSubview(scroll)

        // Behind the cards: a rope is occluded by the paper hanging on it,
        // and the peg is drawn on the card so it appears to grip the line.
        let rope = RopeView(frame: bounds)
        rope.autoresizingMask = [.width, .height]
        addSubview(rope, positioned: .below, relativeTo: scroll)

        strip.host = self
        strip.onCopy = { [weak self] item in self?.onCopy?(item) }
        strip.onOpen = { [weak self] item in self?.onOpen?(item) }
        strip.onSaveToDesktop = { [weak self] item in self?.onSaveToDesktop?(item) }
        strip.onReveal = { [weak self] item in self?.onReveal?(item) }
        strip.onTrash = { [weak self] item in self?.onTrash?(item) }
        strip.onOCR = { [weak self] item in self?.onOCR?(item) }
        strip.onPin = { [weak self] item in self?.onPin?(item) }
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
        DispatchQueue.main.async { [weak self] in self?.scrollToNewest() }
    }

    private func scrollToNewest() {
        guard !strip.isHidden else { return }
        let clip = scroll.contentView
        let maxX = max(0, strip.frame.width - clip.bounds.width)
        guard maxX > 0 else { return }
        clip.scroll(to: NSPoint(x: maxX, y: 0))
        scroll.reflectScrolledClipView(clip)
    }

    private func previewClosed() {
        strip.closePreviews()
    }

    override func layout() {
        super.layout()
        let side: CGFloat = ShelfMetrics.side
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
        let steps = 200
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

    /// One segment: dark underlay for the shadow, mid grey core, white highlight.
    private func stroke(from: NSPoint, to: NSPoint, alpha: CGFloat) {
        guard alpha > 0.01 else { return }

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4 * alpha)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: 1.5)
        shadow.set()

        let core = NSBezierPath()
        core.move(to: from)
        core.line(to: to)
        core.lineWidth = 2.8
        NSColor.black.withAlphaComponent(0.30 * alpha).setStroke()
        core.stroke()

        NSShadow().set()

        core.lineWidth = 2.0
        NSColor(white: 0.58, alpha: 0.95 * alpha).setStroke()
        core.stroke()

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: from.x, y: from.y - 0.7))
        highlight.line(to: NSPoint(x: to.x, y: to.y - 0.7))
        highlight.lineWidth = 0.6
        NSColor.white.withAlphaComponent(0.6 * alpha).setStroke()
        highlight.stroke()
    }
}

/// Vertical wheel scrolls the shelf sideways, which is what a plain mouse has.
final class HorizontalScrollView: NSScrollView {
    var onScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?()
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
    weak var host: NSView?
    private var thumbs: [ThumbView] = []

    var onCopy: ((ShotItem) -> Void)?
    var onOpen: ((ShotItem) -> Void)?
    var onSaveToDesktop: ((ShotItem) -> Void)?
    var onReveal: ((ShotItem) -> Void)?
    var onTrash: ((ShotItem) -> Void)?
    var onOCR: ((ShotItem) -> Void)?
    var onPin: ((ShotItem) -> Void)?

    override var isFlipped: Bool { true }

    func setItems(_ items: [ShotItem]) {
        let previous = Set(thumbs.map { $0.item.url })
        thumbs.forEach { $0.removeFromSuperview() }

        // Oldest on the left, newest on the right, so the new one lands at the
        // end of the line and older ones scroll in from the left.
        thumbs = items.reversed().map { item in
            let view = ThumbView(item: item)
            view.onCopy = { [weak self] in self?.onCopy?(item) }
            view.onOpen = { [weak self] in self?.onOpen?(item) }
            view.onSaveToDesktop = { [weak self] in self?.onSaveToDesktop?(item) }
            view.onReveal = { [weak self] in self?.onReveal?(item) }
            view.onTrash = { [weak self] in self?.onTrash?(item) }
            view.onOCR = { [weak self] in self?.onOCR?(item) }
            view.onPin = { [weak self] in self?.onPin?(item) }
            view.strip = self
            addSubview(view)
            if !previous.isEmpty, !previous.contains(item.url) {
                view.dropIn()
            }
            return view
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func closePreviews() {
        PreviewPanel.shared.hide()
        thumbs.forEach { $0.cancelPreview() }
    }

    override var intrinsicContentSize: NSSize {
        let widths = thumbs.reduce(0) { $0 + $1.intrinsicContentSize.width + ShelfMetrics.gap }
        return NSSize(width: max(0, widths - ShelfMetrics.gap + ShelfMetrics.side * 2),
                      height: ShelfContentView.height)
    }

    override func layout() {
        super.layout()
        guard !thumbs.isEmpty else { return }
        let visible = superview?.bounds.width ?? bounds.width
        let originInHost = host.map { convert(NSPoint.zero, to: $0) } ?? .zero

        let total = thumbs.reduce(0) { $0 + $1.intrinsicContentSize.width } 
            + ShelfMetrics.gap * CGFloat(max(0, thumbs.count - 1))
        var x = total + ShelfMetrics.side * 2 <= visible
            ? (visible - total) / 2
            : ShelfMetrics.side
        for thumb in thumbs {
            let size = thumb.intrinsicContentSize
            let ropeX = originInHost.x + x + size.width / 2
            let ropeY = ShelfContentView.ropeY(x: ropeX, width: visible)
            let slope = atan(ShelfContentView.ropeSlope(x: ropeX, width: visible))
            thumb.frame = NSRect(x: x,
                                 y: ropeY + ShelfMetrics.ropeOffset - ShelfMetrics.pegHeight,
                                 width: size.width, height: size.height)
            thumb.tilt = slope + thumb.item.tilt
            x += size.width + ShelfMetrics.gap
        }
    }
}

extension ShotItem {
    /// A small, stable tilt so the line looks casually hung rather than laid out.
    var tilt: CGFloat {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.lastPathComponent.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let unit = CGFloat(hash % 1000) / 1000 - 0.5
        return unit * 0.055   // about ±1.6°
    }
}

final class ThumbView: NSView, NSDraggingSource {
    let item: ShotItem
    weak var strip: ThumbStrip?
    var tilt: CGFloat = 0 { didSet { needsDisplay = true } }

    var onCopy: (() -> Void)?
    var onOpen: (() -> Void)?
    var onSaveToDesktop: (() -> Void)?
    var onReveal: (() -> Void)?
    var onTrash: (() -> Void)?
    var onOCR: (() -> Void)?
    var onPin: (() -> Void)?

    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var dragged = false
    private var dropOffset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    private var dropTimer: Timer?
    private var swing: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    private var swingTimer: Timer?
    private var previewWork: DispatchWorkItem?

    init(item: ShotItem) {
        self.item = item
        super.init(frame: .zero)
        toolTip = item.url.lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let imageSize = item.thumb.size
        var height = ShelfMetrics.cardMaxHeight
        var width = height
        if imageSize.width > 0, imageSize.height > 0 {
            let aspect = imageSize.width / imageSize.height
            width = height * aspect
            if width > ShelfMetrics.cardMaxWidth {
                width = ShelfMetrics.cardMaxWidth
                height = width / aspect
            }
        }
        return NSSize(width: max(44, width) + ShelfMetrics.inset * 2,
                      height: max(26, height) + ShelfMetrics.inset * 2 + ShelfMetrics.pegHeight)
    }

    // MARK: - Motion

    /// New shots fall onto the line and swing once they land.
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
                self.nudge(5)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dropTimer = timer
    }

    /// A damped swing around the peg.
    func nudge(_ degrees: CGFloat) {
        swingTimer?.invalidate()
        let amplitude = degrees * .pi / 180
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 1.5 {
                timer.invalidate()
                self.swingTimer = nil
                self.swing = 0
                return
            }
            let decay = exp(-3.2 * elapsed)
            self.swing = amplitude * decay * sin(2 * .pi * 1.7 * elapsed)
        }
        RunLoop.main.add(timer, forMode: .common)
        swingTimer = timer
    }

    // MARK: - Hover

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
        nudge(2.5)
        schedulePreview()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        cancelPreview(delay: 0.12)
    }

    func cancelPreview(delay: TimeInterval = 0) {
        previewWork?.cancel()
        previewWork = nil
        PreviewPanel.shared.hide(after: delay)
    }

    private func schedulePreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showPreview() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func showPreview() {
        guard !dragged, let window else { return }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return }
        let image = NSImage(contentsOf: item.url) ?? item.thumb
        PreviewPanel.shared.show(image, near: onScreen, on: screen)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let cardTop = ShelfMetrics.pegHeight
        let card = CGRect(x: 0, y: cardTop,
                          width: bounds.width,
                          height: bounds.height - cardTop)

        // Rotate around the point where the peg holds the card.
        context.saveGState()
        context.translateBy(x: card.midX, y: cardTop + dropOffset)
        context.rotate(by: tilt + swing)
        context.translateBy(x: -card.midX, y: -cardTop)

        // Paper first, peg on top: the jaws must visibly bite the sheet.
        drawFrame(card)
        drawPeg(at: CGPoint(x: card.midX, y: cardTop))

        context.restoreGState()
    }

    /// A clothespin: a grip that widens at the top, a coil across the middle
    /// and two jaws biting the paper. The coil sits on the rope, so the line
    /// visibly passes *through* the peg rather than behind a floating block.
    private func drawPeg(at point: CGPoint) {
        let scale = ShelfMetrics.scale
        let above = (11 * scale).rounded()
        let below = (6 * scale).rounded()
        let topWidth = (10 * scale).rounded()
        let bottomWidth = (7 * scale).rounded()

        let minY = point.y - above
        let maxY = point.y + below
        let midX = point.x.rounded()
        let radius = min(2.5 * scale, topWidth / 2)

        // Body: a trapezoid with a rounded top.
        let body = NSBezierPath()
        body.move(to: NSPoint(x: midX - bottomWidth / 2, y: maxY))
        body.line(to: NSPoint(x: midX - topWidth / 2, y: minY + radius))
        body.appendArc(withCenter: NSPoint(x: midX - topWidth / 2 + radius, y: minY + radius),
                       radius: radius, startAngle: 180, endAngle: 270)
        body.line(to: NSPoint(x: midX + topWidth / 2 - radius, y: minY))
        body.appendArc(withCenter: NSPoint(x: midX + topWidth / 2 - radius, y: minY + radius),
                       radius: radius, startAngle: 270, endAngle: 360)
        body.line(to: NSPoint(x: midX + bottomWidth / 2, y: maxY))
        body.close()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: 1.5)
        shadow.set()
        NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.89, alpha: 1).setFill()
        body.fill()
        NSShadow().set()

        // A soft vertical shading so it does not read as flat paper.
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        let shade = NSGradient(starting: NSColor(calibratedWhite: 1, alpha: 0.75),
                               ending: NSColor(calibratedWhite: 0.62, alpha: 0.5))
        shade?.draw(in: body, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Jaws: the gap between the two legs, opening towards the paper.
        let ropeY = minY + above - ShelfMetrics.ropeOffset
        NSColor(calibratedWhite: 0.45, alpha: 0.75).setFill()
        NSBezierPath(rect: CGRect(x: midX - 0.6 * scale, y: ropeY + 1,
                                  width: 1.2 * scale, height: maxY - ropeY - 2)).fill()
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: midX - bottomWidth * 0.28, y: maxY))
        mouth.line(to: NSPoint(x: midX, y: maxY - below * 0.7))
        mouth.line(to: NSPoint(x: midX + bottomWidth * 0.28, y: maxY))
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        mouth.fill()

        // Coil, wrapped around the peg right where the rope crosses.
        let coil = CGRect(x: midX - topWidth / 2 - 0.4, y: ropeY - 1.6, width: topWidth + 0.8, height: 3.2)
        NSColor(calibratedWhite: 0.62, alpha: 1).setFill()
        NSBezierPath(roundedRect: coil, xRadius: 1.4, yRadius: 1.4).fill()
        NSColor(calibratedWhite: 0.34, alpha: 0.85).setStroke()
        for offset in [-0.8, 0.8] {
            let wire = NSBezierPath()
            wire.move(to: NSPoint(x: coil.minX, y: coil.midY + offset))
            wire.line(to: NSPoint(x: coil.maxX, y: coil.midY + offset))
            wire.lineWidth = 0.5
            wire.stroke()
        }

        // Contact shadow on the paper, so the jaws look like they pinch it.
        NSGraphicsContext.saveGraphicsState()
        let jawShadow = NSShadow()
        jawShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        jawShadow.shadowBlurRadius = 2
        jawShadow.shadowOffset = NSSize(width: 0, height: 2)
        jawShadow.set()
        NSColor.black.withAlphaComponent(0.01).setFill()
        NSBezierPath(rect: CGRect(x: midX - bottomWidth / 2, y: maxY - 1, width: bottomWidth, height: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 0.28, alpha: 0.7).setStroke()
        body.lineWidth = 0.8
        body.stroke()
    }

    private func drawFrame(_ card: CGRect) {
        let outward: CGFloat = hovering ? 1 : 0
        let frameRect = card.insetBy(dx: -outward, dy: -outward)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(hovering ? 0.5 : 0.38)
        shadow.shadowBlurRadius = hovering ? 12 : 7
        shadow.shadowOffset = NSSize(width: 0, height: hovering ? 6 : 4)
        shadow.set()

        // A paper-white frame, the way a print looks pegged to a line.
        NSColor(calibratedWhite: 0.97, alpha: 0.96).setFill()
        let frame = NSBezierPath(roundedRect: frameRect, xRadius: 8, yRadius: 8)
        frame.fill()

        NSShadow().set()

        let photo = frameRect.insetBy(dx: ShelfMetrics.inset, dy: ShelfMetrics.inset)
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

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        dragged = false
        cancelPreview()
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged else { return }
        if event.clickCount >= 2 {
            onOpen?()
        } else {
            onCopy?()
            nudge(3)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        cancelPreview()
        let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: item.thumb)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelPreview()
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "复制") { [weak self] in self?.onCopy?() })
        menu.addItem(ClosureMenuItem(title: "贴到屏幕上") { [weak self] in self?.onPin?() })
        menu.addItem(ClosureMenuItem(title: "识别文字") { [weak self] in self?.onOCR?() })
        menu.addItem(ClosureMenuItem(title: "用「预览」打开") { [weak self] in self?.onOpen?() })
        menu.addItem(ClosureMenuItem(title: "保存到桌面") { [weak self] in self?.onSaveToDesktop?() })
        menu.addItem(ClosureMenuItem(title: "在访达中显示") { [weak self] in self?.onReveal?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "移入废纸篓") { [weak self] in self?.onTrash?() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
