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
    /// A line of tiny type under every sheet: when it was taken.
    static var stampHeight: CGFloat { (11 * scale).rounded() }
}

/// The clothesline: a rope that sags under the menu bar with shots pegged to
/// it. The look follows Tendedero's rope: a parabola, a dark pass for the
/// shadow, a mid-grey core and a faint highlight, fading out at both ends.
final class ShelfContentView: NSView {
    static let ropeTop: CGFloat = 22
    static var ropeSag: (CGFloat) -> CGFloat = { width in min(30, width * 0.018) }

    static var height: CGFloat {
        ropeTop + 30 + ShelfMetrics.pegHeight + ShelfMetrics.cardMaxHeight
            + ShelfMetrics.inset * 2 + ShelfMetrics.stampHeight + 10
    }

    /// A slow travelling ripple on top of the sag. Zero at both ends so the
    /// line stays pinned off-screen, and it never swings more than a couple of
    /// points, so the sheets still look hung rather than floating.
    static var wavePhase: CGFloat = 0
    static var waveAmplitude: CGFloat { 4 * ShelfMetrics.scale }
    static var waveLength: CGFloat { 240 * ShelfMetrics.scale }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = min(1, max(0, x / width))
        let sag = 4 * ropeSag(width) * f * (1 - f)
        // Only the last couple of percent at each end are flattened, so the
        // line reads as a wave even when the cards have scrolled away from the
        // edges. The ends themselves fade out (see RopeView).
        let pinned = min(1, min(f, 1 - f) * 40)
        let phase = x / waveLength * 2 * .pi + wavePhase
        return ropeTop + sag + sin(phase) * waveAmplitude * pinned
    }

    static func ropeSlope(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let step: CGFloat = 1
        return (ropeY(x: x + step, width: width) - ropeY(x: x - step, width: width)) / (2 * step)
    }

    private let header = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let scroll = HorizontalScrollView()
    private let strip = ThumbStrip()
    private var ropeView: RopeView?
    private var waveTimer: Timer?
    private var wavePaused = false

    var onCopy: ((ShotItem) -> Void)?
    var onOpen: ((ShotItem) -> Void)?
    var onSaveToDesktop: ((ShotItem) -> Void)?
    var onReveal: ((ShotItem) -> Void)?
    var onTrash: ((ShotItem) -> Void)?
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
        addSubview(hint)

        addSubview(emptyLabel)
        refreshHints()

        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.documentView = strip
        scroll.onScroll = { [weak self] in
            guard let self else { return }
            self.previewClosed()
            // Cards are hung on the rope by x, so scrolling has to re-lay them
            // out: their height and tilt both depend on where they now sit.
            self.strip.needsLayout = true
        }
        addSubview(scroll)

        // Behind the cards: a rope is occluded by the paper hanging on it,
        // and the peg is drawn on the card so it appears to grip the line.
        let rope = RopeView(frame: bounds)
        rope.autoresizingMask = [.width, .height]
        addSubview(rope, positioned: .below, relativeTo: scroll)
        ropeView = rope

        strip.host = self
        strip.onCopy = { [weak self] item in self?.onCopy?(item) }
        strip.onOpen = { [weak self] item in self?.onOpen?(item) }
        strip.onSaveToDesktop = { [weak self] item in self?.onSaveToDesktop?(item) }
        strip.onReveal = { [weak self] item in self?.onReveal?(item) }
        strip.onTrash = { [weak self] item in self?.onTrash?(item) }
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

    /// The rope only ripples while the line is on screen.
    func startWave() {
        // The hints quote whatever the shortcuts are bound to right now, so a
        // rebind in settings is picked up the next time the line drops.
        refreshHints()
        guard waveTimer == nil else { return }
        // A line that slid away while the pointer was on a sheet must ripple
        // again when it comes back.
        wavePaused = false
        // 12 fps is plenty for a rope that drifts a few points a second; the
        // old 24 fps doubled the redraw cost for motion nobody could see.
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.wavePaused else { return }
                ShelfContentView.wavePhase += 0.12
                self.ropeView?.needsDisplay = true
                self.strip.needsLayout = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        waveTimer = timer
    }

    func stopWave() {
        waveTimer?.invalidate()
        waveTimer = nil
    }

    /// A resting pointer needs a still line: the preview is placed once, and a
    /// moving sheet would slide out from under it.
    func pauseWave(_ paused: Bool) {
        wavePaused = paused
    }

    private func scrollToNewest() {
        guard !strip.isHidden else { return }
        let clip = scroll.contentView
        let maxX = max(0, strip.frame.width - clip.bounds.width)
        guard maxX > 0 else { return }
        clip.scroll(to: NSPoint(x: maxX, y: 0))
        scroll.reflectScrolledClipView(clip)
        strip.needsLayout = true
    }

    private func previewClosed() {
        strip.closePreviews()
    }

    func debugPreview(_ index: Int) {
        strip.debugPreview(index)
    }

    func debugHover(_ index: Int) {
        strip.debugHover(index)
    }

    func debugScroll(_ x: CGFloat) {
        let clip = scroll.contentView
        let maxX = max(0, strip.frame.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: min(max(0, x), maxX), y: 0))
        scroll.reflectScrolledClipView(clip)
        scroll.onScroll?()
    }

    override func layout() {
        super.layout()
        let side: CGFloat = ShelfMetrics.side
        header.sizeToFit()
        header.frame.origin = NSPoint(x: side, y: 4)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: bounds.width - hint.frame.width - side, y: 5)
        // The pill behind the hint is painted by this view, so it has to be
        // redrawn whenever the label moves or changes length.
        needsDisplay = true
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(
            x: bounds.midX - emptyLabel.frame.width / 2,
            y: Self.ropeY(x: bounds.midX, width: bounds.width) + 34)

        scroll.frame = bounds
        strip.setFrameSize(NSSize(width: max(strip.intrinsicContentSize.width, bounds.width),
                                  height: bounds.height))
        strip.needsLayout = true
    }

    /// The line used to advertise ⌃⌥X and ⌃⌥S in fixed text, which went stale as
    /// soon as either shortcut was rebound.
    func refreshHints() {
        let snip = ShortcutStore.shortcut(for: .snip).display
        let line = ShortcutStore.shortcut(for: .shelf).display
        hint.attributedStringValue = Self.text("\(snip) 截图　·　点图复制　·　悬浮预览　·　拖出去用　·　\(line) 收起",
                                               size: 11, alpha: 0.95)
        emptyLabel.attributedStringValue = Self.text("按 \(snip) 截一张，它就挂在这根线上",
                                                     size: 12, alpha: 0.8)
    }

    /// The hint sits over whatever happens to be behind the line — menu bar
    /// extras, a busy window — and plain white type disappeared against a light
    /// background. It gets its own dark pill, drawn here so the label itself
    /// still paints on top of it.
    override func draw(_ dirtyRect: NSRect) {
        guard !hint.isHidden, hint.frame.width > 0 else { return }
        let pill = hint.frame.insetBy(dx: -9, dy: -4)
        NSColor(calibratedWhite: 0.06, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
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

        // One path for the whole rope, stroked three times. The old version
        // stroked ~200 separate segments with a fresh NSShadow each, which cost
        // more than everything else on screen put together.
        let startX: CGFloat = -24
        let endX = width + 24
        let steps = 160
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: startX, y: ShelfContentView.ropeY(x: startX, width: width)))
        for step in 1...steps {
            let x = startX + (endX - startX) * CGFloat(step) / CGFloat(steps)
            path.line(to: NSPoint(x: x, y: ShelfContentView.ropeY(x: x, width: width)))
        }

        // A dark underlay instead of an NSShadow: a blur pass per frame was the
        // most expensive thing in the animation, and at 2pt the difference is
        // invisible.
        path.lineWidth = 3.0
        NSColor.black.withAlphaComponent(0.34).setStroke()
        path.stroke()

        // Core.
        path.lineWidth = 2.0
        NSColor(white: 0.58, alpha: 0.95).setStroke()
        path.stroke()

        // Highlight, nudged up by a hair.
        if let highlight = path.copy() as? NSBezierPath {
            highlight.transform(using: AffineTransform(translationByX: 0, byY: -0.7))
            highlight.lineWidth = 0.6
            NSColor.white.withAlphaComponent(0.55).setStroke()
            highlight.stroke()
        }
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
    /// One hover target for the whole line. Each card used to schedule its own
    /// preview, so sweeping across a few of them queued several of them and the
    /// last one to fire was not necessarily the one under the pointer.
    private weak var hovered: ThumbView?
    private var previewWork: DispatchWorkItem?

    var onCopy: ((ShotItem) -> Void)?
    var onOpen: ((ShotItem) -> Void)?
    var onSaveToDesktop: ((ShotItem) -> Void)?
    var onReveal: ((ShotItem) -> Void)?
    var onTrash: ((ShotItem) -> Void)?
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

    /// Debug hook: show the hover preview for one sheet.
    func debugPreview(_ index: Int) {
        guard index >= 0, index < thumbs.count else { return }
        thumbs[index].debugPreview()
    }

    func closePreviews() {
        previewWork?.cancel()
        previewWork = nil
        hovered = nil
        PreviewPanel.shared.hide()
    }

    /// The pointer entered a card (`thumb`), or left the line (`nil`).
    func pointer(on thumb: ThumbView?) {
        guard hovered !== thumb else { return }
        hovered = thumb
        previewWork?.cancel()
        previewWork = nil
        (host as? ShelfContentView)?.pauseWave(thumb != nil)
        guard let thumb else {
            PreviewPanel.shared.hide(after: 0.14)
            return
        }
        // Sheet-to-sheet moves fire an exit and an entry in one go; without
        // this the exit's scheduled hide lands after the new preview is up.
        PreviewPanel.shared.cancelHide()
        let work = DispatchWorkItem { [weak self, weak thumb] in
            guard let self, let thumb, self.hovered === thumb else { return }
            thumb.showPreviewNow()
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    /// Debug hook: pretend the pointer is on one card.
    func debugHover(_ index: Int) {
        guard index >= 0, index < thumbs.count else {
            pointer(on: nil)
            return
        }
        pointer(on: thumbs[index])
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
        return unit * 0.02   // about ±0.6°: hung by hand, not swaying
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
    var onPin: (() -> Void)?

    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var dragged = false
    private var pinsOnDrop = false
    private var dragStartScreen: CGPoint = .zero
    private var cardCache: CGImage?
    private var isRenderingCache = false
    private var cacheSize: NSSize = .zero
    private var cacheHover = false
    private var cacheScale: CGFloat = 0
    private var dropOffset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    private var dropTimer: Timer?
    private var swing: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    private var swingTimer: Timer?

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
                      height: max(26, height) + ShelfMetrics.inset * 2
                          + ShelfMetrics.pegHeight + ShelfMetrics.stampHeight)
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
                self.nudge(3)
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
            if elapsed > 1.2 {
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
        strip?.pointer(on: self)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        strip?.pointer(on: nil)
    }

    func cancelPreview(delay: TimeInterval = 0) {
        PreviewPanel.shared.hide(after: delay)
    }

    func showPreviewNow() { showPreview() }

    func debugPreview() { showPreview() }

    private func showPreview() {
        guard !dragged, let window else { return }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return }
        PreviewPanel.shared.show(item.url, near: onScreen, on: screen)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let cardTop = ShelfMetrics.pegHeight
        let card = CGRect(x: 0, y: cardTop,
                          width: bounds.width,
                          height: bounds.height - cardTop - ShelfMetrics.stampHeight)

        // The sheet only changes when its size or hover state does; the rope
        // animation just rotates it. Caching the drawing turns every animated
        // frame into one bitmap blit instead of a full redraw (thumbnail
        // scaling, shadow, text) for each card, twenty-four times a second.
        let scale = window?.backingScaleFactor ?? 2
        let stale = cardCache == nil || cacheSize != bounds.size
            || cacheHover != hovering || cacheScale != scale

        if isRenderingCache {
            // Collecting the cache: draw the sheet at rest, no rotation.
            drawFrame(card)
            drawPeg(at: CGPoint(x: card.midX, y: cardTop))
            return
        }
        if stale {
            cardCache = renderCard(size: bounds.size)
            cacheSize = bounds.size
            cacheHover = hovering
            cacheScale = scale
        }

        context.saveGState()
        context.translateBy(x: card.midX, y: cardTop + dropOffset)
        context.rotate(by: tilt + swing)
        context.translateBy(x: -card.midX, y: -cardTop)
        if let cgImage = cardCache {
            // The cached image comes from cacheDisplay, which renders in the
            // view's flipped space; CGImage drawing here works in a y-up space,
            // so mirror it around the middle.
            context.translateBy(x: 0, y: bounds.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -bounds.midY)
            context.interpolationQuality = .high
            context.draw(cgImage, in: bounds)
        } else {
            drawFrame(card)
            drawPeg(at: CGPoint(x: card.midX, y: cardTop))
        }
        context.restoreGState()
    }

    /// Uses AppKit's own view caching: it renders through the same path as an
    /// on-screen draw, so flipped coordinates and the peg's position come out
    /// right without hand-rolled transform gymnastics.
    private func renderCard(size: NSSize) -> CGImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        isRenderingCache = true
        cacheDisplay(in: bounds, to: rep)
        isRenderingCache = false
        return rep.cgImage
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

        drawStamp(below: card)
        if GIFFile.isAnimated(item.url) { drawGIFBadge(in: frameRect) }
    }

    /// A small "GIF" tag: without it a recording looks like a still capture on
    /// the line, and only the hover preview reveals that it moves.
    private func drawGIFBadge(in card: CGRect) {
        let text = "GIF" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .kern: 0.5
        ]
        let size = text.size(withAttributes: attributes)
        let plate = CGRect(x: card.maxX - size.width - 11,
                           y: card.minY + 5,
                           width: size.width + 8,
                           height: size.height + 4)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 3, yRadius: 3).fill()
        text.draw(at: NSPoint(x: plate.minX + 4, y: plate.minY + 2), withAttributes: attributes)
    }

    /// Time the shot was taken, in type small enough to read as a caption and
    /// not as a label competing with the picture.
    private func drawStamp(below card: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        // Today's shots only need a time; older ones need the date too.
        let formatter = Calendar.current.isDateInToday(item.created) ? Self.timeOnly : Self.withDate
        let text = formatter.string(from: item.created) as NSString
        let size = text.size(withAttributes: attributes)
        let centreY = card.maxY - ShelfMetrics.stampHeight / 2
        // A small plate behind the type: a wallpaper can be any colour, and a
        // 9pt line on its own disappears against a light one.
        let plate = CGRect(x: card.midX - size.width / 2 - 5,
                           y: centreY - size.height / 2 - 1.5,
                           width: size.width + 10,
                           height: size.height + 3)
        NSColor.black.withAlphaComponent(0.42).setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.height / 2, yRadius: plate.height / 2).fill()
        text.draw(at: NSPoint(x: plate.minX + 5, y: plate.minY + 1.5), withAttributes: attributes)
    }

    private static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let withDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

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
        // Plain drag hands the file to whoever accepts it (chat, Finder,
        // mail). Holding ⌥ asks Peg to pin the shot where you let go instead —
        // the drop target cannot make that distinction for us, because Finder
        // accepts file URLs and would copy the file before we ever heard about
        // it.
        pinsOnDrop = event.modifierFlags.contains(.option)
        dragStartScreen = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        let writer: NSPasteboardWriting = pinsOnDrop
            ? PinDragItem(url: item.url)
            : (item.url as NSURL)
        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        draggingItem.setDraggingFrame(bounds, contents: item.thumb)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        if pinsOnDrop {
            // Nobody accepts the private type, and the default behaviour for a
            // drag that ends "unaccepted" is to fly the thumbnail back to the
            // shelf. The pin appearing is the result, so drop that animation.
            session.animatesToStartingPositionsOnCancelOrFail = false
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // The drag session swallows the mouse-up, so `mouseUp` never runs and
        // `dragged` would stay set, silently keeping this sheet's hover preview
        // off until it is clicked again. Only `mouseDown` clears it otherwise.
        dragged = false
        guard pinsOnDrop else { return }
        pinsOnDrop = false
        // Esc lands here with an empty operation and the pointer barely moved;
        // that is a cancelled drag, not a request to pin.
        let cancelled = operation.isEmpty
            && hypot(screenPoint.x - dragStartScreen.x,
                     screenPoint.y - dragStartScreen.y) < 12
        if cancelled { return }
        PinController.shared.pinFile(at: item.url, centeredAt: screenPoint)
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelPreview()
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "复制") { [weak self] in self?.onCopy?() })
        menu.addItem(ClosureMenuItem(title: "贴到屏幕上") { [weak self] in self?.onPin?() })
        menu.addItem(ClosureMenuItem(title: "用「预览」打开") { [weak self] in self?.onOpen?() })
        menu.addItem(ClosureMenuItem(title: "保存到桌面") { [weak self] in self?.onSaveToDesktop?() })
        menu.addItem(ClosureMenuItem(title: "在访达中显示") { [weak self] in self?.onReveal?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "移入废纸篓") { [weak self] in self?.onTrash?() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
