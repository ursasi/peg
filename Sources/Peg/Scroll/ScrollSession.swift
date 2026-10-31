import AppKit
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
import VideoToolbox

/// Scrolling capture: the user scrolls a window by hand, we sample the chosen
/// region, stitch what moved, and hand back one tall image.
///
/// Manual scrolling is deliberate. Driving the scroll from here would need the
/// Accessibility permission and would fight momentum; sampling frames needs
/// nothing but the screen recording permission we already have.
@MainActor
final class ScrollSession {
    static let shared = ScrollSession()

    private(set) var isActive = false

    private var screen: NSScreen?
    private var region: CGRect = .zero      // top-left origin, screen-local points
    private var border: NSWindow?
    private var hud: ScrollHUD?
    private var filter: SCContentFilter?
    private var display: SCDisplay?
    private var stream: SCStream?
    private var receiver: ScrollFrameReceiver?
    private var busy = false
    private var expectedSize: CGSize = .zero
    private var screenScale: CGFloat = 2
    private var lastTimestamp: Double = -1

    private var stitcher = ScrollStitcher()
    private var task: Task<Void, Never>?

    // MARK: - Lifecycle

    func start(region: CGRect, screen: NSScreen) {
        guard !isActive else { return }
        isActive = true
        self.screen = screen
        self.region = region
        stitcher = ScrollStitcher()

        showBorder(on: screen)
        let hud = ScrollHUD()
        hud.onFinish = { [weak self] in self?.finish() }
        hud.onCancel = { [weak self] in self?.cancel() }
        hud.show(region: region, on: screen)
        self.hud = hud

        startStream()

        if let raw = ProcessInfo.processInfo.environment["PEG_SCROLL_AUTOFINISH"],
           let seconds = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated { self?.finish() }
            }
        }
    }

    func cancel() {
        guard isActive else { return }
        stop()
    }

    func finish() {
        guard isActive else { return }
        let image = stitcher.image()
        stop()
        guard let image else { return }
        Clip.copy(image)
        if let url = Storage.save(image) {
            Shelf.shared.insert(url)
        }
        Shelf.shared.flash()
    }

    private func stop() {
        isActive = false
        task?.cancel()
        task = nil
        border?.orderOut(nil)
        border = nil
        hud?.close()
        hud = nil
        stream?.stopCapture { _ in }
        stream = nil
        receiver = nil
        filter = nil
        display = nil
        busy = false
        stitcher = ScrollStitcher()
    }

    // MARK: - Sampling

    private func startStream() {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.openStream()
            } catch {
                self.hud?.setStatus("无法采集：\(error.localizedDescription)")
            }
        }
    }

    private func openStream() async throws {
        guard let screen, let displayID = Displays.id(of: screen) else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let match = content.displays.first(where: { $0.displayID == displayID }) else {
            hud?.setStatus("找不到显示器")
            return
        }
        let me = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = me.map {
            SCContentFilter(display: match, excludingApplications: [$0], exceptingWindows: [])
        } ?? SCContentFilter(display: match, excludingWindows: [])
        let mode = CGDisplayCopyDisplayMode(match.displayID)
        screenScale = CGFloat(mode?.pixelWidth ?? match.width) / max(1, screen.frame.width)
        expectedSize = CGSize(width: (region.width * screenScale).rounded(),
                              height: (region.height * screenScale).rounded())

        let config = SCStreamConfiguration()
        // Only ask for the selection, at native pixels.
        config.sourceRect = region
        config.width = Int(expectedSize.width)
        config.height = Int(expectedSize.height)
        config.showsCursor = false
        config.scalesToFit = false
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.queueDepth = 4

        let receiver = ScrollFrameReceiver { [weak self] image, timestamp in
            MainActor.assumeIsolated { self?.handleFrame(image, timestamp: timestamp) }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
        try await stream.startCapture()

        self.filter = filter
        self.display = match
        self.receiver = receiver
        self.stream = stream
        if ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1" {
            NSLog("Peg scroll stream %dx%d sourceRect=%@ scale=%.2f",
                  Int(expectedSize.width), Int(expectedSize.height),
                  NSStringFromRect(region), screenScale)
        }
    }

    /// Called for every delivered frame, on the main actor. Frames that arrive
    /// while the previous one is still being matched are dropped: stitching an
    /// older frame after a newer one would corrupt the join.
    private func handleFrame(_ image: CGImage, timestamp: Double) {
        guard isActive, !busy else { return }
        if timestamp > 0, timestamp <= lastTimestamp { return }
        lastTimestamp = timestamp
        busy = true
        defer { busy = false }

        let frame: ScrollFrame?
        if abs(CGFloat(image.width) - expectedSize.width) < 2,
           abs(CGFloat(image.height) - expectedSize.height) < 2 {
            frame = ScrollFrame(image: image)
        } else {
            // sourceRect was ignored: crop out of the full frame.
            let scale = CGFloat(image.width) / max(1, screen?.frame.width ?? 1)
            let rect = CGRect(x: region.minX * scale,
                              y: region.minY * scale,
                              width: region.width * scale,
                              height: region.height * scale).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard rect.width >= 8, rect.height >= 8, let cropped = image.cropping(to: rect) else { return }
            frame = ScrollFrame(image: cropped)
        }
        guard let frame else { return }
        if ProcessInfo.processInfo.environment["PEG_DUMP"] == "1", dumpedFrames < 40 {
            dumpFrame(frame)
        }
        let started = Date()
        ingest(frame)
        if ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1" {
            NSLog("Peg scroll frame %dx%d took %.0f ms", frame.width, frame.height,
                  Date().timeIntervalSince(started) * 1000)
        }
    }

    private var dumpedFrames = 0

    private func dumpFrame(_ frame: ScrollFrame) {
        dumpedFrames += 1
        guard let provider = CGDataProvider(data: Data(frame.bytes) as CFData),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return }
        let url = URL(fileURLWithPath: String(format: "/tmp/pegdump-%03d.png", dumpedFrames))
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    private func ingest(_ frame: ScrollFrame) {
        guard isActive else { return }
        let update = stitcher.ingest(frame)
        if ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1" {
            NSLog("Peg scroll %dx%d -> %@", frame.width, frame.height, String(describing: update))
        }
        switch update {
        case .seeded, .appended:
            updatePreview()
        case .failed:
            if ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1", let before = debugPrevious {
                NSLog("Peg scroll fail: %@", ScrollMatcher.diagnose(before, frame))
            }
        case .unchanged, .ignored:
            break
        }
        if ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1" { debugPrevious = frame }
    }

    /// The preview is sampled directly from the stitcher's row store, so it is
    /// cheap enough to refresh on every frame that actually adds content.
    private func updatePreview() {
        hud?.setPreview(stitcher.previewImage())
    }

    private var debugPrevious: ScrollFrame?

    // MARK: - Overlay

    private func showBorder(on screen: NSScreen) {
        let window = NSWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true   // the real window underneath must scroll
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.contentView = ScrollBorderView(region: region)
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
        border = window
    }
}

/// Dims everything outside the region and outlines it.
final class ScrollBorderView: NSView {
    private let region: CGRect

    init(region: CGRect) {
        self.region = region
        super.init(frame: NSRect(origin: .zero, size: region.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: region))
        outside.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.30).setFill()
        outside.fill()

        let borderPath = NSBezierPath(rect: region.insetBy(dx: -0.5, dy: -0.5))
        borderPath.lineWidth = 1.5
        NSColor.systemBlue.setStroke()
        borderPath.stroke()
    }
}

/// The little panel with the progress and the two buttons.
@MainActor
final class ScrollHUD {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private var content: ScrollHUDView?

    func show(region: CGRect, on screen: NSScreen) {
        let size = NSSize(width: 250, height: 350)
        let gap: CGFloat = 14
        let margin: CGFloat = 8

        // Beside the region first (right, then left), so the preview and the
        // thing being captured can be watched together. Only fall back to
        // above/below when the screen is too narrow.
        var origin = CGPoint(x: region.maxX + gap,
                             y: region.midY - size.height / 2)
        if origin.x + size.width > screen.frame.width - margin {
            let left = region.minX - size.width - gap
            if left >= margin {
                origin.x = left
            } else if region.maxY + gap + size.height <= screen.frame.height - margin {
                origin = CGPoint(x: region.minX, y: region.maxY + gap)
            } else if region.minY - gap - size.height >= margin {
                origin = CGPoint(x: region.minX, y: region.minY - size.height - gap)
            }
        }
        origin.x = min(max(margin, origin.x), screen.frame.width - size.width - margin)
        origin.y = min(max(margin, origin.y), screen.frame.height - size.height - margin)
        let rect = CGRect(origin: origin, size: size)

        let view = ScrollHUDView(frame: rect)
        view.onFinish = { [weak self] in self?.onFinish?() }
        view.onCancel = { [weak self] in self?.onCancel?() }
        content = view

        let panel = NSPanel(contentRect: Displays.appKitRect(fromLocalTopLeft: rect, on: screen),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        self.panel = panel
    }

    func setStatus(_ text: String) {
        content?.setStatus(text)
    }

    func setPreview(_ image: CGImage?) {
        content?.setPreview(image)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        content = nil
    }
}

final class ScrollHUDView: NSView {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let title = NSTextField(labelWithString: "滚动截图")
    private let preview = ScrollPreviewView(frame: .zero)
    private let hint = NSTextField(labelWithString: "⏎ 完成　·　⎋ 取消　·　⌃⌥X 也能完成")
    private let doneButton = NSButton(title: "完成", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        addSubview(title)

        preview.message = "在框内滚动"
        addSubview(preview)

        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor.white.withAlphaComponent(0.45)
        addSubview(hint)

        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(finish)
        doneButton.keyEquivalent = "\r"
        addSubview(doneButton)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        addSubview(cancelButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setPreview(_ image: CGImage?) {
        preview.image = image
    }

    /// Used only for real failures (the stream could not start). Normal
    /// progress is shown as the picture itself, not as a row count.
    func setStatus(_ text: String) {
        preview.message = text
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        title.sizeToFit()
        title.frame.origin = NSPoint(x: pad, y: 14)

        let buttonSize = NSSize(width: 68, height: 26)
        let buttonY = bounds.height - pad - buttonSize.height
        hint.sizeToFit()
        let hintY = buttonY - 8 - hint.frame.height
        hint.frame.origin = NSPoint(x: pad, y: hintY)

        preview.frame = NSRect(x: pad,
                               y: title.frame.maxY + 10,
                               width: bounds.width - pad * 2,
                               height: max(60, hintY - 10 - (title.frame.maxY + 10)))

        doneButton.frame = NSRect(x: bounds.width - pad - buttonSize.width,
                                  y: buttonY, width: buttonSize.width, height: buttonSize.height)
        cancelButton.frame = NSRect(x: doneButton.frame.minX - buttonSize.width - 8,
                                    y: buttonY, width: buttonSize.width, height: buttonSize.height)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onFinish?()
        default: super.keyDown(with: event)
        }
    }

    @objc private func finish() { onFinish?() }
    @objc private func cancel() { onCancel?() }
}

/// The live stitched picture. It is fitted into the card so the growth reads
/// even when the result becomes much taller than it is wide.
final class ScrollPreviewView: NSView {
    var image: CGImage? {
        didSet {
            if image != nil { message = nil }
            needsDisplay = true
        }
    }

    var message: String? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.055).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        if let image, image.width > 0, image.height > 0 {
            let available = bounds.insetBy(dx: 5, dy: 5)
            let scale = min(available.width / CGFloat(image.width),
                            available.height / CGFloat(image.height))
            let size = CGSize(width: max(1, CGFloat(image.width) * scale),
                              height: max(1, CGFloat(image.height) * scale))
            let frame = CGRect(x: available.midX - size.width / 2,
                               y: available.midY - size.height / 2,
                               width: size.width, height: size.height)

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: image,
                    size: NSSize(width: image.width, height: image.height)).draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()

            NSColor.white.withAlphaComponent(0.16).setStroke()
            let border = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            border.lineWidth = 1
            border.stroke()
        }

        if let message, !message.isEmpty {
            draw(message)
        }
    }

    private func draw(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: paragraph
        ]
        let maxWidth = max(40, bounds.width - 28)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes)
        let size = CGSize(width: min(maxWidth, ceil(measured.width) + 18),
                          height: ceil(measured.height) + 12)
        let plate = CGRect(x: bounds.midX - size.width / 2,
                           y: bounds.midY - size.height / 2,
                           width: size.width, height: size.height)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(with: plate.insetBy(dx: 9, dy: 6),
                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attributes)
    }
}
