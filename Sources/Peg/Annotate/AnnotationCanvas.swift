import AppKit

/// The image being marked up, at whatever size fits the screen, plus the marks
/// in image pixels.
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    let image: CGImage
    /// Points per image pixel.
    let scale: CGFloat

    private(set) var shapes: [AnnotationShape] = []
    var tool: AnnotationTool = .rect { didSet { needsDisplay = true } }
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 4
    var onChange: (() -> Void)?

    private var draft: AnnotationShape?
    private var textField: NSTextField?
    private var textAnchor: CGPoint = .zero
    private var isEditingText = false

    private lazy var baseImage = NSImage(cgImage: image,
                                         size: NSSize(width: image.width, height: image.height))
    private lazy var mosaicImage: CGImage? = AnnotationRenderer.makeMosaic(image)
    private lazy var blurredImage: CGImage? = AnnotationRenderer.makeBlur(image)

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: CGFloat(image.width) * scale,
                                 height: CGFloat(image.height) * scale))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }


    /// Used by the demo mode to show a populated canvas.
    func addShapes(_ new: [AnnotationShape]) {
        shapes.append(contentsOf: new)
        needsDisplay = true
        onChange?()
    }

    // MARK: - Editing

    func undo() {
        guard !shapes.isEmpty else { return }
        shapes.removeLast()
        needsDisplay = true
        onChange?()
    }

    func setTool(_ newTool: AnnotationTool) {
        endTextEditing(commit: true)
        tool = newTool
    }

    func endTextEditing(commit: Bool) {
        guard let field = textField else { return }
        let text = field.stringValue
        textField = nil
        isEditingText = false
        field.removeFromSuperview()

        if commit, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var shape = AnnotationShape(tool: .text, color: color, lineWidth: lineWidth)
            shape.start = textAnchor
            shape.text = text
            shape.fontSize = 26
            shapes.append(shape)
            onChange?()
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    // MARK: - Mouse

    private func toPixels(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / scale, y: point.y / scale)
    }

    override func mouseDown(with event: NSEvent) {
        if isEditingText {
            endTextEditing(commit: true)
            return
        }
        window?.makeFirstResponder(self)
        let point = toPixels(convert(event.locationInWindow, from: nil))

        if tool == .text {
            beginText(at: point)
            return
        }

        var shape = AnnotationShape(tool: tool, color: color, lineWidth: lineWidth)
        if tool == .pen || tool == .marker {
            shape.points = [point]
        } else {
            shape.start = point
            shape.end = point
        }
        draft = shape
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var shape = draft else { return }
        let point = toPixels(convert(event.locationInWindow, from: nil))
        if shape.tool == .pen || shape.tool == .marker {
            shape.points.append(point)
        } else {
            shape.end = point
        }
        draft = shape
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let shape = draft else { return }
        draft = nil
        if !shape.isDegenerate {
            shapes.append(shape)
            onChange?()
        }
        needsDisplay = true
    }

    private func beginText(at point: CGPoint) {
        endTextEditing(commit: true)

        let fontSize = 26 * scale
        let width = min(bounds.width - point.x * scale - 4, 360)
        let field = NSTextField(frame: NSRect(x: point.x * scale,
                                              y: point.y * scale,
                                              width: max(60, width),
                                              height: fontSize * 1.4))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = color
        field.delegate = self
        field.target = self
        field.action = #selector(commitText)
        addSubview(field)
        textAnchor = point
        textField = field
        isEditingText = true
        window?.makeFirstResponder(field)
    }

    @objc private func commitText() {
        endTextEditing(commit: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditingText else { return }
        endTextEditing(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing(commit: false)
            return true
        }
        return false
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                undo()
                return
            default:
                break
            }
        }
        if let index = Int(event.charactersIgnoringModifiers ?? ""), index >= 1, index <= 9 {
            if let newTool = AnnotationTool(rawValue: index - 1) {
                setTool(newTool)
                return
            }
        }
        super.keyDown(with: event)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        baseImage.draw(in: bounds)

        let space = DrawSpace(scale: scale, flipped: true, height: bounds.height)
        for shape in shapes {
            AnnotationRenderer.draw(shape, space: space, mosaic: mosaicImage,
                                    blurred: blurredImage,
                                    imageSize: CGSize(width: image.width, height: image.height))
        }

        if let draft {
            AnnotationRenderer.draw(draft, space: space, mosaic: mosaicImage,
                                    blurred: blurredImage,
                                    imageSize: CGSize(width: image.width, height: image.height))
        }
    }
}
