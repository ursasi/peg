import AppKit
import CoreGraphics

/// A screen paired with the display id ScreenCaptureKit uses for it.
struct ScreenRef {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
}

enum Displays {
    static func id(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static var all: [ScreenRef] {
        NSScreen.screens.compactMap { screen in
            guard let id = id(of: screen) else { return nil }
            return ScreenRef(screen: screen, displayID: id)
        }
    }

    /// The screen the pointer is currently on.
    static func underMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// AppKit global (origin bottom-left of the primary screen, y up) -> local,
    /// top-left-origin point inside a screen. Used when a selection has to be
    /// placed back on screen as a window.
    static func appKitRect(fromLocalTopLeft rect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
