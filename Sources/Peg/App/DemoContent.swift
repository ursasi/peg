import AppKit
import CoreGraphics
import ImageIO

/// Screens for the README, built from nothing but code.
///
/// `PEG_DEMO=desktop` puts a fabricated editor window on screen so screenshots
/// show Peg's UI without exposing the real desktop, real documents or real
/// file names. `PEG_DEMO=shelf` fills the clothesline with the same invented
/// shots instead of reading ~/Pictures/Peg.
enum DemoContent {
    private static var desktopWindow: NSWindow?
    private static var generatedFolder: URL?

    /// A borderless window showing the fake desktop, below floating pins.
    static func showDesktop() {
        guard desktopWindow == nil else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let window = NSWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.16, alpha: 1)
        // Above other apps' windows (so nothing real shows through in a
        // screenshot), below pins (.floating) so they still sit on top.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        window.ignoresMouseEvents = false
        let image = DemoImage.make(size: screen.frame.size, scale: screen.backingScaleFactor)
        let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.image = NSImage(cgImage: image,
                             size: NSSize(width: image.width, height: image.height))
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        window.orderFrontRegardless()
        desktopWindow = window
    }

    static func hideDesktop() {
        desktopWindow?.orderOut(nil)
        desktopWindow = nil
    }

    /// Shots for the clothesline demo: written to a temp folder so hover
    /// previews work, then removed on quit.
    static func shelfItems() -> [ShotItem] {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("peg-demo-shots", isDirectory: true)
        try? manager.removeItem(at: folder)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        generatedFolder = folder

        let sizes: [CGSize] = [
            CGSize(width: 520, height: 320),
            CGSize(width: 640, height: 380),
            CGSize(width: 460, height: 460),
            CGSize(width: 700, height: 300),
            CGSize(width: 560, height: 420),
            CGSize(width: 620, height: 340),
            CGSize(width: 480, height: 500),
            CGSize(width: 660, height: 360)
        ]

        var items: [ShotItem] = []
        for (index, size) in sizes.enumerated() {
            let image = DemoImage.make(size: size, scale: 1)
            let url = folder.appendingPathComponent("demo-\(index).png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                   "public.png" as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { continue }
            guard let thumb = Thumbnailer.make(url) else { continue }
            // Oldest first, so the newest sits at the right end of the line.
            let created = Date().addingTimeInterval(-Double(sizes.count - index) * 240)
            items.append(ShotItem(url: url, created: created, thumb: thumb))
        }
        return items
    }

    static func cleanup() {
        hideDesktop()
        if let generatedFolder { try? FileManager.default.removeItem(at: generatedFolder) }
        generatedFolder = nil
    }
}
