import AppKit
import CoreGraphics
import ScreenCaptureKit

/// One frozen frame of one display, plus what we need to map points to pixels.
struct Shot {
    let displayID: CGDirectDisplayID
    let screen: NSScreen
    let image: CGImage

    /// Pixels per point for this display.
    var scale: CGFloat {
        let points = screen.frame.width
        guard points > 0 else { return 1 }
        return CGFloat(image.width) / points
    }
}

enum CaptureError: LocalizedError {
    case noDisplays
    case emptyFrame

    var errorDescription: String? {
        switch self {
        case .noDisplays: return "没有找到可截图的显示器"
        case .emptyFrame: return "截图结果为空，请检查屏幕录制权限"
        }
    }
}

enum Capture {
    /// Captures every display at native pixel resolution. The result is a
    /// frozen frame, which is what the selection overlay draws on: no flicker,
    /// no overlay baked into the image, and the magnifier has real pixels.
    ///
    /// Peg leaves its own windows out by default — the clothesline hangs under
    /// the menu bar and would otherwise land in the middle of a shot. Pass
    /// `includeSelf` to keep them, which is how the clothesline, a pin or the
    /// settings window gets photographed when Peg itself needs describing.
    static func allDisplays(includeSelf: Bool = false) async throws -> [CGDirectDisplayID: Shot] {
        let t0 = CFAbsoluteTimeGetCurrent()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1" {
            NSLog("Peg timing content=%.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myApp = content.applications.first { $0.processID == myPID }

        // Each display is its own ScreenCaptureKit round trip; taking them one
        // after another made a two-display setup wait twice for no reason.
        let shots = try await withThrowingTaskGroup(of: Shot.self) { group in
            for display in content.displays {
                guard let screen = NSScreen.screens.first(where: { Displays.id(of: $0) == display.displayID }) else {
                    continue
                }
                group.addTask {
                    try await capture(display: display, screen: screen,
                                      myApp: myApp, includeSelf: includeSelf)
                }
            }
            var shots: [CGDirectDisplayID: Shot] = [:]
            for try await shot in group { shots[shot.displayID] = shot }
            return shots
        }

        guard !shots.isEmpty else { throw CaptureError.noDisplays }
        return shots
    }

    /// One display, at native pixel resolution.
    private static func capture(display: SCDisplay,
                                screen: NSScreen,
                                myApp: SCRunningApplication?,
                                includeSelf: Bool) async throws -> Shot {
        let filter: SCContentFilter
        if let myApp, !includeSelf {
            filter = SCContentFilter(display: display,
                                     excludingApplications: [myApp],
                                     exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        // SCDisplay reports points, not pixels: on a scaled Retina mode that
        // would give a soft 1x capture. The display mode knows the real backing
        // resolution.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let config = SCStreamConfiguration()
        config.width = mode?.pixelWidth ?? display.width
        config.height = mode?.pixelHeight ?? display.height
        config.showsCursor = false
        config.scalesToFit = false
        config.captureResolution = .best

        let t1 = CFAbsoluteTimeGetCurrent()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1" {
            NSLog("Peg timing capture display=%u %.0f ms", display.displayID, (CFAbsoluteTimeGetCurrent() - t1) * 1000)
        }
        if ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1" {
            NSLog("Peg display=%u scDisplay=%dx%d screen=%.0fx%.0f backing=%.2f cgPixels=%dx%d image=%dx%d",
                  display.displayID, display.width, display.height,
                  screen.frame.width, screen.frame.height, screen.backingScaleFactor,
                  CGDisplayPixelsWide(display.displayID), CGDisplayPixelsHigh(display.displayID),
                  image.width, image.height)
        }
        guard image.width > 0, image.height > 0 else { throw CaptureError.emptyFrame }
        return Shot(displayID: display.displayID, screen: screen, image: image)
    }
}
