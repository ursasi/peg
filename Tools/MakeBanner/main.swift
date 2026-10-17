import AppKit

/// Renders docs/banner.png for the README.
///
///     swiftc Tools/Design/PegMark.swift Tools/MakeBanner/main.swift -o build/makebanner

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

let width = 1280
let height = 400

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: width, pixelsHigh: height,
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let canvas = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
NSGradient(colors: [
    NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.18, alpha: 1),
    NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.31, alpha: 1)
])!.draw(in: canvas, angle: 0)

PegMark.draw(in: NSRect(x: 74, y: 74, width: 252, height: 252))

NSAttributedString(string: "Peg", attributes: [
    .font: NSFont.systemFont(ofSize: 116, weight: .bold),
    .foregroundColor: NSColor.white,
    .kern: -2
]).draw(at: NSPoint(x: 372, y: 192))

NSAttributedString(string: "A free screenshot tool for macOS", attributes: [
    .font: NSFont.systemFont(ofSize: 30, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.80)
]).draw(at: NSPoint(x: 376, y: 140))

NSAttributedString(string: "snip · annotate · pin · clothesline · long shots · GIF", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 19, weight: .regular),
    .foregroundColor: NSColor.white.withAlphaComponent(0.45)
]).draw(at: NSPoint(x: 378, y: 96))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
let path = (outputDirectory as NSString).appendingPathComponent("banner.png")
try png.write(to: URL(fileURLWithPath: path))
print("banner: wrote \(path)")
