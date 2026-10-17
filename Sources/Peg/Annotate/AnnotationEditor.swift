import AppKit

/// Borderless key window that hosts the canvas and the toolbar, and turns the
/// marks into a bitmap on copy/save.
@MainActor
final class AnnotationEditor {
    static let shared = AnnotationEditor()

    private var panel: NSPanel?
    private var canvas: AnnotationCanvas?
    private var monitor: Any?

    var isOpen: Bool { panel != nil }

    func present(image: CGImage, on screen: NSScreen?) {
        close()

        let target = screen ?? Displays.underMouse() ?? NSScreen.main
        let backing = target?.backingScaleFactor ?? 2
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        var scale = max(1 / backing, min(1.0, 520 / CGFloat(max(image.width, image.height))))
        scale = min(scale, visible.width * 0.86 / CGFloat(image.width))
        scale = min(scale, visible.height * 0.68 / CGFloat(image.height))

        let canvas = AnnotationCanvas(image: image, scale: scale)
        let toolbar = AnnotationToolbar()
        self.canvas = canvas

        let padding: CGFloat = 14
        let toolbarHeight: CGFloat = 54
        let size = NSSize(width: canvas.intrinsicContentSize.width + padding * 2,
                          height: canvas.intrinsicContentSize.height + toolbarHeight + padding * 2)

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true

        canvas.frame = NSRect(x: padding, y: toolbarHeight + padding,
                              width: canvas.intrinsicContentSize.width,
                              height: canvas.intrinsicContentSize.height)
        canvas.autoresizingMask = []
        root.addSubview(canvas)

        toolbar.frame = NSRect(x: padding, y: padding,
                               width: size.width - padding * 2, height: toolbarHeight - 10)
        toolbar.autoresizingMask = [.width]
        root.addSubview(toolbar)

        toolbar.onTool = { [weak self] tool in self?.canvas?.setTool(tool) }
        toolbar.onColor = { [weak self] colour in self?.canvas?.color = colour }
        toolbar.onWidth = { [weak self] width in self?.canvas?.lineWidth = width }
        toolbar.onUndo = { [weak self] in self?.canvas?.undo() }
        toolbar.onCopy = { [weak self] in self?.copy() }
        toolbar.onSave = { [weak self] in self?.save() }
        toolbar.onDone = { [weak self] in self?.done() }

        let panel = EditorPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless],
                                backing: .buffered,
                                defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = root
        panel.center()
        if let visible = target?.visibleFrame {
            var frame = panel.frame
            frame.origin.x = min(max(frame.origin.x, visible.minX + 20), visible.maxX - frame.width - 20)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 20), visible.maxY - frame.height - 20)
            panel.setFrame(frame, display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel

        if ProcessInfo.processInfo.environment["PEG_DEMO_SHAPES"] == "1" {
            canvas.addShapes(AnnotationSample.shapes(for: image))
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Never swallow keys while the text tool has a field editor open.
        if let responder = panel?.firstResponder, responder is NSTextView || responder is NSTextField {
            return false
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(); return true
            case "s": save(); return true
            case "z": canvas?.undo(); return true
            case "w": close(); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 53: close(); return true
        case 36, 76, 49: done(); return true
        default: return false
        }
    }

    // MARK: - Output

    private func rendered() -> CGImage? {
        guard let canvas else { return nil }
        canvas.endTextEditing(commit: true)
        return AnnotationRenderer.flatten(canvas.image, shapes: canvas.shapes)
    }

    private func copy() {
        guard let image = rendered() else { close(); return }
        Clip.copy(image)
        close()
    }

    private func save() {
        guard let image = rendered() else { close(); return }
        if let url = Storage.save(image) {
            Shelf.shared.insert(url)
            Shelf.shared.flash()
        }
        close()
    }

    private func done() {
        guard let image = rendered() else { close(); return }
        Clip.copy(image)
        if let url = Storage.save(image) {
            Shelf.shared.insert(url)
        }
        Shelf.shared.flash()
        close()
    }

    func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        canvas = nil
    }
}

final class EditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Toolbar

final class AnnotationToolbar: NSView {
    var onTool: ((AnnotationTool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onDone: (() -> Void)?

    private let tools = NSSegmentedControl()
    private let widths = NSSegmentedControl()
    private var dots: [ColorDotButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
        layer?.cornerRadius = 10

        tools.segmentStyle = .texturedRounded
        tools.trackingMode = .selectOne
        for tool in AnnotationTool.allCases {
            tools.segmentCount += 1
            let index = tools.segmentCount - 1
            if let image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title) {
                tools.setImage(image, forSegment: index)
            } else {
                tools.setLabel(tool.title, forSegment: index)
            }
            tools.setWidth(34, forSegment: index)
            tools.setToolTip(tool.title, forSegment: index)
        }
        tools.selectedSegment = 0
        tools.target = self
        tools.action = #selector(toolChanged)
        addSubview(tools)

        for (index, colour) in AnnotationPalette.colors.enumerated() {
            let dot = ColorDotButton(color: colour)
            dot.tag = index
            dot.isSelectedDot = index == 0
            dot.target = self
            dot.action = #selector(colourChanged(_:))
            addSubview(dot)
            dots.append(dot)
        }

        widths.segmentStyle = .texturedRounded
        widths.trackingMode = .selectOne
        for (index, width) in AnnotationPalette.widths.enumerated() {
            widths.segmentCount += 1
            widths.setLabel(String(Int(width)), forSegment: index)
            widths.setWidth(28, forSegment: index)
        }
        widths.selectedSegment = 1
        widths.target = self
        widths.action = #selector(widthChanged)
        addSubview(widths)

        addSubview(makeButton("撤销", #selector(undo)))
        addSubview(makeButton("复制", #selector(copyAll)))
        addSubview(makeButton("保存", #selector(saveAll)))
        addSubview(makeButton("完成", #selector(done)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var actionButtons: [NSButton] = []

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        actionButtons.append(button)
        return button
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x: CGFloat = 10

        tools.frame = NSRect(x: x, y: (height - 24) / 2, width: 8 * 34, height: 24)
        x = tools.frame.maxX + 12

        for dot in dots {
            dot.frame = NSRect(x: x, y: (height - 20) / 2, width: 20, height: 20)
            x += 24
        }
        x += 8

        widths.frame = NSRect(x: x, y: (height - 24) / 2, width: 3 * 28, height: 24)
        x = widths.frame.maxX + 12

        var right = bounds.width - 10
        for button in actionButtons.reversed() {
            button.sizeToFit()
            let width = max(52, button.frame.width + 8)
            button.frame = NSRect(x: right - width, y: (height - 24) / 2, width: width, height: 24)
            right = button.frame.minX - 6
        }
    }

    @objc private func toolChanged() {
        guard let tool = AnnotationTool(rawValue: tools.selectedSegment) else { return }
        onTool?(tool)
    }

    @objc private func colourChanged(_ sender: ColorDotButton) {
        for dot in dots { dot.isSelectedDot = dot === sender }
        onColor?(sender.color)
    }

    @objc private func widthChanged() {
        let index = max(0, min(AnnotationPalette.widths.count - 1, widths.selectedSegment))
        onWidth?(AnnotationPalette.widths[index])
    }

    @objc private func undo() { onUndo?() }
    @objc private func copyAll() { onCopy?() }
    @objc private func saveAll() { onSave?() }
    @objc private func done() { onDone?() }
}

final class ColorDotButton: NSButton {
    let color: NSColor
    var isSelectedDot = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 3
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        color.setFill()
        circle.fill()
        (isSelectedDot ? NSColor.white : NSColor.white.withAlphaComponent(0.3)).setStroke()
        circle.lineWidth = isSelectedDot ? 2.5 : 1
        circle.stroke()
    }
}
