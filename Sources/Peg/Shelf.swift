import AppKit

struct ShotItem: Identifiable, Equatable {
    let url: URL
    let created: Date
    let thumb: NSImage

    var id: URL { url }

    static func == (a: ShotItem, b: ShotItem) -> Bool { a.url == b.url }
}

/// The clothesline: recent captures hang at the top of the screen, out of the
/// way until the pointer reaches the top edge.
@MainActor
final class Shelf {
    static let shared = Shelf()

    private(set) var items: [ShotItem] = [] {
        didSet { content?.setItems(items) }
    }

    private var panel: NSPanel?
    private var isShown = false
    private var hideWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var currentScreen: NSScreen?
    private var content: ShelfContentView?

    private var height: CGFloat { ShelfContentView.height }

    static var lineSize: LineSize {
        get { ShelfMetrics.lineSize }
        set { ShelfMetrics.lineSize = newValue }
    }

    func setSize(_ size: LineSize) {
        ShelfMetrics.lineSize = size
        content?.setItems(items)
        if isShown, let screen = currentScreen {
            reveal(on: screen)
        }
    }
    private let limit = 24

    // MARK: - Lifetime

    func start() {
        reload()
        startPointerPolling()
    }

    /// Polling the pointer position needs no permissions at all, unlike a
    /// global NSEvent monitor (which can be blocked or require Accessibility).
    private func startPointerPolling() {
        let timer = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Content

    func reload() {
        let folder = Storage.folder
        let limit = self.limit
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = Shelf.scan(folder: folder, limit: limit)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.items = items }
            }
        }
    }

    nonisolated private static func scan(folder: URL, limit: Int) -> [ShotItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        let recent = urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .compactMap { url -> (URL, Date)? in
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)

        return recent.compactMap { url, date in
            guard let thumb = Thumbnailer.make(url) else { return nil }
            return ShotItem(url: url, created: date, thumb: thumb)
        }
    }

    /// Puts a fresh capture at the front without re-reading the folder.
    func insert(_ url: URL) {
        guard !items.contains(where: { $0.url == url }) else {
            if let index = items.firstIndex(where: { $0.url == url }), index > 0 {
                let item = items.remove(at: index)
                items.insert(item, at: 0)
            }
            return
        }
        guard let thumb = Thumbnailer.make(url) else { return }
        let item = ShotItem(url: url, created: Date(), thumb: thumb)
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    private func recognize(_ item: ShotItem) {
        guard let image = NSImage(contentsOf: item.url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let screen = Displays.underMouse() ?? NSScreen.main
        Task { @MainActor in
            guard let text = await OCREngine.recognize(image), let screen else {
                NSSound.beep()
                return
            }
            Clip.copy(text)
            var near = CGRect(x: 240, y: 240, width: 300, height: 120)
            if let frame = panel?.frame {
                near = CGRect(x: frame.minX + 20, y: frame.minY, width: 300, height: 120)
            }
            OCRPanel.shared.show(text: text, near: near, on: screen)
        }
    }

    private func saveToDesktop(_ item: ShotItem) {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
        let target = desktop.appendingPathComponent(item.url.lastPathComponent)
        try? FileManager.default.copyItem(at: item.url, to: target)
    }

    func remove(_ item: ShotItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        items.removeAll { $0.url == item.url }
    }

    // MARK: - Show / hide

    func toggle() {
        if isShown { hideNow() } else { reveal() }
    }

    func flash() {
        reveal(autoHideAfter: 1.8)
    }

    func reveal(on screen: NSScreen? = nil, autoHideAfter seconds: TimeInterval? = nil) {
        guard let target = screen ?? Displays.underMouse() ?? NSScreen.main else { return }
        currentScreen = target
        hideWork?.cancel()
        hideWork = nil

        let panel = panel ?? makePanel()
        self.panel = panel

        // Hang below the menu bar, not over it.
        let top = target.visibleFrame.maxY
        let shown = NSRect(x: target.frame.minX, y: top - height, width: target.frame.width, height: height)

        if isShown {
            if panel.frame != shown { panel.setFrame(shown, display: true) }
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            isShown = true
            panel.alphaValue = 0
            panel.setFrame(shown.offsetBy(dx: 0, dy: 20), display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(shown, display: true)
            }
        }

        if let seconds { scheduleHide(after: seconds) }
    }

    func hideNow(animated: Bool = true) {
        hideWork?.cancel()
        hideWork = nil
        PreviewPanel.shared.hide()
        guard let panel, isShown else { return }
        isShown = false

        guard animated else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }

        var frame = panel.frame
        frame.origin.y += 20
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    private func scheduleHide(after seconds: TimeInterval) {
        // Polling runs ~11 times a second; rescheduling on every tick would
        // push the deadline out for ever.
        guard hideWork == nil else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideNow() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        // Above ordinary windows, below the menu bar.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false

        let content = ShelfContentView(frame: NSRect(x: 0, y: 0, width: 800, height: height))
        content.autoresizingMask = [.width, .height]
        content.onCopy = { item in Clip.copy(contentsOf: item.url) }
        content.onOpen = { item in NSWorkspace.shared.open(item.url) }
        content.onReveal = { item in Storage.reveal(item.url) }
        content.onSaveToDesktop = { [weak self] item in self?.saveToDesktop(item) }
        content.onTrash = { [weak self] item in self?.remove(item) }
        content.onPin = { item in
            PinController.shared.pinFile(at: item.url)
        }
        content.onOCR = { [weak self] item in self?.recognize(item) }
        content.setItems(items)
        self.content = content
        panel.contentView = content
        return panel
    }

    // MARK: - Pointer

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        if ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1" {
            NSLog("Peg tick y=%.1f shown=%d panel=%@", point.y, isShown ? 1 : 0,
                  panel.map { NSStringFromRect($0.frame) } ?? "nil")
        }
        guard SnipSession.shared.isActive == false else { return }

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }

        if !isShown {
            // Anywhere in the menu bar pulls the line down (the same gesture
            // Tendedero uses), not just the last two pixels of the display.
            if point.y >= screen.visibleFrame.maxY - 1 {
                reveal(on: screen)
            }
            return
        }

        guard let frame = panel?.frame else { return }
        // Inside the line, or still resting on the very top edge above it.
        if frame.contains(point) || point.y >= frame.maxY {
            hideWork?.cancel()
            hideWork = nil
            return
        }
        if point.y < frame.minY - 6 || currentScreen !== screen {
            scheduleHide(after: 0.3)
        }
    }
}
