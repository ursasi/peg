import AppKit
import CoreGraphics

/// Finds the window under the pointer so a snip can lock onto it with a click.
///
/// Only window *frames* are needed, which CGWindowList hands out without asking
/// for anything beyond the screen recording grant we already hold.
enum WindowFinder {
    /// Bounds of the topmost normal window under `point`, in that screen's own
    /// top-left-origin points.
    static func windowRect(atLocalPoint point: CGPoint, on screen: NSScreen) -> CGRect? {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        // CGWindowList counts y downwards from the top of the main display.
        let cgPoint = CGPoint(x: screen.frame.minX + point.x,
                             y: (mainHeight - screen.frame.maxY) + point.y)

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Layer 0 is "normal window": our own overlay sits at screenSaver level
        // and the shelf at statusBar level, so they are filtered out on their
        // own. Peg's settings window *is* layer 0 and should be capturable.
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0.15,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width >= 24, rect.height >= 24,
                  rect.contains(cgPoint)
            else { continue }

            let local = CGRect(x: rect.minX - screen.frame.minX,
                               y: rect.minY - (mainHeight - screen.frame.maxY),
                               width: rect.width,
                               height: rect.height)
            return local.intersection(CGRect(origin: .zero, size: screen.frame.size))
        }
        return nil
    }
}
