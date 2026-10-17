import AppKit

/// Writes AppIcon.icns next to the app bundle's Resources. The mark is drawn
/// from code (Tools/Design/PegMark.swift) so the repo stays free of binaries.
///
///     swiftc Tools/Design/PegMark.swift Tools/MakeIcon/main.swift -o build/makeicon

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"
let fileManager = FileManager.default
let iconset = (outputDirectory as NSString).appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(atPath: iconset)
try fileManager.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, pixels) in variants {
    // Render at 1024 and downsample, so small sizes keep clean edges.
    let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    big.size = NSSize(width: 1024, height: 1024)
    let context = NSGraphicsContext(bitmapImageRep: big)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    PegMark.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { rect in
        big.draw(in: rect)
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: URL(fileURLWithPath: (iconset as NSString).appendingPathComponent("\(name).png")))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset, "-o",
                     (outputDirectory as NSString).appendingPathComponent("AppIcon.icns")]
try process.run()
process.waitUntilExit()
try? fileManager.removeItem(atPath: iconset)
print(process.terminationStatus == 0 ? "icon: wrote AppIcon.icns" : "icon: iconutil failed")
