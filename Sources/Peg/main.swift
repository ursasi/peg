import AppKit

// Headless checks, used while developing the stitcher.
if ProcessInfo.processInfo.environment["PEG_SELFTEST"] == "1" {
    exit(ScrollSelfTest.run())
}

// A menu-bar-only app: no Dock icon, no windows at launch.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
