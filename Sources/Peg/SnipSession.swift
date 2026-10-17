import AppKit
import CoreGraphics

/// One snip: freeze every screen, let the user drag a rectangle on any of them,
/// then crop at native resolution and hand the result off.
@MainActor
final class SnipSession {
    static let shared = SnipSession()

    enum Finish {
        case copyAndSave
        case pin
    }

    private(set) var isActive = false
    private var windows: [SelectionWindow] = []
    private var shots: [CGDirectDisplayID: Shot] = [:]
    private var samplers: [CGDirectDisplayID: PixelSampler] = [:]

    /// Selection state is kept for one screen at a time, in that screen's own
    /// top-left-origin points. Dragging across displays is deliberately not
    /// supported: it would need mixed scale factors composited into one image.
    private var activeScreen: NSScreen?
    private var anchor: CGPoint?
    private var current: CGPoint?

    // MARK: - Start / stop

    func begin() {
        guard !isActive else { return }
        guard Permissions.ensure() else { return }
        isActive = true
        Shelf.shared.hideNow(animated: false)

        Task { @MainActor in
            // Give the shelf a frame to slide out of the way before freezing.
            try? await Task.sleep(nanoseconds: 70_000_000)
            do {
                let shots = try await Capture.allDisplays()
                present(shots)
            } catch {
                isActive = false
                report(error)
            }
        }
    }

    /// Development only: draw the whole selection UI over a synthetic screen so
    /// it can be reviewed without the Screen Recording permission.
    func beginDemo() {
        guard !isActive else { return }
        isActive = true
        var shots: [CGDirectDisplayID: Shot] = [:]
        for ref in Displays.all {
            let image = DemoImage.make(size: ref.screen.frame.size, scale: ref.screen.backingScaleFactor)
            shots[ref.displayID] = Shot(displayID: ref.displayID, screen: ref.screen, image: image)
        }
        present(shots)

        guard let screen = Displays.underMouse(), let displayID = Displays.id(of: screen), shots[displayID] != nil else {
            return
        }
        activeScreen = screen
        if ProcessInfo.processInfo.environment["PEG_DEMO_EMPTY"] == "1" {
            anchor = nil
            current = nil
        } else {
            anchor = CGPoint(x: 360, y: 300)
            current = CGPoint(x: 980, y: 760)
        }
        for window in windows {
            (window.contentView as? SelectionView)?.demoCursor = CGPoint(x: 100, y: 906)
        }
        redraw()
    }

    private func present(_ shots: [CGDirectDisplayID: Shot]) {
        self.shots = shots
        samplers = shots.reduce(into: [:]) { result, pair in
            result[pair.key] = PixelSampler(pair.value.image)
        }

        for shot in shots.values {
            let window = SelectionWindow(screen: shot.screen)
            let view = SelectionView(shot: shot, sampler: samplers[shot.displayID])
            view.session = self
            window.contentView = view
            window.setFrame(shot.screen.frame, display: false)
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let target = windows.first { $0.frame.contains(mouse) } ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        if let view = target?.contentView {
            target?.makeFirstResponder(view)
        }
    }

    func cancel() {
        guard isActive else { return }
        dismiss()
    }

    private func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        shots.removeAll()
        samplers.removeAll()
        activeScreen = nil
        anchor = nil
        current = nil
        isActive = false
        NSCursor.arrow.set()
    }

    // MARK: - Geometry

    /// The magnifier follows the pointer until a drag starts somewhere.
    func allowsMagnifier(on screen: NSScreen) -> Bool {
        activeScreen == nil || activeScreen === screen
    }

    func selection(on screen: NSScreen) -> CGRect? {
        guard activeScreen === screen, let anchor, let current else { return nil }
        let rect = CGRect(x: min(anchor.x, current.x),
                          y: min(anchor.y, current.y),
                          width: abs(anchor.x - current.x),
                          height: abs(anchor.y - current.y))
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let clipped = rect.intersection(bounds)
        return clipped.isNull ? nil : clipped
    }

    // MARK: - Mouse

    func mouseDown(on screen: NSScreen, at point: CGPoint) {
        activeScreen = screen
        anchor = point
        current = point
        redraw()
    }

    func mouseDragged(on screen: NSScreen, at point: CGPoint) {
        guard activeScreen === screen, anchor != nil else { return }
        current = point
        redraw()
    }

    func mouseUp(on screen: NSScreen, at point: CGPoint) {
        guard activeScreen === screen, anchor != nil else { return }
        current = point
        redraw()
    }

    private func redraw() {
        for window in windows {
            window.contentView?.needsDisplay = true
        }
    }

    // MARK: - Keyboard

    func keyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // esc
            cancel()
            return true
        case 36, 76, 49: // return, enter, space
            commit(.copyAndSave)
            return true
        case 35: // p
            commit(.pin)
            return true
        default:
            return false
        }
    }

    // MARK: - Commit

    func commit(_ finish: Finish) {
        guard let screen = activeScreen,
              let rect = selection(on: screen),
              rect.width >= 3, rect.height >= 3,
              let displayID = Displays.id(of: screen),
              let shot = shots[displayID]
        else { return }

        let scale = shot.scale
        var pixelRect = CGRect(x: rect.minX * scale,
                               y: rect.minY * scale,
                               width: rect.width * scale,
                               height: rect.height * scale).integral
        pixelRect = pixelRect.intersection(CGRect(x: 0, y: 0,
                                                  width: CGFloat(shot.image.width),
                                                  height: CGFloat(shot.image.height)))
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = shot.image.cropping(to: pixelRect)
        else { return }

        let onScreen = Displays.appKitRect(fromLocalTopLeft: rect, on: screen)
        dismiss()

        switch finish {
        case .copyAndSave:
            Clip.copy(cropped)
            if let url = Storage.save(cropped) {
                Shelf.shared.insert(url)
            }
            Shelf.shared.flash()
        case .pin:
            PinController.shared.pin(cropped, at: onScreen)
        }
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// A borderless window that can take keyboard focus.
final class SelectionWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
