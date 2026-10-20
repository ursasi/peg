import AppKit

/// The frozen screen plus everything that makes a snip feel direct: dimming,
/// a live rectangle, corner handles, pixel size, and a magnifier that reads the
/// real pixels underneath.
final class SelectionView: NSView, NSTextFieldDelegate {
    let shot: Shot
    private let sampler: PixelSampler?
    weak var session: SnipSession?

    private lazy var frozen = NSImage(cgImage: shot.image,
                                      size: NSSize(width: shot.image.width, height: shot.image.height))
    private var cursor: CGPoint?
    /// Set only by the demo mode, which has no real pointer to follow.
    var demoCursor: CGPoint?

    private var activeCursor: CGPoint? { cursor ?? demoCursor }

    private let dim = NSColor.black.withAlphaComponent(0.38)
    private let accent = NSColor.systemBlue

    /// A click that hit the action bar must not also reach the selection logic
    /// on its way up, or the release would reshuffle the rectangle.
    private var consumedClick = false
    private var textField: NSTextField?
    private var textAnchor: CGPoint = .zero
    /// Index of the caption being dragged, while one is being moved.
    private var movingTextIndex: Int?
    private var movingTextLast: CGPoint = .zero
    private var previewSources: (mosaic: CGImage?, blur: CGImage?)?

    init(shot: Shot, sampler: PixelSampler?) {
        self.shot = shot
        self.sampler = sampler
        super.init(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - View plumbing

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private func takeFocus() {
        guard let window, textField == nil else { return }
        if !window.isKeyWindow { window.makeKey() }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }

    // MARK: - Events

    override func mouseMoved(with event: NSEvent) {
        takeFocus()
        followPointer(convert(event.locationInWindow, from: nil))
    }

    /// Called by the session's 0.09s poller too, so the window under the pointer
    /// is known even if the user never moves the mouse after pressing the hotkey.
    func followPointer(_ point: CGPoint) {
        cursor = point
        session?.updateHover(on: shot.screen, at: point)
        updateBarHover()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        takeFocus()
    }

    override func mouseExited(with event: NSEvent) {
        cursor = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        takeFocus()
        let point = convert(event.locationInWindow, from: nil)
        cursor = point

        if let selection = session?.selection(on: shot.screen), session?.mode == .markup {
            let items = barItems(for: selection)
            DebugLog.log("mouseDown \(point) selection=\(selection) bar=[\(items.first?.rect.minX ?? 0),\(items.first?.rect.minY ?? 0) \(items.last?.rect.maxX ?? 0),\(items.last?.rect.maxY ?? 0)]")
            for item in items where item.rect.contains(point) {
                DebugLog.log("bar hit: \(item.title)")
                perform(item.action)
                return
            }
            // With no tool up, a click on a placed caption picks it up instead
            // of starting a new selection.
            if session?.tool == nil, let index = session?.textShapeIndex(at: point) {
                consumedClick = true
                movingTextIndex = index
                movingTextLast = point
                return
            }
            if let tool = session?.tool, selection.contains(point) {
                if tool == .text {
                    consumedClick = true
                    beginText(at: point)
                } else {
                    session?.beginShape(at: point)
                }
                return
            }
        }

        if let rect = session?.selection(on: shot.screen), rect.contains(point) {
            // Clicking inside an existing selection keeps it; a double click
            // takes the snip straight to the clipboard.
            if event.clickCount == 2 {
                session?.commit(.copyAndSave)
            }
            return
        }

        session?.mouseDown(on: shot.screen, at: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        if let index = movingTextIndex {
            session?.moveText(at: index,
                              by: CGSize(width: point.x - movingTextLast.x,
                                         height: point.y - movingTextLast.y))
            movingTextLast = point
            needsDisplay = true
            return
        }
        if consumedClick { return }
        if session?.isDrafting == true {
            session?.updateShape(to: point)
            needsDisplay = true
            return
        }
        session?.mouseDragged(on: shot.screen, at: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        if movingTextIndex != nil {
            movingTextIndex = nil
            consumedClick = false
            needsDisplay = true
            return
        }
        if consumedClick {
            consumedClick = false
            return
        }
        if session?.isDrafting == true {
            session?.endShape()
            needsDisplay = true
            return
        }
        session?.mouseUp(on: shot.screen, at: point)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        session?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        if session?.keyDown(event) == true { return }
        super.keyDown(with: event)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endText(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endText(commit: false)
            return true
        }
        return false
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.imageInterpolation = .high
        frozen.draw(in: bounds)

        dim.setFill()
        bounds.fill()

        if let selection = session?.selection(on: shot.screen) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            frozen.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()

            drawMarks(in: selection)
            drawBorder(selection)
            drawSizeLabel(for: selection)
            if session?.mode == .markup {
                drawActionBar(for: selection)
                if session?.tool != nil { drawHint() }
            }
        } else if let hover = session?.windowHover, hover.width > 8, hover.height > 8 {
            // Un-dim the window under the pointer and ring it: one click grabs it.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: hover).addClip()
            frozen.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()

            let path = NSBezierPath(roundedRect: hover.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
            path.lineWidth = 2.5
            accent.withAlphaComponent(0.95).setStroke()
            path.stroke()
            drawSizeLabel(for: hover)
            drawCrosshair()
        } else {
            drawCrosshair()
            drawHint()
        }

        if activeCursor != nil, session?.allowsMagnifier(on: shot.screen) != false {
            drawMagnifier()
        }
    }

    private func drawBorder(_ rect: CGRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1
        accent.setStroke()
        path.stroke()

        // Corner ticks.
        let arm: CGFloat = 12
        let tick = NSBezierPath()
        tick.lineWidth = 2
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)
        ]
        for (point, dx, dy) in corners {
            tick.move(to: CGPoint(x: point.x + dx * arm, y: point.y))
            tick.line(to: point)
            tick.line(to: CGPoint(x: point.x, y: point.y + dy * arm))
        }
        accent.setStroke()
        tick.stroke()
    }

    private func drawSizeLabel(for rect: CGRect) {
        let w = Int((rect.width * shot.scale).rounded())
        let h = Int((rect.height * shot.scale).rounded())
        let text = "\(w) × \(h)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding = NSSize(width: 8, height: 4)
        var origin = CGPoint(x: rect.minX, y: rect.minY - size.height - padding.height * 2 - 6)
        if origin.y < 4 { origin.y = rect.minY + 6 }

        let box = CGRect(x: origin.x, y: origin.y,
                         width: size.width + padding.width * 2,
                         height: size.height + padding.height * 2)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height),
                                withAttributes: attributes)
    }

    private func drawCrosshair() {
        guard let cursor = activeCursor else { return }
        let line = NSBezierPath()
        line.lineWidth = 0.5
        line.move(to: CGPoint(x: 0, y: cursor.y + 0.25))
        line.line(to: CGPoint(x: bounds.maxX, y: cursor.y + 0.25))
        line.move(to: CGPoint(x: cursor.x + 0.25, y: 0))
        line.line(to: CGPoint(x: cursor.x + 0.25, y: bounds.maxY))
        NSColor.white.withAlphaComponent(0.55).setStroke()
        line.stroke()
    }

    // MARK: - Action bar

    /// One row of buttons under the selection, the way Snipaste puts its tools
    /// within reach instead of hiding them behind a keystroke.
    enum BarAction: Equatable {
        case tool(AnnotationTool)
        case undo
        case copy
        case pin
        case scroll
    }

    struct BarItem {
        let rect: CGRect
        let symbol: String
        let title: String
        let action: BarAction
    }

    private var barHover: Int = -1
    private static var symbolCache: [String: NSImage] = [:]

    private static let barSpec: [(symbol: String, title: String, action: BarAction)] = [
        ("rectangle", "矩形", .tool(.rect)),
        ("circle", "椭圆", .tool(.ellipse)),
        ("arrow.up.right", "箭头", .tool(.arrow)),
        ("pencil", "画笔", .tool(.pen)),
        ("highlighter", "荧光笔", .tool(.marker)),
        ("textformat", "文字", .tool(.text)),
        ("square.grid.3x3", "马赛克", .tool(.mosaic)),
        ("camera.filters", "模糊", .tool(.blur)),
        ("arrow.uturn.backward", "撤销 ⌘Z", .undo),
        ("checkmark", "完成 ⏎", .copy),
        ("pin", "贴到屏幕 P", .pin),
        ("arrow.up.and.down", "长截图 L", .scroll)
    ]

    func barItems(for selection: CGRect) -> [BarItem] {
        let button = NSSize(width: 34, height: 30)
        let gap: CGFloat = 3
        let sidePadding: CGFloat = 6
        let separator: CGFloat = 9
        let tools = AnnotationTool.allCases.count
        let total = CGFloat(Self.barSpec.count) * button.width
            + CGFloat(Self.barSpec.count - 1) * gap
            + separator + sidePadding * 2
        let height = button.height + 10

        // Keep the bar on screen. A selection that fills the display (a whole
        // window, say) leaves no room below *or* above, so fall back to sitting
        // inside the bottom edge of the selection instead of sliding off.
        // Centre the bar on the selection instead of hanging it off the left
        // edge: with a wide selection the buttons landed nowhere near the part
        // being annotated.
        var origin = CGPoint(x: selection.midX - total / 2, y: selection.maxY + 10)
        if origin.y + height > bounds.maxY - 4 {
            origin.y = selection.minY - height - 10
        }
        if origin.y < 4 {
            origin.y = min(selection.maxY - height - 8, bounds.maxY - height - 8)
        }
        origin.y = max(4, min(origin.y, bounds.maxY - height - 4))
        origin.x = max(4, min(origin.x, bounds.maxX - total - 4))

        var items: [BarItem] = []
        var x = origin.x + sidePadding
        for (index, spec) in Self.barSpec.enumerated() {
            if index == tools { x += separator }
            items.append(BarItem(rect: CGRect(x: x, y: origin.y + 5, width: button.width, height: button.height),
                                 symbol: spec.symbol,
                                 title: spec.title,
                                 action: spec.action))
            x += button.width + gap
        }
        return items
    }

    private func barBackground(for selection: CGRect) -> CGRect {
        let items = barItems(for: selection)
        guard let first = items.first, let last = items.last else { return .zero }
        return CGRect(x: first.rect.minX - 6, y: first.rect.minY - 5,
                      width: last.rect.maxX - first.rect.minX + 12,
                      height: first.rect.height + 10)
    }

    private func drawMarks(in selection: CGRect) {
        guard let session, !session.visibleShapes.isEmpty else { return }
        let needsMosaic = session.visibleShapes.contains { $0.tool == .mosaic }
        let needsBlur = session.visibleShapes.contains { $0.tool == .blur }
        var mosaic: CGImage?
        var blurred: CGImage?
        if needsMosaic || needsBlur {
            if previewSources == nil {
                previewSources = AnnotationRenderer.previewSources(for: shot.image)
            }
            mosaic = needsMosaic ? previewSources?.mosaic : nil
            blurred = needsBlur ? previewSources?.blur : nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        let space = DrawSpace(scale: 1, flipped: true, height: bounds.height)
        for shape in session.visibleShapes {
            AnnotationRenderer.draw(shape, space: space, mosaic: mosaic, blurred: blurred,
                                    imageSize: bounds.size)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Inline text

    private func beginText(at point: CGPoint) {
        endText(commit: true)
        let size: CGFloat = 26
        let width = min(max(80, bounds.width - point.x - 8), 420)
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y, width: width, height: size * 1.4))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: size, weight: .semibold)
        field.textColor = session?.color ?? .systemRed
        field.delegate = self
        field.target = self
        field.action = #selector(commitText)
        addSubview(field)
        textAnchor = point
        textField = field

        // The overlay window is only orderFrontRegardless'd, so the very first
        // click can land on a window that is not key yet: entering the field
        // then silently fails and the user has to click again.
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let focused = window?.makeFirstResponder(field) ?? false
        DebugLog.log("beginText focused=\(focused) responder=\(String(describing: window?.firstResponder)) key=\(window?.isKeyWindow ?? false)")
        guard !focused else { return }
        // Adding a field and focusing it in the same turn is unreliable; retry
        // once the run loop has laid it out.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let field = self.textField else { return }
                let ok = self.window?.makeFirstResponder(field) ?? false
                DebugLog.log("beginText retry focused=\(ok) responder=\(String(describing: self.window?.firstResponder))")
            }
        }
    }

    /// Called by the session right before it crops: a half-typed caption must
    /// not be lost when the user hits ⏎ or clicks 完成.
    func commitPendingText() {
        endText(commit: true)
    }

    @objc private func commitText() {
        endText(commit: true)
        // ⏎ in the caption finishes the snip, the same as ⏎ on the overlay
        // itself: typing a note and then hunting for the tick with the mouse
        // was the complaint, not the commit itself.
        session?.commit(.copyAndSave)
    }

    private func endText(commit: Bool) {
        guard let field = textField else { return }
        DebugLog.log("endText commit=\(commit)")
        let value = field.stringValue
        textField = nil
        field.removeFromSuperview()
        if commit { session?.addText(value, at: textAnchor) }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func drawActionBar(for selection: CGRect) {
        guard selection.width > 24, selection.height > 24 else { return }
        let background = barBackground(for: selection)
        let items = barItems(for: selection)
        NSColor(calibratedWhite: 0.10, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: background, xRadius: 8, yRadius: 8).fill()

        for (index, item) in items.enumerated() {
            let isActive: Bool = {
                if case .tool(let tool) = item.action { return session?.tool == tool }
                return false
            }()
            if isActive {
                accent.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: item.rect, xRadius: 6, yRadius: 6).fill()
            } else if index == barHover {
                NSColor.white.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: item.rect, xRadius: 6, yRadius: 6).fill()
            }
            if let image = Self.symbol(item.symbol) {
                let size = image.size
                image.draw(in: CGRect(x: item.rect.midX - size.width / 2,
                                      y: item.rect.midY - size.height / 2,
                                      width: size.width,
                                      height: size.height))
            }
        }

        // A hairline between the drawing tools and the commit actions.
        if items.count > AnnotationTool.allCases.count {
            let boundary = items[AnnotationTool.allCases.count]
            let line = NSBezierPath()
            line.move(to: CGPoint(x: boundary.rect.minX - 6, y: background.minY + 7))
            line.line(to: CGPoint(x: boundary.rect.minX - 6, y: background.maxY - 7))
            line.lineWidth = 1
            NSColor.white.withAlphaComponent(0.14).setStroke()
            line.stroke()
        }

        // An icon at 17 pt cannot say which tool it is — mosaic and blur read
        // alike — so hovering names it, with the digit that selects it.
        if barHover >= 0, barHover < items.count {
            drawTooltip(for: items[barHover], bar: background)
        }

        // `[` / `]` changed a size: say which one and to what, where the eyes
        // already are.
        if let hud = session?.sizeHUD {
            drawSizeHUD(hud, bar: background)
        }
    }

    private func drawSizeHUD(_ label: String, bar: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = label as NSString
        let size = text.size(withAttributes: attributes)
        let padding = NSSize(width: 9, height: 5)
        let bubbleSize = NSSize(width: size.width + padding.width * 2,
                                height: size.height + padding.height * 2)
        var origin = CGPoint(x: bar.midX - bubbleSize.width / 2,
                             y: bar.minY - bubbleSize.height - 6)
        if origin.y < 4 { origin.y = bar.maxY + 6 }
        let bubble = CGRect(origin: origin, size: bubbleSize)
        accent.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: bubble.minX + padding.width, y: bubble.minY + padding.height),
                  withAttributes: attributes)
    }

    private func drawTooltip(for item: BarItem, bar: CGRect) {
        var label = item.title
        if case .tool(let tool) = item.action {
            label += "　\(tool.rawValue + 1)"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = label as NSString
        let size = text.size(withAttributes: attributes)
        let padding = NSSize(width: 8, height: 5)
        let bubbleSize = NSSize(width: size.width + padding.width * 2,
                                height: size.height + padding.height * 2)
        var origin = CGPoint(x: item.rect.midX - bubbleSize.width / 2,
                             y: bar.minY - bubbleSize.height - 6)
        if origin.y < 4 { origin.y = bar.maxY + 6 }
        origin.x = max(4, min(origin.x, bounds.maxX - bubbleSize.width - 4))
        let bubble = CGRect(origin: origin, size: bubbleSize)
        NSColor(calibratedWhite: 0.05, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: bubble.minX + padding.width, y: bubble.minY + padding.height),
                  withAttributes: attributes)
    }

    private func updateBarHover() {
        var next = -1
        if let selection = session?.selection(on: shot.screen), session?.mode == .markup, let point = cursor {
            for (index, item) in barItems(for: selection).enumerated() where item.rect.contains(point) {
                next = index
            }
        }
        if next != barHover {
            barHover = next
            needsDisplay = true
        }
    }

    private func perform(_ action: BarAction) {
        // Whatever the button did, this click is spent: the release must not be
        // read as "resize the selection".
        consumedClick = true
        // Switching tools (or undoing) must not throw away a caption being typed.
        commitPendingText()
        switch action {
        case .tool(let tool):
            DebugLog.log("perform tool=\(tool)")
            // Clicking the active tool again returns to plain selection.
            session?.setTool(session?.tool == tool ? nil : tool)
            needsDisplay = true
        case .undo:
            session?.undo()
        case .copy: session?.commit(.copyAndSave)
        case .pin: session?.commit(.pin)
        case .scroll: session?.beginScrollFromBar()
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            DebugLog.log("missing symbol: \(name)")
            return nil
        }
        // Ask the symbol itself for white: drawing a template into an image and
        // tinting afterwards kept the glyphs dark on the dark bar.
        let config = NSImage.SymbolConfiguration(paletteColors: [.white])
            .applying(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        guard let configured = base.withSymbolConfiguration(config) else { return nil }
        symbolCache[name] = configured
        return configured
    }

    private func drawHint() {
        let text: String
        if session?.tool != nil {
            text = "在选区内拖拽即可标注　⌘Z 撤销　Esc 回到选区"
        } else if session?.mode == .direct {
            text = "拖拽选区，松开即复制并保存　L 滚动长截图　Esc 取消"
        } else {
            text = "拖拽选区　1–8 选工具直接标注　⏎ 复制并保存　P 贴到屏幕\nL 滚动长截图　Esc 取消"
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGRect(x: bounds.midX - size.width / 2 - 18,
                         y: bounds.midY - size.height / 2 - 10,
                         width: size.width + 36,
                         height: size.height + 20)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(in: box.insetBy(dx: 18, dy: 10), withAttributes: attributes)
    }

    private func drawMagnifier() {
        guard let cursor = activeCursor, let sampler else { return }

        let sourceWidth: CGFloat = 16
        let sourceHeight: CGFloat = 11
        let zoom: CGFloat = 8
        let boxSize = NSSize(width: sourceWidth * zoom, height: sourceHeight * zoom)

        var origin = CGPoint(x: cursor.x + 24, y: cursor.y + 24)
        if origin.x + boxSize.width > bounds.maxX - 8 {
            origin.x = cursor.x - boxSize.width - 24
        }
        if origin.y + boxSize.height + 56 > bounds.maxY - 8 {
            origin.y = cursor.y - boxSize.height - 24
        }
        let box = CGRect(origin: origin, size: boxSize)

        // Colour under the pointer, at pixel resolution.
        let px = Int(cursor.x * shot.scale)
        let py = Int(cursor.y * shot.scale)
        let colour = sampler.rgb(x: px, y: py)

        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8).fill()

        let halfW = sourceWidth / 2 * shot.scale
        let halfH = sourceHeight / 2 * shot.scale
        var source = CGRect(x: CGFloat(px) - halfW,
                            y: CGFloat(py) - halfH,
                            width: halfW * 2,
                            height: halfH * 2).integral
        source = source.intersection(CGRect(x: 0, y: 0,
                                            width: CGFloat(shot.image.width),
                                            height: CGFloat(shot.image.height)))
        if let crop = shot.image.cropping(to: source), source.width > 0, source.height > 0 {
            let image = NSImage(cgImage: crop, size: NSSize(width: source.width, height: source.height))
            let previous = NSGraphicsContext.current?.imageInterpolation ?? .high
            NSGraphicsContext.current?.imageInterpolation = .none
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).addClip()
            image.draw(in: box)
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = previous
        }

        // Crosshair in the middle of the magnified patch.
        let cross = NSBezierPath()
        cross.lineWidth = 1
        cross.move(to: CGPoint(x: box.midX, y: box.minY))
        cross.line(to: CGPoint(x: box.midX, y: box.maxY))
        cross.move(to: CGPoint(x: box.minX, y: box.midY))
        cross.line(to: CGPoint(x: box.maxX, y: box.midY))
        NSColor.white.withAlphaComponent(0.55).setStroke()
        cross.stroke()

        // Swatch + hex + pixel coordinate.
        let swatch = CGRect(x: box.minX, y: box.maxY + 8, width: 16, height: 16)
        if let colour {
            NSColor(srgbRed: CGFloat(colour.0) / 255,
                    green: CGFloat(colour.1) / 255,
                    blue: CGFloat(colour.2) / 255,
                    alpha: 1).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).fill()
            NSColor.white.withAlphaComponent(0.25).setStroke()
            NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).stroke()
        }

        let hex = colour.map { String(format: "#%02X%02X%02X", $0.0, $0.1, $0.2) } ?? "—"
        let label = "\(hex)   \(px), \(py)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        (label as NSString).draw(at: CGPoint(x: swatch.maxX + 7, y: swatch.minY + 2),
                                 withAttributes: attributes)
    }
}
