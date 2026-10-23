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

    /// Two hotkeys, two behaviours, no setting to remember: one frames and
    /// saves straight away, the other keeps the selection and puts the drawing
    /// tools under it.
    enum Mode {
        case direct   // ⌃⌥X: release the mouse, it is already copied and saved
        case markup   // ⌃⌥A: tools appear, ⏎ when done
        case record   // ⌃⌥G: the region becomes a GIF recorder
        case scroll   // ⌃⌥L: drag a region and the scroll capture starts
    }

    private(set) var isActive = false
    private(set) var mode: Mode = .markup
    /// `beginDemo` draws a fabricated screen; window lookup must stay off then,
    /// or the overlay would outline whatever is really on the desktop.
    private var isDemo = false
    private var windows: [SelectionWindow] = []
    private var shots: [CGDirectDisplayID: Shot] = [:]
    private var samplers: [CGDirectDisplayID: PixelSampler] = [:]

    /// Selection state is kept for one screen at a time, in that screen's own
    /// top-left-origin points. Dragging across displays is deliberately not
    /// supported: it would need mixed scale factors composited into one image.
    private var activeScreen: NSScreen?
    private var anchor: CGPoint?
    private var current: CGPoint?

    /// The window under the pointer before any selection exists, and the point
    /// where it was clicked (a real drag turns that click into a free rectangle).
    private var hoverScreen: NSScreen?
    private(set) var windowHover: CGRect?
    private var windowClick: CGPoint?
    private var hoverTimer: Timer?

    /// Marks made on the frozen screen, in screen points. Nothing is cropped,
    /// copied or saved until the snip is finished — so what you paste is exactly
    /// what you were looking at.
    private(set) var shapes: [AnnotationShape] = []
    private var draftShape: AnnotationShape?
    /// The mark drawn most recently. A size change right after drawing applies
    /// to it as well as to the next one: the mark on screen is the only way to
    /// judge what the number means.
    private var lastDrawnIndex: Int?
    private(set) var tool: AnnotationTool?
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    /// Type size for the next caption. Kept apart from `lineWidth` so switching
    /// between the pen and the text tool does not drag the other value along.
    var textSize: CGFloat = 26

    var isDrafting: Bool { draftShape != nil }

    /// Drawn marks, plus the one under the pointer right now.
    var visibleShapes: [AnnotationShape] {
        if let draftShape { return shapes + [draftShape] }
        return shapes
    }

    // MARK: - Start / stop

    /// The snip hotkey does double duty: while a scroll capture is running it
    /// finishes that instead of starting a new snip.
    func hotKeyPressed(mode: Mode = .markup) {
        DebugLog.log("hotkey mode=\(mode) recording=\(Recorder.shared.isRecording) scroll=\(ScrollSession.shared.isActive) active=\(isActive) perm=\(Permissions.hasScreenRecording)")
        if Recorder.shared.isRecording {
            Recorder.shared.stop()
            return
        }
        if ScrollSession.shared.isActive {
            ScrollSession.shared.finish()
            return
        }
        begin(mode: mode, includeSelf: NSEvent.modifierFlags.contains(.shift))
    }

    /// `includeSelf` keeps Peg's own windows in the frozen frame, for shooting
    /// the clothesline or a pin when reporting a problem with Peg itself.
    func begin(mode: Mode = .markup, includeSelf: Bool = false) {
        guard !isActive else { return }
        guard Permissions.ensure() else { return }
        isActive = true
        self.mode = mode
        let keepSelf = includeSelf || Prefs.captureSelf
        DebugLog.log("snip begin mode=\(mode) self=\(keepSelf)")
        if !keepSelf {
            Shelf.shared.hideNow(animated: false)
        }

        Task { @MainActor in
            // Give the shelf a frame to slide out of the way before freezing.
            if !keepSelf { try? await Task.sleep(nanoseconds: 70_000_000) }
            do {
                let shots = try await Capture.allDisplays(includeSelf: keepSelf)
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
        isDemo = true
        mode = .markup
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
            // Inside the selection, so the magnifier does not sit on the toolbar.
            (window.contentView as? SelectionView)?.demoCursor = CGPoint(x: 1178, y: 402)
        }

        if ProcessInfo.processInfo.environment["PEG_DEMO_SCROLL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                MainActor.assumeIsolated { self?.beginScroll() }
            }
        }
        redraw()
    }

    /// The window under the pointer is found by polling, not by waiting for a
    /// mouse-move: press the hotkey and click straight away (no pointer motion
    /// at all) and it still grabs the window you were looking at.
    private func startHoverPolling() {
        stopHoverPolling()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
        pollPointer()
    }

    private func stopHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func pollPointer() {
        // In demo mode the pointer position is fabricated; polling the real
        // cursor would drag the magnifier to wherever the mouse happens to be.
        guard isActive, !isDemo else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = Displays.underMouse(),
              let window = windows.first(where: { $0.frame.contains(mouse) }),
              let view = window.contentView as? SelectionView
        else { return }
        let local = CGPoint(x: mouse.x - screen.frame.minX,
                            y: screen.frame.maxY - mouse.y)
        view.followPointer(local)
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
            if DebugLog.enabled {
                try? "\(window.windowNumber)".write(toFile: "/tmp/peg-winnum", atomically: true, encoding: .utf8)
            }
        }

        startHoverPolling()

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
        hoverScreen = nil
        windowHover = nil
        windowClick = nil
        shapes.removeAll()
        draftShape = nil
        tool = nil
        mode = .markup
        isDemo = false
        stopHoverPolling()
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

    /// Called on every pointer move while nothing is selected yet.
    func updateHover(on screen: NSScreen, at point: CGPoint) {
        guard anchor == nil, !isDemo else { return }
        let rect = WindowFinder.windowRect(atLocalPoint: point, on: screen)
        if rect != windowHover { DebugLog.log("hover \(point.x),\(point.y) -> \(rect.map { "\($0)" } ?? "nil")") }
        if hoverScreen !== screen || rect != windowHover {
            hoverScreen = screen
            windowHover = rect
            redraw()
        }
    }

    // MARK: - Marks

    func setTool(_ newTool: AnnotationTool?) {
        tool = newTool
        draftShape = nil
        redraw()
    }

    func undo() {
        if draftShape != nil {
            draftShape = nil
        } else if !shapes.isEmpty {
            shapes.removeLast()
            if let last = lastDrawnIndex, last >= shapes.count { lastDrawnIndex = nil }
        }
        redraw()
    }

    func beginShape(at point: CGPoint) {
        guard let tool else { return }
        var shape = AnnotationShape(tool: tool, color: color, lineWidth: lineWidth)
        if tool == .pen || tool == .marker {
            shape.points = [point]
        } else {
            shape.start = point
            shape.end = point
        }
        draftShape = shape
        redraw()
    }

    func updateShape(to point: CGPoint) {
        guard var shape = draftShape else { return }
        if shape.tool == .pen || shape.tool == .marker {
            // Drop samples that are closer than a point: they only cost redraws.
            if let last = shape.points.last, hypot(point.x - last.x, point.y - last.y) < 1.2 {
                return
            }
            shape.points.append(point)
        } else {
            shape.end = point
        }
        draftShape = shape
        redraw()
    }

    func endShape() {
        guard let shape = draftShape else { return }
        draftShape = nil
        if !shape.isDegenerate {
            shapes.append(shape)
            lastDrawnIndex = shapes.count - 1
        }
        DebugLog.log("endShape tool=\(shape.tool) degenerate=\(shape.isDegenerate) count=\(shapes.count) rect=\(shape.rect)")
        redraw()
    }

    func addText(_ text: String, at point: CGPoint) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var shape = AnnotationShape(tool: .text, color: color, lineWidth: lineWidth)
        shape.start = point
        shape.end = point
        shape.text = trimmed
        shape.fontSize = textSize
        shapes.append(shape)
        lastDrawnIndex = shapes.count - 1
        redraw()
    }

    /// Burn the marks into the cropped capture. Both the clipboard and the pin
    /// come through here, so they can never disagree.
    private func flatten(_ image: CGImage, selection: CGRect, scale: CGFloat) -> CGImage {
        guard !shapes.isEmpty else { return image }
        let marks = shapes.map { $0.transformed(scale: scale, offset: selection.origin) }
        return AnnotationRenderer.flatten(image, shapes: marks) ?? image
    }

    func mouseDown(on screen: NSScreen, at point: CGPoint) {
        DebugLog.log("session.mouseDown \(point) hover=\(windowHover.map { "\($0)" } ?? "nil") anchor=\(String(describing: anchor))")
        if anchor == nil, let rect = windowHover, rect.contains(point) {
            // One click grabs the whole window; dragging from here still makes
            // a free selection instead.
            activeScreen = screen
            anchor = CGPoint(x: rect.minX, y: rect.minY)
            current = CGPoint(x: rect.maxX, y: rect.maxY)
            windowClick = point
            hoverScreen = nil
            windowHover = nil
            redraw()
            return
        }
        windowClick = nil
        activeScreen = screen
        anchor = point
        current = point
        redraw()
    }

    func mouseDragged(on screen: NSScreen, at point: CGPoint) {
        guard activeScreen === screen, anchor != nil else { return }
        if let origin = windowClick {
            // Moved far enough to mean "I want to drag a rectangle myself".
            guard hypot(point.x - origin.x, point.y - origin.y) > 4 else { return }
            windowClick = nil
            anchor = origin
        }
        current = point
        redraw()
    }

    func mouseUp(on screen: NSScreen, at point: CGPoint) {
        guard activeScreen === screen, anchor != nil else { return }
        if windowClick != nil {
            // A click on a window keeps the whole window: the release point is
            // only used when it was an actual drag.
            windowClick = nil
            if mode == .direct { commit(.copyAndSave) }
            return
        }
        current = point
        redraw()
        if mode == .record, let rect = selection(on: screen), rect.width >= 8, rect.height >= 8 {
            dismiss()
            Task { @MainActor in
                await Recorder.shared.begin(region: rect, on: screen)
            }
            return
        }
        // Long capture is a mode of its own now: dragging a region and letting
        // go starts it, instead of selecting first and then remembering L.
        if mode == .scroll, let rect = selection(on: screen), rect.width >= 16, rect.height >= 16 {
            beginScroll()
            return
        }
        if mode == .direct, let rect = selection(on: screen), rect.width >= 8, rect.height >= 8 {
            commit(.copyAndSave)
        }
    }

    // MARK: - Debug input

    /// PEG_DEBUG=1 test hook: synthesise the AppKit callbacks directly instead of
    /// posting system events, so automation cannot leak keystrokes to other apps.
    func debugEvent(_ kind: String, _ points: [CGPoint]) {
        guard isActive, let firstPoint = points.first,
              let window = windows.first(where: {
                  $0.frame.contains(firstPoint) || $0.frame.contains(points.last ?? firstPoint)
              }),
              let view = window.contentView as? SelectionView
        else { DebugLog.log("debugEvent: no window for \(points)"); return }

        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type,
                               location: NSPoint(x: point.x - window.frame.minX,
                                                 y: window.frame.maxY - point.y),
                               modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber,
                               context: nil,
                               eventNumber: 0,
                               clickCount: 1,
                               pressure: 1)
        }

        switch kind {
        case "click":
            if let e = event(.leftMouseDown, firstPoint) { view.mouseDown(with: e) }
            if let e = event(.leftMouseUp, firstPoint) { view.mouseUp(with: e) }
        case "drag":
            guard points.count >= 2, let last = points.last else { return }
            if let e = event(.leftMouseDown, firstPoint) { view.mouseDown(with: e) }
            for point in points.dropFirst() {
                if let e = event(.leftMouseDragged, point) { view.mouseDragged(with: e) }
            }
            if let e = event(.leftMouseUp, last) { view.mouseUp(with: e) }
        case "move":
            view.followPointer(firstPoint)
        default:
            break
        }
    }

    func debugKey(_ code: UInt16) {
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        let chars: String = code == 36 ? "\r" : " "
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
        DebugLog.log("debugKey \(code) responder=\(String(describing: window.firstResponder))")
        window.sendEvent(event)
    }

    func debugType(_ text: String) {
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        DebugLog.log("debugType responder=\(String(describing: window.firstResponder))")
        if let editor = window.firstResponder as? NSTextView {
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else {
            DispatchQueue.main.async {
                let current = String(describing: window.firstResponder)
                DebugLog.log("debugType: no text editor, responder=\(current)")
            }
        }
    }

    private func redraw() {
        for window in windows {
            window.contentView?.needsDisplay = true
        }
    }

    // MARK: - Keyboard

    func keyDown(_ event: NSEvent) -> Bool {
        if mode == .markup, event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            undo()
            return true
        }
        if mode == .markup,
           let digit = Int(event.charactersIgnoringModifiers ?? ""), digit >= 1, digit <= 8,
           let tool = AnnotationTool(rawValue: digit - 1) {
            setTool(tool)
            return true
        }
        switch event.keyCode {
        case 53: // esc: leave the tool first, then leave the snip
            if tool != nil {
                setTool(nil)
            } else {
                cancel()
            }
            return true
        case 36, 76: // return, enter
            commit(.copyAndSave)
            return true
        case 49: // space: first tool, so the keyboard-only path still works
            if mode == .markup { setTool(.rect) }
            return true
        case 35: // p
            commit(.pin)
            return true
        case 37: // l
            beginScroll()
            return true
        case 33: // [
            adjustSize(-1)
            return true
        case 30: // ]
            adjustSize(1)
            return true
        default:
            return false
        }
    }

    /// `[` and `]` step the size of whatever the active tool draws: stroke width
    /// for the drawing tools, type size for the text tool.
    func adjustSize(_ direction: CGFloat) {
        let before = (textSize, lineWidth)
        if tool == .text {
            textSize = min(96, max(12, textSize + direction * 4))
        } else {
            lineWidth = min(24, max(1, lineWidth + direction))
        }
        guard (textSize, lineWidth) != before else { return }
        // Follow the mark just drawn, but only one of the same tool: having a
        // rect resize because the text tool's number went up would be wrong.
        if let index = lastDrawnIndex, index < shapes.count, shapes[index].tool == tool {
            if shapes[index].tool == .text {
                shapes[index].fontSize = textSize
            } else {
                shapes[index].lineWidth = lineWidth
            }
        }
        redraw()
    }

    // MARK: - Moving a caption

    /// The text mark under `point`, newest first, in view points. Captions used
    /// to be nailed down the moment they were placed.
    func textShapeIndex(at point: CGPoint) -> Int? {
        for (index, shape) in shapes.enumerated().reversed() where shape.tool == .text {
            if textBounds(shape).insetBy(dx: -6, dy: -6).contains(point) { return index }
        }
        return nil
    }

    private func textBounds(_ shape: AnnotationShape) -> CGRect {
        let font = NSFont.systemFont(ofSize: max(8, shape.fontSize), weight: .semibold)
        let size = (shape.text as NSString).size(withAttributes: [.font: font])
        return CGRect(x: shape.start.x, y: shape.start.y,
                      width: max(8, size.width),
                      height: max(shape.fontSize * 1.6, size.height))
    }

    /// Bounds of the caption at `index`, in view points: the overlay outlines it
    /// so that a placed caption reads as something that can be picked up.
    func textRect(at index: Int) -> CGRect? {
        guard index >= 0, index < shapes.count, shapes[index].tool == .text else { return nil }
        return textBounds(shapes[index])
    }

    func moveText(at index: Int, by delta: CGSize) {
        guard index >= 0, index < shapes.count, shapes[index].tool == .text else { return }
        shapes[index].start.x += delta.width
        shapes[index].start.y += delta.height
        shapes[index].end = shapes[index].start
        redraw()
    }

    // MARK: - Commit

    func commit(_ finish: Finish) {
        // A text box that is still open is part of the picture too.
        for window in windows {
            (window.contentView as? SelectionView)?.commitPendingText()
        }
        guard let cropped = cropSelection() else { return }
        DebugLog.log("commit \(finish) rect=\(cropped.onScreen) local=\(cropped.localRect) shapes=\(shapes.count)")
        let onScreen = cropped.onScreen
        // Marks live in top-left points, so the offset must be the top-left
        // rectangle, not the AppKit (bottom-left) one.
        let flattened = flatten(cropped.image,
                                selection: cropped.localRect,
                                scale: CGFloat(cropped.image.width) / max(1, cropped.localRect.width))
        let finished = Rounded.apply(flattened)
        dismiss()

        switch finish {
        case .copyAndSave:
            DebugLog.log("saved \(flattened.width)x\(flattened.height) marks=\(cropped.image.width > 0)")
            if Prefs.autoCopy { Clip.copy(finished) }
            if let url = Storage.save(finished) {
                Shelf.shared.insert(url)
            }
            Shelf.shared.flash()
        case .pin:
            PinController.shared.pin(finished, at: onScreen)
        }
    }

    private func cropSelection() -> (image: CGImage, screen: NSScreen, onScreen: CGRect, localRect: CGRect)? {
        guard let screen = activeScreen,
              let rect = selection(on: screen),
              rect.width >= 3, rect.height >= 3,
              let displayID = Displays.id(of: screen),
              let shot = shots[displayID]
        else { return nil }

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
        else { return nil }

        return (cropped, screen, Displays.appKitRect(fromLocalTopLeft: rect, on: screen), rect)
    }

    /// Hands the current selection to the scrolling capture.
    /// The action bar's "L" button lands here.
    func beginScrollFromBar() {
        beginScroll()
    }

    private func beginScroll() {
        guard let screen = activeScreen,
              let rect = selection(on: screen),
              rect.width >= 16, rect.height >= 16,
              let displayID = Displays.id(of: screen),
              shots[displayID] != nil
        else { return }
        dismiss()
        ScrollSession.shared.start(region: rect, screen: screen)
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
