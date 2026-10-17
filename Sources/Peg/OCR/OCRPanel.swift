import AppKit

/// The recognised text, already on the clipboard, in a panel you can read and
/// copy from again.
@MainActor
final class OCRPanel {
    static let shared = OCRPanel()

    private var panel: NSPanel?
    private var monitor: Any?
    private var textView: NSTextView?

    func show(text: String, near rect: CGRect, on screen: NSScreen) {
        close()

        let size = NSSize(width: 420, height: 220)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "已复制到剪贴板")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = NSColor.white.withAlphaComponent(0.55)
        title.frame = NSRect(x: 14, y: size.height - 26, width: 240, height: 16)
        root.addSubview(title)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 46, width: size.width - 24, height: size.height - 78))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = NSTextView(frame: scroll.bounds)
        textView.string = text
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .white
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        scroll.documentView = textView
        root.addSubview(scroll)
        self.textView = textView

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeAction))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: size.width - 82, y: 12, width: 68, height: 24)
        root.addSubview(closeButton)

        let copyButton = NSButton(title: "复制", target: self, action: #selector(copyAction))
        copyButton.bezelStyle = .rounded
        copyButton.frame = NSRect(x: size.width - 158, y: 12, width: 68, height: 24)
        root.addSubview(copyButton)

        let hint = NSTextField(labelWithString: "Esc 关闭")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor.white.withAlphaComponent(0.35)
        hint.frame = NSRect(x: 14, y: 16, width: 140, height: 14)
        root.addSubview(hint)

        var frame = CGRect(x: rect.minX,
                           y: screen.visibleFrame.minY + 40,
                           width: size.width,
                           height: size.height)
        if rect.minX + size.width > screen.visibleFrame.maxX {
            frame.origin.x = screen.visibleFrame.maxX - size.width - 16
        }
        frame.origin.x = max(screen.visibleFrame.minX + 16, frame.origin.x)

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = root
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                self.copyAction()
                return nil
            }
            return event
        }
    }

    func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        textView = nil
    }

    @objc private func closeAction() {
        close()
    }

    @objc private func copyAction() {
        guard let text = textView?.string else { return }
        Clip.copy(text)
    }
}
