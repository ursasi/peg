import AppKit

/// The frozen screen plus everything that makes a snip feel direct: dimming,
/// a live rectangle, corner handles, pixel size, and a magnifier that reads the
/// real pixels underneath.
final class SelectionView: NSView, NSTextViewDelegate {
    private(set) var shot: Shot
    private var sampler: PixelSampler?
    weak var session: SnipSession?

    private lazy var frozen = makeFrozen()
    private func makeFrozen() -> NSImage { NSImage(cgImage: shot.image,
                                  size: NSSize(width: shot.image.width, height: shot.image.height)) }
    private var cursor: CGPoint?
    /// Set only by the demo mode, which has no real pointer to follow.
    var demoCursor: CGPoint?

    private var activeCursor: CGPoint? { cursor ?? demoCursor }

    private let dim = NSColor.black.withAlphaComponent(0.38)
    private let accent = NSColor.systemBlue

    /// A click that hit the action bar must not also reach the selection logic
    /// on its way up, or the release would reshuffle the rectangle.
    private var consumedClick = false
    private var textEditor: NSTextView?
    /// Only for the debug channel, which cannot rely on the window being key.
    var currentTextEditor: NSTextView? { textEditor }
    private var textAnchor: CGPoint = .zero
    /// Index of the caption being dragged, while one is being moved.
    private var movingTextIndex: Int?
    /// Index of a non-caption mark being dragged.
    private var movingShapeIndex: Int?
    private var movingShapeLast: CGPoint = .zero
    /// Caption under the pointer, shown as draggable.
    private var captionHover: Int?
    /// Index of an existing caption being re-edited.
    private var editingShape: Int?
    private var toast: String?
    /// Which handle the current drag grabbed, if any. `nil` while nothing is
    /// being moved or resized.
    private enum Grab {
        case move(CGRect)            // the selection as it was when the drag began
        case resize(Corner, CGRect)  // the corner being dragged, and the original box
    }
    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    private var grab: Grab?
    private var grabStart: CGPoint = .zero
    private var toastWork: DispatchWorkItem?
    private var movingTextLast: CGPoint = .zero
    private var previewSources: (mosaic: CGImage?, blur: CGImage?)?

    init(shot: Shot, sampler: PixelSampler?) {
        self.shot = shot
        self.sampler = sampler
        super.init(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Swaps in another frozen frame — the replay history walks through older
    /// captures on the same display.
    func replaceShot(_ newShot: Shot, sampler newSampler: PixelSampler?) {
        shot = newShot
        sampler = newSampler
        frozen = makeFrozen()
        needsDisplay = true
    }

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
        guard let window, textEditor == nil else { return }
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
            // An existing box is adjusted, never replaced, by a press on a
            // corner or inside it: a stray click used to throw the frame away
            // and start a new one.
            if let corner = corner(at: point, in: selection) {
                grab = .resize(corner, selection)
                grabStart = point
                consumedClick = true
                return
            }
            if selection.contains(point), session?.tool == nil,
               session?.textShapeIndex(at: point) == nil,
               session?.shapeIndex(at: point) == nil {
                grab = .move(selection)
                grabStart = point
                consumedClick = true
                return
            }
            // Double click re-opens a caption for editing; a single click picks
            // it up (and selects it, so the size controls follow).
            if event.clickCount >= 2, let index = session?.textShapeIndex(at: point) {
                commitPendingText()
                consumedClick = true
                session?.select(index)
                editExistingText(at: index)
                return
            }
            if let index = session?.textShapeIndex(at: point) {
                commitPendingText()
                consumedClick = true
                session?.select(index)
                movingTextIndex = index
                movingTextLast = point
                captionHover = nil
                needsDisplay = true
                return
            }
            // Any other mark can be selected too, and dragging its body moves
            // it: the wheel sizes the selection, the pointer moves it.
            if let index = session?.shapeIndex(at: point) {
                commitPendingText()
                session?.select(index)
                consumedClick = true
                movingShapeIndex = index
                movingShapeLast = point
                needsDisplay = true
                return
            }
            // A tool owns the click wherever it lands. Requiring it inside the
            // selection meant a click just outside started a whole new selection
            // instead of placing a caption. Esc leaves the tool when the
            // selection itself needs changing.
            if let tool = session?.tool {
                if tool == .text {
                    consumedClick = true
                    beginText(at: clamped(point, into: selection))
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

        session?.select(nil)
        session?.mouseDown(on: shot.screen, at: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        if let grab {
            let dx = point.x - grabStart.x
            let dy = point.y - grabStart.y
            switch grab {
            case .move(let start):
                let moved = start.offsetBy(dx: dx, dy: dy)
                let limit = bounds
                let x = min(max(moved.minX, limit.minX), limit.maxX - moved.width)
                let y = min(max(moved.minY, limit.minY), limit.maxY - moved.height)
                session?.setSelection(CGRect(x: x, y: y, width: moved.width, height: moved.height))
            case .resize(let corner, let start):
                var minX = start.minX, maxX = start.maxX
                var minY = start.minY, maxY = start.maxY
                switch corner {
                case .topLeft:     minX = point.x; minY = point.y
                case .topRight:    maxX = point.x; minY = point.y
                case .bottomLeft:  minX = point.x; maxY = point.y
                case .bottomRight: maxX = point.x; maxY = point.y
                }
                let minSize: CGFloat = 24
                if maxX - minX < minSize {
                    if corner == .topLeft || corner == .bottomLeft { minX = maxX - minSize } else { maxX = minX + minSize }
                }
                if maxY - minY < minSize {
                    if corner == .topLeft || corner == .topRight { minY = maxY - minSize } else { maxY = minY + minSize }
                }
                session?.setSelection(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
            needsDisplay = true
            return
        }
        if let index = movingShapeIndex {
            session?.moveShape(at: index,
                               by: CGSize(width: point.x - movingShapeLast.x,
                                          height: point.y - movingShapeLast.y))
            movingShapeLast = point
            needsDisplay = true
            return
        }
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
        if grab != nil {
            grab = nil
            consumedClick = false
            needsDisplay = true
            return
        }
        if movingTextIndex != nil || movingShapeIndex != nil {
            movingTextIndex = nil
            movingShapeIndex = nil
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

    /// A caption clicked outside the selection is pulled inside it: text drawn
    /// past the crop would never reach the saved image.
    private func clamped(_ point: CGPoint, into rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX + 4), max(rect.minX + 4, rect.maxX - 40)),
                y: min(max(point.y, rect.minY + 4), max(rect.minY + 4, rect.maxY - 30)))
    }

    /// The wheel sizes the active tool: no round trip to the bar for every
    /// step of the stroke.
    override func scrollWheel(with event: NSEvent) {
        guard session?.mode == .markup else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        if let editor = textEditor {
            // The box being typed is the current one, whatever else is drawn.
            session?.adjustSize(delta > 0 ? 1 : -1)
            if let size = session?.textSize {
                applyFont(size: size, to: editor)
                growText()
            }
            needsDisplay = true
            return
        }
        guard session?.tool != nil || session?.selectedShape != nil else {
            super.scrollWheel(with: event)
            return
        }
        session?.adjustSize(delta > 0 ? 1 : -1)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if textEditor == nil, event.keyCode == 8 {    // c copies the colour under the pointer
            copyColourUnderPointer(shift: event.modifierFlags.contains(.shift))
            return
        }
        if textEditor == nil, event.keyCode == 51 {   // ⌫ deletes the selected mark
            session?.deleteSelected()
            needsDisplay = true
            return
        }
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
            if let index = session?.selectedShape, editingShape == nil,
               let rect = session?.bounds(of: index) {
                drawObjectBox(rect.insetBy(dx: -6, dy: -5))
            }
            if let index = captionHover, let rect = session?.textRect(at: index) {
                let outline = NSBezierPath(rect: rect.insetBy(dx: -5, dy: -4))
                outline.lineWidth = 1
                outline.setLineDash([4, 3], count: 2, phase: 0)
                accent.withAlphaComponent(0.9).setStroke()
                outline.stroke()
            }
            drawBorder(selection)
            drawHandles(in: selection)
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

        if let toast {
            drawToast(toast)
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
        /// Opens the colour palette.
        case colour
        /// Step the active tool's size: stroke width, or type size for text.
        case sizeStep(CGFloat)
        /// The size readout: a button-sized label, not something to click.
        case noop
    }

    struct BarItem {
        let rect: CGRect
        let symbol: String
        let title: String
        let action: BarAction
        /// Set on the size readout, which draws this instead of an icon.
        var value: String?
    }

    private var barHover: Int = -1
    private static var symbolCache: [String: NSImage] = [:]

    /// Colours offered in the bar's palette. Snipaste's list, roughly.
    static let palette: [(String, NSColor)] = [
        ("红", .systemRed), ("橙", .systemOrange), ("黄", .systemYellow),
        ("绿", .systemGreen), ("蓝", .systemBlue), ("紫", .systemPurple),
        ("白", .white), ("黑", .black)
    ]

    private static let barSpec: [(symbol: String, title: String, action: BarAction)] = [
        ("rectangle", "矩形", .tool(.rect)),
        ("circle", "椭圆", .tool(.ellipse)),
        ("arrow.up.right", "箭头", .tool(.arrow)),
        ("pencil", "画笔", .tool(.pen)),
        ("highlighter", "荧光笔", .tool(.marker)),
        ("textformat", "文字", .tool(.text)),
        ("square.grid.3x3", "马赛克", .tool(.mosaic)),
        ("camera.filters", "模糊", .tool(.blur)),
        ("circle.fill", "颜色", .colour),
        ("arrow.uturn.backward", "撤销 ⌘Z", .undo),
        ("checkmark", "完成 ⏎", .copy),
        ("pin", "贴到屏幕 P", .pin),
        ("arrow.up.and.down", "长截图 L", .scroll)
    ]

    /// Tools, a size control for whichever of them is active, then the commit
    /// actions. The size has to be visible: `[` and `]` on their own left the
    /// stroke width a guess.
    private func specs() -> [(symbol: String, title: String, action: BarAction, width: CGFloat, value: String?)] {
        var all: [(String, String, BarAction, CGFloat, String?)] = Self.barSpec.map { spec in
            if case .colour = spec.action {
                return ("circle.fill", "颜色", spec.action, 34, nil)
            }
            // The commit button says 完成 in words: a bare tick left people
            // hunting for a ⏎ they had never been told about.
            if case .copy = spec.action {
                return (spec.symbol, "完成 ⏎ 或点这里", spec.action, 62, "完成")
            }
            return (spec.symbol, spec.title, spec.action, 34, nil)
        }
        let size: [(String, String, BarAction, CGFloat, String?)] = [
            ("minus", "变细 / 变小 [", .sizeStep(-1), 30, nil),
            ("", "当前大小", .noop, 58, sizeLabel),
            ("plus", "变粗 / 变大 ]", .sizeStep(1), 30, nil)
        ]
        all.insert(contentsOf: size, at: AnnotationTool.allCases.count)
        return all
    }

    private var sizeLabel: String {
        if session?.tool == .text { return "字号 \(Int(session?.textSize ?? 26))" }
        return "粗细 \(Int(session?.lineWidth ?? 4))"
    }

    func barItems(for selection: CGRect) -> [BarItem] {
        let button = NSSize(width: 34, height: 30)
        let gap: CGFloat = 3
        let sidePadding: CGFloat = 6
        let separator: CGFloat = 9
        let tools = AnnotationTool.allCases.count
        let specs = self.specs()
        let total = specs.reduce(0) { $0 + $1.width }
            + CGFloat(specs.count - 1) * gap
            + separator + sidePadding * 2
        let height = button.height + 10

        // Keep the bar on screen. A selection that fills the display (a whole
        // window, say) leaves no room below *or* above, so fall back to sitting
        // inside the bottom edge of the selection instead of sliding off.
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
        for (index, spec) in specs.enumerated() {
            if index == tools { x += separator }
            items.append(BarItem(rect: CGRect(x: x, y: origin.y + 5, width: spec.width, height: button.height),
                                 symbol: spec.symbol,
                                 title: spec.title,
                                 action: spec.action,
                                 value: spec.value))
            x += spec.width + gap
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

        // Marks are not clipped to the frame: shrinking the frame used to make
        // every mark outside it vanish, which felt like losing work. They stay
        // on the dimmed plate; the crop decides what ends up in the picture.
        let space = DrawSpace(scale: 1, flipped: true, height: bounds.height)
        for shape in session.visibleShapes {
            AnnotationRenderer.draw(shape, space: space, mosaic: mosaic, blurred: blurred,
                                    imageSize: bounds.size)
        }
    }

    // MARK: - Inline text

    /// A caption is edited in a real text view rather than a text field: a
    /// field is one line tall, so a line break or a wrapped line pushed its
    /// first line out of sight.
    /// Reopens a caption for editing, prefilled with what it says.
    private func editExistingText(at index: Int) {
        guard let shape = session?.shapes[index] else { return }
        // The wheel inside the box should act on this caption's size.
        session?.textSize = shape.fontSize
        editingShape = index
        session?.suppressedShape = index
        beginText(at: shape.start, text: shape.text)
    }

    private func beginText(at point: CGPoint, text: String = "") {
        endText(commit: true)
        // The size control applies to the caption being typed too, otherwise the
        // box shows one size and the mark lands at another.
        let size = session?.textSize ?? 26
        let width = min(max(120, bounds.width - point.x - 8), 460)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)

        // Integral geometry: a fractional origin or height makes AppKit render
        // text between pixels, which reads as blur — especially once the size
        // has been changed a few times.
        let origin = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        let view = NSTextView(frame: NSRect(x: origin.x, y: origin.y,
                                            width: width.rounded(.down),
                                            height: ceil(size * 1.4)),
                              textContainer: container)
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.font = .systemFont(ofSize: size, weight: .semibold)
        view.textColor = session?.color ?? .systemRed
        view.insertionPointColor = session?.color ?? .systemRed
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.delegate = self
        view.string = text
        addSubview(view)
        textAnchor = point
        textEditor = view
        session?.isEditingCaption = true
        // A brand-new caption has no mark yet, so nothing else may stay selected
        // or the wheel would resize that instead of the box being typed.
        if editingShape == nil { session?.select(nil) }

        // The overlay window is only orderFrontRegardless'd, so the very first
        // click can land on a window that is not key yet: entering the view
        // then silently fails and the user has to click again.
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Same trap as the old text field: a window that is on screen but not
        // key refuses the responder, and the first keystrokes go to the overlay
        // instead of the caption.
        if window?.makeFirstResponder(view) != true {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let view = self.textEditor else { return }
                    self.window?.makeKeyAndOrderFront(nil)
                    self.window?.makeFirstResponder(view)
                }
            }
        }
        growText()
    }

    /// Called by the session right before it crops: a half-typed caption must
    /// not be lost when the user hits ⏎ or clicks 完成.
    func commitPendingText() {
        endText(commit: true)
    }

    @objc private func commitText() {
        endText(commit: true)
        // ⏎ in the caption finishes the snip, the same as ⏎ on the overlay
        // itself.
        session?.commit(.copyAndSave)
    }

    private func endText(commit: Bool) {
        guard let view = textEditor else { return }
        let value = view.string
        textEditor = nil
        session?.isEditingCaption = false
        view.removeFromSuperview()
        session?.suppressedShape = nil
        if let index = editingShape {
            // Re-editing: change that caption, or drop it if it was emptied.
            if commit { session?.updateText(at: index, with: value) }
            editingShape = nil
        } else if commit {
            session?.addText(value, at: textAnchor)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// `c` copies the colour under the pointer as `#RRGGBB`; `⇧c` copies the
    /// same colour as `rgb(r, g, b)`. The magnifier already shows the value, so
    /// this saves reading it off the screen.
    private func copyColourUnderPointer(shift: Bool) {
        guard let point = activeCursor, let sampler else { return }
        let px = Int(point.x * shot.scale)
        let py = Int(point.y * shot.scale)
        guard let (r, g, b) = sampler.rgb(x: px, y: py) else { return }
        let text = shift
            ? "rgb(\(r), \(g), \(b))"
            : String(format: "#%02X%02X%02X", r, g, b)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showToast("已复制 \(text)")
        DebugLog.log("copy colour \(text)")
    }

    /// A short-lived pill, so a copy is visible without opening anything.
    private func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.toast = nil
                self?.needsDisplay = true
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        needsDisplay = true
    }

    /// Sets the caption's type size on the whole text, not just on the control:
    /// leaving the run with its old font made AppKit scale the glyphs up, which
    /// looked blurred.
    private func applyFont(size: CGFloat, to editor: NSTextView) {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        editor.font = font
        let whole = NSRange(location: 0, length: editor.textStorage?.length ?? 0)
        editor.textStorage?.addAttribute(.font, value: font, range: whole)
        editor.typingAttributes = [
            .font: font,
            .foregroundColor: session?.color ?? .systemRed
        ]
    }

    /// Keeps the editor tall enough for everything typed into it.
    private func growText() {
        guard let view = textEditor, let layout = view.layoutManager,
              let container = view.textContainer else { return }
        layout.ensureLayout(for: container)
        let needed = ceil(max(view.font?.pointSize ?? 26, layout.usedRect(for: container).height))
        guard abs(view.frame.height - needed) > 0.5 else { return }
        view.frame = NSRect(x: view.frame.origin.x.rounded(),
                            y: view.frame.origin.y.rounded(),
                            width: view.frame.width.rounded(.down),
                            height: needed)
        view.needsDisplay = true
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        growText()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // ⇧⏎ / ⌥⏎ is a line break; a bare ⏎ finishes the snip. AppKit sends
            // both as `insertNewline` from a text view, so the modifiers decide.
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                growText()
                return true
            }
            commitText()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil)
            growText()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endText(commit: false)
            return true
        default:
            return false
        }
    }

    /// Corners are 12 pt targets even though they are drawn smaller.
    private func corner(at point: CGPoint, in rect: CGRect) -> Corner? {
        let handles: [(Corner, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
        for (corner, centre) in handles {
            if abs(point.x - centre.x) <= 12, abs(point.y - centre.y) <= 12 { return corner }
        }
        return nil
    }

    /// The selected mark gets the same treatment as the frame: an outline and
    /// four corner dots, so it reads as an object you can act on.
    private func drawObjectBox(_ rect: CGRect) {
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 1.2
        outline.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        outline.stroke()
        for centre in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            let dot = CGRect(x: centre.x - 3, y: centre.y - 3, width: 6, height: 6)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dot).fill()
            accent.setStroke()
            let ring = NSBezierPath(ovalIn: dot)
            ring.lineWidth = 1.2
            ring.stroke()
        }
    }

    private func drawHandles(in rect: CGRect) {
        for corner in [Corner.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let centre = CGPoint(x: corner == .topLeft || corner == .bottomLeft ? rect.minX : rect.maxX,
                                 y: corner == .topLeft || corner == .topRight ? rect.minY : rect.maxY)
            let box = CGRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
            accent.setStroke()
            let edge = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            edge.lineWidth = 1.5
            edge.stroke()
        }
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
            } else if index == barHover, item.action != .noop {
                NSColor.white.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: item.rect, xRadius: 6, yRadius: 6).fill()
            }
            if case .colour = item.action {
                let dot = item.rect.insetBy(dx: 9, dy: 8)
                (session?.color ?? .systemRed).setFill()
                NSBezierPath(ovalIn: dot).fill()
                NSColor.white.withAlphaComponent(0.75).setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -0.5, dy: -0.5))
                ring.lineWidth = 1
                ring.stroke()
                continue
            }
            if let value = item.value {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.9)
                ]
                let size = (value as NSString).size(withAttributes: attributes)
                (value as NSString).draw(at: CGPoint(x: item.rect.midX - size.width / 2,
                                                    y: item.rect.midY - size.height / 2),
                                         withAttributes: attributes)
            } else if let image = Self.symbol(item.symbol) {
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
    }

    /// Pops the palette next to the swatch button.
    private func showPalette() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (name, colour) in Self.palette {
            let item = NSMenuItem(title: name, action: #selector(chooseColour(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = colour
            item.image = Self.swatch(colour)
            if session?.color == colour { item.state = .on }
            menu.addItem(item)
        }
        let anchor = NSPoint(x: cursor?.x ?? bounds.midX, y: (cursor?.y ?? bounds.midY) + 4)
        menu.popUp(positioning: nil, at: anchor, in: self)
    }

    @objc private func chooseColour(_ sender: NSMenuItem) {
        guard let colour = sender.representedObject as? NSColor else { return }
        session?.color = colour
        // A caption being typed should change with the palette too.
        if let editor = textEditor { applyFont(size: session?.textSize ?? 26, to: editor); editor.textColor = colour }
        needsDisplay = true
    }

    static func swatch(_ colour: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        colour.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let edge = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        edge.lineWidth = 1
        edge.stroke()
        image.unlockFocus()
        return image
    }

    private func drawTooltip(for item: BarItem, bar: CGRect) {
        var label = item.title
        if case .tool(let tool) = item.action {
            label += "　\(tool.key.uppercased())"
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
        var caption: Int?
        if next < 0, session?.mode == .markup, let point = cursor, movingTextIndex == nil {
            caption = session?.textShapeIndex(at: point)
        }
        if next != barHover || caption != captionHover {
            barHover = next
            captionHover = caption
            needsDisplay = true
        }
        if caption != nil { NSCursor.openHand.set() }
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
        case .colour: showPalette()
        case .sizeStep(let step): session?.adjustSize(step)
        case .noop: break
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
            text = "拖拽即可标注　⌘Z 撤销　Esc 回到选区　⇧⏎ 换行"
        } else if session?.mode == .direct {
            text = "拖拽选区，松开即复制并保存　L 滚动长截图　Esc 取消"
        } else {
            text = "拖拽选区　R/O/A/P/H/T/M/B 选工具　⏎ 复制并保存　P 贴到屏幕\nL 滚动长截图　Esc 取消"
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

    private func drawToast(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding = NSSize(width: 10, height: 6)
        let bubble = CGRect(x: bounds.midX - (size.width + padding.width * 2) / 2,
                            y: bounds.minY + 120,
                            width: size.width + padding.width * 2,
                            height: size.height + padding.height * 2)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 7, yRadius: 7).fill()
        (text as NSString).draw(at: CGPoint(x: bubble.minX + padding.width,
                                            y: bubble.minY + padding.height),
                                withAttributes: attributes)
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
