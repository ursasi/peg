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
        case .seeded(let rows):
            hud?.setStatus("已拼接 \(rows) 像素 · 在框内滚动（上下都行）")
        case .appended(let rows, let total):
            hud?.setStatus(rows < 0
                ? "已向上补 \(total) 像素 · \(stitcher.frames) 屏"
                : "已拼接 \(total) 像素 · \(stitcher.frames) 屏")
        case .failed:
            if ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1", let before = debugPrevious {
                NSLog("Peg scroll fail: %@", ScrollMatcher.diagnose(before, frame))
            }
            hud?.setStatus("这一下没对上 · 慢一点滚")
        case .unchanged, .ignored:
            break
        }
        if ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1" { debugPrevious = frame }
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
        let size = NSSize(width: 330, height: 112)
        var rect = CGRect(origin: .zero, size: size)

        if region.minY - size.height - 14 >= 0 {
            rect.origin = CGPoint(x: region.minX, y: region.minY - size.height - 14)
        } else if region.maxY + size.height + 14 <= screen.frame.height {
            rect.origin = CGPoint(x: region.minX, y: region.maxY + 14)
        } else {
            rect.origin = CGPoint(x: screen.frame.width - size.width - 18, y: 18)
        }
        rect.origin.x = min(max(8, rect.origin.x), screen.frame.width - size.width - 8)

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
    private let status = NSTextField(labelWithString: "在框内向下滚动")
    private let hint = NSTextField(labelWithString: "慢一点更准 · ⏎ 完成 · ⎋ 取消 · ⌃⌥X 也能完成")
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

        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = NSColor.white.withAlphaComponent(0.75)
        addSubview(status)

        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor.white.withAlphaComponent(0.4)
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

    func setStatus(_ text: String) {
        status.stringValue = text
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 16
        title.sizeToFit()
        title.frame.origin = NSPoint(x: pad, y: 14)
        status.sizeToFit()
        status.frame.origin = NSPoint(x: pad, y: 36)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: pad, y: bounds.height - 26)

        let buttonSize = NSSize(width: 68, height: 26)
        doneButton.frame = NSRect(x: bounds.width - pad - buttonSize.width,
                                  y: bounds.height - 42, width: buttonSize.width, height: buttonSize.height)
        cancelButton.frame = NSRect(x: doneButton.frame.minX - buttonSize.width - 8,
                                    y: doneButton.frame.minY, width: buttonSize.width, height: buttonSize.height)
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
