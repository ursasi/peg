import AppKit
import ImageIO

// Render a sample of every annotation on the demo image, then exit.
if ProcessInfo.processInfo.environment["PEG_ANNOTATE_SAMPLE"] == "1" {
    let size = CGSize(width: 900, height: 600)
    let image = DemoImage.make(size: size, scale: 2)
    guard let flat = AnnotationRenderer.flatten(image, shapes: AnnotationSample.shapes(for: image)) else {
        exit(1)
    }
    let url = URL(fileURLWithPath: "/tmp/peg-annotate-sample.png")
    if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, flat, nil)
        CGImageDestinationFinalize(destination)
    }
    exit(0)
}

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
