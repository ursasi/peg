import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var statusItem: NSStatusItem?
    private var dockItem: NSMenuItem?
    private var debugTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        applyDockPreference()
        setUpStatusItem()
        setUpHotKeys()
        Shelf.shared.start()
        _ = PinController.shared
        PinController.shared.scrollMonitorInstalled()
        ClipboardHistory.shared.start()
        DebugLog.log("launched, debug=\(DebugLog.enabled)")
        setUpDebugChannel()

        // Development helpers: PEG_DEMO=shelf|overlay|desktop|settings…
        // Comma separated, so "desktop,shelf" shows the fake desktop with the
        // clothesline on top — the combination the README screenshots need.
        let demo = ProcessInfo.processInfo.environment["PEG_DEMO"] ?? ""
        for step in demo.split(separator: ",").map(String.init) {
            applyDemoStep(step)
        }
    }

    private func applyDemoStep(_ step: String) {
        switch step {
        case "settings":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { SettingsWindow.shared.show() }
            }
        case "shelf":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    Shelf.shared.setDemoItems(DemoContent.shelfItems())
                    Shelf.shared.reveal(autoHideAfter: 30)
                }
            }
        case "desktop":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { DemoContent.showDesktop() }
            }
        case "annotate":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    let screen = NSScreen.main
                    let size = screen?.frame.size ?? CGSize(width: 900, height: 600)
                    let image = DemoImage.make(size: size, scale: screen?.backingScaleFactor ?? 2)
                    AnnotationEditor.shared.present(image: image, on: screen)
                }
            }
        case "overlay":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { SnipSession.shared.beginDemo() }
            }
        case "snip":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { SnipSession.shared.hotKeyPressed() }
            }
        default:
            break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PinController.shared.closeAll()
        DemoContent.cleanup()
    }

    private func setUpHotKeys() {
        let handlers: [ShortcutAction: () -> Void] = [
            .snip: { MainActor.assumeIsolated { SnipSession.shared.hotKeyPressed(mode: .direct) } },
            .snipMarkup: { MainActor.assumeIsolated { SnipSession.shared.hotKeyPressed(mode: .markup) } },
            .record: { MainActor.assumeIsolated { SnipSession.shared.hotKeyPressed(mode: .record) } },
            .shelf: { MainActor.assumeIsolated { Shelf.shared.toggle() } },
            .history: { MainActor.assumeIsolated { HistoryWindow.shared.show() } },
            .pastePin: {
                MainActor.assumeIsolated {
                    if !PinController.shared.pinFromPasteboard() { NSSound.beep() }
                }
            }
        ]
        HotKeyCenter.shared.apply(handlers: handlers)
        for action in HotKeyCenter.shared.failed {
            NSLog("Peg: %@ (⌃⌥ shortcut) is taken by another app", action.title)
        }
    }

    /// Called after the shortcuts change in settings.
    func reloadHotKeys() {
        setUpHotKeys()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A Dock icon click has no window to bring forward; open settings.
        SettingsWindow.shared.show()
        return true
    }

    /// Test hook: with PEG_DEBUG=1 a distributed notification can start a snip
    /// or open a window, so automation never has to synthesise system-wide key
    /// events (a stray global Esc aborts whatever app is in front).
    private func setUpDebugChannel() {
        guard DebugLog.enabled else { return }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDebugNotification(_:)),
            name: nil,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        debugTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { AppDelegate.runPendingDebugCommand() }
        }
    }

    /// `echo snipmarkup > /tmp/peg-cmd` from a test script.
    private static let commandFile = "/tmp/peg-cmd"

    static func runPendingDebugCommand() {
        guard let text = try? String(contentsOfFile: commandFile, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: commandFile)
        (NSApp.delegate as? AppDelegate)?.run(debugCommand: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func run(debugCommand: String) {
        DebugLog.log("debug command: \(debugCommand)")
        switch debugCommand {
        case "snip": SnipSession.shared.hotKeyPressed(mode: .direct)
        case "snipmarkup": SnipSession.shared.hotKeyPressed(mode: .markup)
        case "record": SnipSession.shared.hotKeyPressed(mode: .record)
        case "history": HistoryWindow.shared.show()
        case "shelf": Shelf.shared.toggle()
        case "settings": SettingsWindow.shared.show()
        case "menu":
            if let button = statusItem?.button, let menu = statusItem?.menu {
                menu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: button.bounds.height + 4),
                           in: button)
            }
        case "dock":
            toggleDock()
        case "closepins":
            PinController.shared.closeAll()
        case "pin":
            if !PinController.shared.pinFromPasteboard() {
                DebugLog.log("pin: clipboard empty and no history")
            }
        case "cancel": SnipSession.shared.cancel()
        case "stoprecord": Recorder.shared.stop()
        case _ where debugCommand.hasPrefix("scroll:"):
            if let x = Double(debugCommand.dropFirst("scroll:".count)) {
                Shelf.shared.debugScroll(x)
            }
        case _ where debugCommand.hasPrefix("hover:"):
            if let index = Int(debugCommand.dropFirst("hover:".count)) {
                Shelf.shared.debugHover(index)
            }
        case _ where debugCommand.hasPrefix("preview:"):
            if let index = Int(debugCommand.dropFirst("preview:".count)) {
                Shelf.shared.debugPreview(index)
            }
        case _ where debugCommand.hasPrefix("key:"):
            if let code = UInt16(debugCommand.dropFirst("key:".count)) { SnipSession.shared.debugKey(code) }
        case _ where debugCommand.hasPrefix("type:"):
            let text = String(debugCommand.dropFirst("type:".count))
            SnipSession.shared.debugType(text)
        case _ where debugCommand.hasPrefix("click:"), _ where debugCommand.hasPrefix("drag:"), _ where debugCommand.hasPrefix("move:"):
            let parts = debugCommand.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return }
            let kind = String(parts[0])
            let points = parts[1].split(separator: " ").compactMap { pair -> CGPoint? in
                let xy = pair.split(separator: ",")
                guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
                return CGPoint(x: x, y: y)
            }
            SnipSession.shared.debugEvent(kind, points)
        default: break
        }
    }

    @objc private func handleDebugNotification(_ note: Notification) {
        let command = note.name.rawValue.replacingOccurrences(of: "com.zhangshuohua.peg.", with: "")
        DebugLog.log("debug command: \(command)")
        switch command {
        case "snip":
            SnipSession.shared.hotKeyPressed(mode: .direct)
        case "snipmarkup":
            SnipSession.shared.hotKeyPressed(mode: .markup)
        case "history":
            HistoryWindow.shared.show()
        case "shelf":
            Shelf.shared.toggle()
        case "settings":
            SettingsWindow.shared.show()
        case "cancel":
            SnipSession.shared.cancel()
        default:
            break
        }
    }

    private func applyDockPreference() {
        NSApp.setActivationPolicy(Prefs.showInDock ? .regular : .accessory)
    }

    @objc private func toggleDock() {
        Prefs.showInDock.toggle()
        applyDockPreference()
        updateDockItemState()
    }

    private func updateDockItemState() {
        dockItem?.state = Prefs.showInDock ? .on : .off
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = StatusIcon.make()
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let snip = NSMenuItem(title: "截图", action: #selector(snip), keyEquivalent: "")
        snip.target = self
        menu.addItem(snip)

        let snipMarkup = NSMenuItem(title: "截图并标注", action: #selector(snipMarkup), keyEquivalent: "")
        snipMarkup.target = self
        menu.addItem(snipMarkup)

        let record = NSMenuItem(title: "录制 GIF", action: #selector(recordMovie), keyEquivalent: "")
        record.target = self
        menu.addItem(record)

        let shelf = NSMenuItem(title: "晾图绳", action: #selector(toggleShelf), keyEquivalent: "")
        shelf.target = self
        menu.addItem(shelf)

        menu.addItem(.separator())

        let sizeItem = NSMenuItem(title: "晾图绳大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (index, size) in LineSize.allCases.enumerated() {
            let entry = NSMenuItem(title: size.title, action: #selector(setLineSize(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = Shelf.lineSize == size ? .on : .off
            sizeMenu.addItem(entry)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let history = NSMenuItem(title: "截图历史", action: #selector(openHistory), keyEquivalent: "")
        menu.addItem(history)

        let pastePin = NSMenuItem(title: "贴到屏幕", action: #selector(pastePin), keyEquivalent: "")
        menu.addItem(pastePin)

        let dock = NSMenuItem(title: "在 Dock 中显示", action: #selector(toggleDock), keyEquivalent: "")
        dock.target = self
        dock.state = Prefs.showInDock ? .on : .off
        menu.addItem(dock)
        dockItem = dock

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settings)

        let openFolder = NSMenuItem(title: "打开图片文件夹", action: #selector(openFolder), keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)

        let closePins = NSMenuItem(title: "关闭所有贴图", action: #selector(closePins), keyEquivalent: "")
        closePins.target = self
        menu.addItem(closePins)

        menu.addItem(.separator())

        let permission = NSMenuItem(title: "屏幕录制权限…", action: #selector(openPermissionSettings), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)

        let relaunch = NSMenuItem(title: "重新启动 Peg", action: #selector(relaunch), keyEquivalent: "")
        relaunch.target = self
        menu.addItem(relaunch)

        let quit = NSMenuItem(title: "退出 Peg", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Real key equivalents, so the shortcut column is right-aligned by
        // AppKit and follows whatever the user binds. Carbon swallows these
        // combinations before the menu sees them, so nothing fires twice.
        for (item, action) in [(snip, ShortcutAction.snip),
                               (snipMarkup, .snipMarkup),
                               (record, .record),
                               (shelf, .shelf),
                               (history, .history),
                               (pastePin, .pastePin)] {
            let shortcut = ShortcutStore.shortcut(for: action)
            item.keyEquivalent = Shortcut.keyName(shortcut.keyCode).lowercased()
            item.keyEquivalentModifierMask = Shortcut.modifierFlags(from: shortcut.modifiers)
        }

        item.menu = menu
        item.behavior = [.removalAllowed]
        statusItem = item
    }

    @objc private func snip() {
        SnipSession.shared.hotKeyPressed(mode: .direct)
    }

    @objc private func snipMarkup() {
        SnipSession.shared.hotKeyPressed(mode: .markup)
    }

    @objc private func recordMovie() {
        SnipSession.shared.hotKeyPressed(mode: .record)
    }

    @objc private func toggleShelf() {
        Shelf.shared.toggle()
    }

    @objc private func setLineSize(_ sender: NSMenuItem) {
        let sizes = LineSize.allCases
        guard sender.tag >= 0, sender.tag < sizes.count else { return }
        Shelf.shared.setSize(sizes[sender.tag])
        for item in sender.menu?.items ?? [] {
            item.state = item.tag == sender.tag ? .on : .off
        }
    }

    @objc private func pastePin() {
        if !PinController.shared.pinFromPasteboard() { NSSound.beep() }
    }

    @objc private func openHistory() {
        HistoryWindow.shared.show()
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(Storage.folder)
    }

    @objc private func closePins() {
        PinController.shared.closeAll()
    }

    @objc private func openPermissionSettings() {
        Permissions.openScreenRecordingSettings()
    }

    @objc private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
