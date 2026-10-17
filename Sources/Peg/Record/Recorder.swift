import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Records a screen region and writes it out as an animated GIF.
///
/// Frames come from ScreenCaptureKit (the same permission the snip already
/// uses), sized to the region, and the frame budget keeps the file small enough
/// to paste into a chat.
@MainActor
final class Recorder {
    static let shared = Recorder()

    private(set) var isRecording = false
    private var task: Task<Void, Never>?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var frames: [CGImage] = []
    private var started = Date()
    private var hud: RecordHUD?
    private var border: RecordBorder?

    /// GIF playback rate. 12 fps reads as motion without ballooning the file.
    private let fps: Double = 12
    private let maxFrames = 240             // 20 seconds
    private let maxWidth: CGFloat = 900

    var elapsed: TimeInterval { Date().timeIntervalSince(started) }

    func begin(region: CGRect, on screen: NSScreen) async {
        guard !isRecording else { return }
        frames.removeAll()
        started = Date()

        let hud = RecordHUD()
        hud.onStop = { Recorder.shared.stop() }
        hud.show(near: region, on: screen)
        self.hud = hud

        // Without an outline there is no way to tell what is inside the frame.
        let border = RecordBorder(region: region, on: screen)
        border.show()
        self.border = border

        // Only the HUD and the frame are excluded: everything else Peg draws
        // (the clothesline, pinned shots) is fair game to record.
        let hidden = [hud.windowNumber, border.windowNumber].map { CGWindowID($0) }
        guard let session = await prepare(region: region, on: screen, hiding: hidden) else {
            DebugLog.log("record: could not prepare the capture stream")
            hud.close()
            border.close()
            self.hud = nil
            self.border = nil
            return
        }
        filter = session.filter
        configuration = session.configuration
        isRecording = true
        NSSound(named: "Tink")?.play()

        task = Task { [weak self] in
            while self?.isRecording == true {
                let started = Date()
                await self?.captureFrame()
                let spent = Date().timeIntervalSince(started)
                let wait = max(0, 1.0 / (self?.fps ?? 12) - spent)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// One capture stream for the recording, sized to the region.
    private func prepare(region: CGRect,
                         on screen: NSScreen,
                         hiding windowIDs: [CGWindowID]) async -> (filter: SCContentFilter, configuration: SCStreamConfiguration)? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let id = Displays.id(of: screen),
              let display = content.displays.first(where: { $0.displayID == id })
        else { return nil }

        let excluded = content.windows.filter { windowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: display.frame.minX + region.minX,
                                   y: display.frame.minY + region.minY,
                                   width: region.width,
                                   height: region.height)
        config.width = max(2, Int((region.width * scale).rounded()))
        config.height = max(2, Int((region.height * scale).rounded()))
        config.showsCursor = true
        config.scalesToFit = false
        config.captureResolution = .best
        return (filter, config)
    }

    private func captureFrame() async {
        guard isRecording, let filter, var configuration else { return }
        guard frames.count < maxFrames else {
            stop()
            return
        }
        // Keep the GIF small enough to paste around.
        let factor = min(1, maxWidth / CGFloat(configuration.width))
        if factor < 1 {
            configuration.width = max(2, Int((CGFloat(configuration.width) * factor).rounded()))
            configuration.height = max(2, Int((CGFloat(configuration.height) * factor).rounded()))
        }
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                     configuration: configuration),
              image.width > 0, image.height > 0
        else { return }
        frames.append(image)
        hud?.tick(elapsed: elapsed)
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        task?.cancel()
        task = nil
        filter = nil
        configuration = nil
        hud?.close()
        hud = nil
        border?.close()
        border = nil
        NSSound(named: "Pop")?.play()

        let captured = frames
        frames.removeAll()
        guard captured.count >= 2 else {
            DebugLog.log("record: too few frames (\(captured.count))")
            return
        }
        DispatchQueue.main.async {
            Recorder.finish(captured, fps: 12)
        }
    }

    private static func finish(_ frames: [CGImage], fps: Double) {
        guard let url = gifURL() else { return }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                               UTType.gif.identifier as CFString,
                                                               frames.count, nil) else { return }
        let loop: [CFString: Any] = [kCGImagePropertyGIFLoopCount: 0]
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: loop
        ] as CFDictionary)
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]
        ]
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return }
        Clip.copy(contentsOf: url)
        Shelf.shared.insert(url)
        Shelf.shared.flash()
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    private static func gifURL() -> URL? {
        let folder = Storage.folder
        var url = folder.appendingPathComponent("Peg \(stamp.string(from: Date())).gif")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Peg \(stamp.string(from: Date()))-\(counter).gif")
            counter += 1
        }
        return url
    }
}

/// The little "recording" pill: a red dot and a clock, click to stop.
final class RecordHUD: NSPanel {
    var onStop: (() -> Void)?
    private let label = NSTextField(labelWithString: "●  0:00")
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private var clock: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 132, height: 30),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 132, height: 30))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.86).cgColor
        view.layer?.cornerRadius = 15

        label.frame = NSRect(x: 14, y: 7, width: 72, height: 16)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        view.addSubview(label)

        stopButton.frame = NSRect(x: 86, y: 4, width: 40, height: 22)
        stopButton.bezelStyle = .inline
        stopButton.isBordered = false
        stopButton.contentTintColor = NSColor(calibratedRed: 1, green: 0.42, blue: 0.42, alpha: 1)
        stopButton.target = self
        stopButton.action = #selector(hitStop)
        view.addSubview(stopButton)

        contentView = view
    }

    func show(near region: CGRect, on screen: NSScreen) {
        // `region` is in top-left points; window frames are bottom-left.
        let size = frame.size
        let top = screen.frame.maxY - region.minY
        let bottom = screen.frame.maxY - region.maxY
        var origin = CGPoint(x: screen.frame.minX + region.midX - size.width / 2,
                             y: top + 10)
        if origin.y + size.height > screen.frame.maxY - 8 {
            origin.y = bottom - size.height - 10
        }
        origin.x = min(max(screen.frame.minX + 8, origin.x),
                       screen.frame.maxX - size.width - 8)
        origin.y = min(max(screen.frame.minY + 8, origin.y),
                       screen.frame.maxY - size.height - 8)
        setFrameOrigin(origin)
        orderFrontRegardless()

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Recorder.shared.isRecording else { return }
                self.tick(elapsed: Recorder.shared.elapsed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    func tick(elapsed: TimeInterval) {
        let seconds = Int(elapsed)
        label.stringValue = String(format: "●  %d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func hitStop() {
        onStop?()
    }

    override func close() {
        clock?.invalidate()
        clock = nil
        super.close()
    }
}

/// A thin red frame around the region being recorded. It is a separate window
/// from the HUD and is never captured: the recorder's content filter excludes
/// this app.
final class RecordBorder: NSPanel {
    private var region: CGRect
    private var screenRef: NSScreen

    init(region: CGRect, on screen: NSScreen) {
        self.region = region
        self.screenRef = screen
        let appKit = CGRect(x: screen.frame.minX + region.minX,
                            y: screen.frame.maxY - region.maxY,
                            width: region.width,
                            height: region.height)
        super.init(contentRect: appKit.insetBy(dx: -3, dy: -3),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = RecordBorderView(frame: NSRect(origin: .zero, size: frame.size))
    }

    func show() {
        orderFrontRegardless()
    }
}

private final class RecordBorderView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 3
        path.lineJoinStyle = .round
        NSColor.systemRed.withAlphaComponent(0.92).setStroke()
        path.stroke()

        // Inner hairline so the frame reads on light and dark backgrounds.
        let inner = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
        inner.lineWidth = 1
        NSColor.black.withAlphaComponent(0.25).setStroke()
        inner.stroke()
    }
}
