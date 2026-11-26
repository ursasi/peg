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
    /// Whether the line is on screen right now. A snip only has to wait for it
    /// to slide away when it actually has something to slide away from.
    var isVisible: Bool { isShown }
    private var hideWork: DispatchWorkItem?
    private var revealWork: DispatchWorkItem?
    private var slideTimer: Timer?
    /// Bumped by every slide, so a hide that was already running when the line
    /// is asked back cannot order the panel out from under the new slide.
    private var slideGeneration = 0
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
        HistoryStore.purge()
        reload()
        startPointerPolling()
    }

    /// Polling the pointer position needs no permissions at all, unlike a
    /// global NSEvent monitor (which can be blocked or require Accessibility).
    private func startPointerPolling() {
        // 11 Hz: the dwell check needs a finer tick to feel immediate, and the
        // work is a pointer read plus two comparisons.
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
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = Shelf.scan(folder: folder, limit: limit)
            await MainActor.run { [weak self] in
                self?.items = items
            }
        }
    }

    nonisolated private static func scan(folder: URL, limit: Int) -> [ShotItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        let recent = urls
            .filter { HistoryStore.extensions.contains($0.pathExtension.lowercased()) }
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
    /// Screenshots for the README: invented shots, no files from disk.
    func setDemoItems(_ demo: [ShotItem]) {
        items = demo
    }

    func insert(_ url: URL) {
        PinController.shared.resetHistoryCursor()
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

    func debugPreview(_ index: Int) {
        content?.debugPreview(index)
    }

    func debugHover(_ index: Int) {
        content?.debugHover(index)
    }

    func debugScroll(_ x: CGFloat) {
        content?.debugScroll(x)
    }

    func toggle() {
        if isShown { hideNow() } else { reveal() }
    }

    /// A fresh capture: drop the line, then hang the sheet on it. The sheet used
    /// to fall while the panel was still sliding in, so the gesture was over
    /// before there was anything to see.
    func flash() {
        let wasShown = isShown
        reveal(autoHideAfter: 1.8)
        guard !wasShown else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated { self?.content?.dropInNewest() }
        }
    }

    func reveal(on screen: NSScreen? = nil, autoHideAfter seconds: TimeInterval? = nil) {
        revealWork?.cancel()
        revealWork = nil
        guard let target = screen ?? Displays.underMouse() ?? NSScreen.main else { return }
        currentScreen = target
        hideWork?.cancel()
        hideWork = nil

        let panel = panel ?? makePanel()
        self.panel = panel

        // Hang below the menu bar, not over it.
        let top = Displays.menuBarBottom(of: target)
        let shown = NSRect(x: target.frame.minX, y: top - height, width: target.frame.width, height: height)

        if isShown {
            if panel.frame != shown { panel.setFrame(shown, display: true) }
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            isShown = true
            slideIn(panel, to: shown, from: shown.offsetBy(dx: 0, dy: 34))
            // The rope comes down first; the sheets lift onto it one behind the
            // next once there is something to see.
            content?.settleAll()
        }

        content?.startWave()
        if let seconds { scheduleHide(after: seconds) }
    }

    /// Slides the line down with a small overshoot, the way a rope with paper
    /// on it settles. The old 0.12 s fade read as a flicker rather than as
    /// something arriving.
    private func slideIn(_ panel: NSPanel, to: NSRect, from: NSRect) {
        slideTimer?.invalidate()
        slideGeneration += 1
        let generation = slideGeneration
        let start = Date()
        let duration: TimeInterval = 0.34

        panel.alphaValue = 0
        panel.setFrame(from, display: false)
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak panel] timer in
            MainActor.assumeIsolated {
                guard let self, let panel, generation == self.slideGeneration else {
                    timer.invalidate()
                    return
                }
                let t = min(1, Date().timeIntervalSince(start) / duration)
                let eased = Shelf.settle(t)
                let y = from.minY + (to.minY - from.minY) * eased
                panel.setFrame(NSRect(x: to.minX, y: y, width: to.width, height: to.height),
                               display: true)
                // Fade quickly, then let the motion carry the rest: the line is
                // readable while it is still moving.
                panel.alphaValue = min(1, CGFloat(t / 0.3))
                if t >= 1 {
                    timer.invalidate()
                    self.slideTimer = nil
                    panel.setFrame(to, display: true)
                    panel.alphaValue = 1
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        slideTimer = timer
    }

    /// A damped spring normalised so 0 is fully raised and 1 is settled. It
    /// overshoots once by about 8%, which is what makes the line read as
    /// weighted rather than as a window being placed on screen.
    private static func settle(_ t: CGFloat) -> CGFloat {
        1 - exp(-5.5 * t) * cos(7 * t)
    }

    func hideNow(animated: Bool = true) {
        hideWork?.cancel()
        hideWork = nil
        revealWork?.cancel()
        revealWork = nil
        PreviewPanel.shared.hide()
        content?.stopWave()
        // A pick belongs to the visit; when the line slides away, the blue
        // frames should go with it instead of greeting the next visit.
        content?.clearSelection()
        guard let panel, isShown else { return }
        isShown = false

        guard animated else {
            slideTimer?.invalidate()
            slideTimer = nil
            slideGeneration += 1
            panel.alphaValue = 0
            finishHide(panel)
            return
        }

        slideTimer?.invalidate()
        slideGeneration += 1
        let generation = slideGeneration
        let from = panel.frame
        var to = from
        to.origin.y += 28
        let start = Date()
        let duration: TimeInterval = 0.19

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak panel] timer in
            MainActor.assumeIsolated {
                guard let self, let panel, generation == self.slideGeneration else {
                    timer.invalidate()
                    return
                }
                let t = min(1, Date().timeIntervalSince(start) / duration)
                // Ease in: it lifts away slowly, then goes.
                let eased = t * t
                panel.setFrame(NSRect(x: to.minX,
                                      y: from.minY + (to.minY - from.minY) * eased,
                                      width: to.width,
                                      height: to.height),
                               display: true)
                panel.alphaValue = 1 - t
                if t >= 1 {
                    timer.invalidate()
                    self.slideTimer = nil
                    self.finishHide(panel)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        slideTimer = timer
    }

    private func finishHide(_ panel: NSPanel) {
        panel.orderOut(nil)
        panel.alphaValue = 1
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

        // `NSRect.contains` excludes maxY, so a pointer resting exactly on the
        // top row of a display would match no screen at all.
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.insetBy(dx: 0, dy: -1).contains(point)
        }) else { return }

        if !isShown {
            // Only the very top edge of the display pulls the line down. That is
            // where macOS puts the menu bar, so reaching it is deliberate;
            // anywhere lower the pointer is usually on its way to click
            // something else, and pulling the line down there was the misfire.
            // When the bar is not set to hide itself it is always on screen, and
            // then the whole bar counts.
            let atTopEdge = point.y >= screen.frame.maxY - 2
            let barIsDrawn = screen.visibleFrame.maxY < screen.frame.maxY - 1
            let inDrawnBar = barIsDrawn && point.y >= Displays.menuBarBottom(of: screen) - 1
            if atTopEdge || inDrawnBar {
                armReveal(on: screen)
            } else {
                revealWork?.cancel()
                revealWork = nil
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
            if ShelfMetrics.linger <= 0 {
                hideNow()
            } else {
                scheduleHide(after: ShelfMetrics.linger)
            }
        }
    }

    /// The pointer has reached the top edge. The line only drops once it has
    /// rested there for the configured dwell: reaching for a menu should not
    /// summon it.
    private func armReveal(on screen: NSScreen) {
        guard revealWork == nil else { return }
        let dwell = ShelfMetrics.dwell
        guard dwell > 0 else {
            reveal(on: screen)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.revealWork = nil
                // A snip can start while the pointer is resting on the edge;
                // the line must not drop in the middle of it.
                guard !self.isShown, !SnipSession.shared.isActive else { return }
                self.reveal(on: screen)
            }
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }
}
