import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var snipHotKey: HotKey?
    private var shelfHotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpHotKeys()
        Shelf.shared.start()

        // Development helpers: PEG_DEMO=shelf|snip
        switch ProcessInfo.processInfo.environment["PEG_DEMO"] {
        case "shelf":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { Shelf.shared.reveal(autoHideAfter: 30) }
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
    }

    private func setUpHotKeys() {
        snipHotKey = HotKey(.snip) {
            MainActor.assumeIsolated { SnipSession.shared.hotKeyPressed() }
        }
        if snipHotKey == nil {
            NSLog("Peg: ⌃⌥X is taken by another app")
        }

        shelfHotKey = HotKey(.shelf) {
            MainActor.assumeIsolated { Shelf.shared.toggle() }
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Peg")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let snip = NSMenuItem(title: "截图", action: #selector(snip), keyEquivalent: "")
        snip.target = self
        menu.addItem(snip)

        let shelf = NSMenuItem(title: "晾图绳", action: #selector(toggleShelf), keyEquivalent: "")
        shelf.target = self
        menu.addItem(shelf)

        menu.addItem(.separator())

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

        // Show the shortcuts in the menu without registering them twice.
        snip.attributedTitle = NSAttributedString(string: "截图        ⌃⌥X")
        shelf.attributedTitle = NSAttributedString(string: "晾图绳      ⌃⌥S")

        item.menu = menu
        statusItem = item
    }

    @objc private func snip() {
        SnipSession.shared.hotKeyPressed()
    }

    @objc private func toggleShelf() {
        Shelf.shared.toggle()
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
