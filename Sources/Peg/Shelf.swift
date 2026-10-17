import AppKit
import Combine
import SwiftUI

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
final class Shelf: ObservableObject {
    static let shared = Shelf()

    @Published private(set) var items: [ShotItem] = []

    private var panel: NSPanel?
    private var isShown = false
    private var hideWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var currentScreen: NSScreen?

    private let height: CGFloat = 168
    private let limit = 24

    // MARK: - Lifetime

    func start() {
        reload()
        installPointerMonitors()
    }

    private func installPointerMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            // Both monitors deliver on the main thread.
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(local)
        }
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
        let width = target.frame.width
        let shown = NSRect(x: target.frame.minX, y: top - height, width: width, height: height)
        let hidden = NSRect(x: target.frame.minX, y: top, width: width, height: height)

        if isShown {
            if panel.frame != shown { panel.setFrame(shown, display: true) }
            panel.orderFrontRegardless()
        } else {
            panel.setFrame(hidden, display: false)
            panel.orderFrontRegardless()
            panel.setFrame(shown, display: true, animate: true)
            isShown = true
        }

        if let seconds { scheduleHide(after: seconds) }
    }

    func hideNow(animated: Bool = true) {
        hideWork?.cancel()
        hideWork = nil
        guard let panel, isShown else { return }
        isShown = false
        var frame = panel.frame
        frame.origin.y = (currentScreen?.visibleFrame.maxY ?? frame.maxY)
        if animated {
            panel.setFrame(frame, display: true, animate: true)
        } else {
            panel.setFrame(frame, display: false)
            panel.orderOut(nil)
        }
    }

    private func scheduleHide(after seconds: TimeInterval) {
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
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false

        let host = NSHostingView(rootView: ShelfView(store: self))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: height)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    // MARK: - Pointer

    private func pointerMoved() {
        guard SnipSession.shared.isActive == false else { return }

        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }

        if !isShown {
            // Rest the pointer on the very top edge to pull the line down.
            if point.y >= screen.frame.maxY - 2 {
                reveal(on: screen)
            }
            return
        }

        guard let frame = panel?.frame else { return }
        if frame.contains(point) {
            hideWork?.cancel()
            hideWork = nil
            return
        }
        if point.y < frame.minY - 6 || currentScreen !== screen {
            scheduleHide(after: 0.3)
        }
    }
}
