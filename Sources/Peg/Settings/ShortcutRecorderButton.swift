import AppKit

/// A button that records the next key combination pressed. Clicking it starts
/// listening; `onCapture` fires with the recorded shortcut, or nil if the user
/// pressed Escape.
final class ShortcutRecorderButton: NSButton {
    var onCapture: ((Shortcut?) -> Void)?

    private var isRecording = false {
        didSet { refreshTitle() }
    }
    private var shortcut: Shortcut = Shortcut(keyCode: 0, modifiers: 0)
    private var localMonitor: Any?

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        focusRingType = .none
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setShortcut(_ shortcut: Shortcut) {
        self.shortcut = shortcut
        refreshTitle()
    }

    private func refreshTitle() {
        title = isRecording ? "按下新的快捷键…" : shortcut.display
        contentTintColor = isRecording ? .controlAccentColor : .labelColor
    }

    @objc private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        // The recorder only listens while it is armed, and only for this app.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.finish(event)
            return nil
        }
    }

    private func finish(_ event: NSEvent) {
        stopRecording()
        if event.keyCode == 53 { // esc cancels
            onCapture?(nil)
            return
        }
        let modifiers = Shortcut.carbonModifiers(from: event.modifierFlags)
        let captured = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard captured.isUsable else {
            NSSound.beep()
            onCapture?(nil)
            return
        }
        shortcut = captured
        refreshTitle()
        onCapture?(captured)
    }

    /// Closed window while armed: drop the monitor instead of keeping it alive.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    private func stopRecording() {
        isRecording = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
