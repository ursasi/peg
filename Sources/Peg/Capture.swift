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
    static func allDisplays() async throws -> [CGDirectDisplayID: Shot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myApp = content.applications.first { $0.processID == myPID }

        var shots: [CGDirectDisplayID: Shot] = [:]
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: { Displays.id(of: $0) == display.displayID }) else {
                continue
            }
            let filter: SCContentFilter
            if let myApp {
                filter = SCContentFilter(display: display,
                                         excludingApplications: [myApp],
                                         exceptingWindows: [])
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }

            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            config.scalesToFit = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard image.width > 0, image.height > 0 else { throw CaptureError.emptyFrame }
            shots[display.displayID] = Shot(displayID: display.displayID, screen: screen, image: image)
        }

        guard !shots.isEmpty else { throw CaptureError.noDisplays }
        return shots
    }
}
