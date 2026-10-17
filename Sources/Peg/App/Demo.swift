import AppKit
import CoreGraphics

/// A fabricated desktop, used for the screenshots in the README and by
/// `PEG_DEMO=overlay` to review the selection UI without Screen Recording.
///
/// Everything here is invented: no real window, no real document, no file
/// names from anyone's machine. It just has to look plausible under Peg's
/// overlay so the screenshots show the product, not the author's desktop.
enum DemoImage {
    private static let code: [(String, NSColor)] = [
        ("# collect totals for the week\n", .init(red: 0.42, green: 0.55, blue: 0.42, alpha: 1)),
        ("def collect(rows, currency):\n", .init(red: 0.78, green: 0.53, blue: 0.86, alpha: 1)),
        ("    total = 0\n", .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("    for row in rows:\n", .init(red: 0.78, green: 0.53, blue: 0.86, alpha: 1)),
        ("        total += row.amount\n", .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("    return Money(total, currency)\n", .init(red: 0.34, green: 0.80, blue: 0.71, alpha: 1)),
        ("\n", .white),
        ("def summarise(rows):\n", .init(red: 0.78, green: 0.53, blue: 0.86, alpha: 1)),
        ("    buckets = {}\n", .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("    for row in rows:\n", .init(red: 0.78, green: 0.53, blue: 0.86, alpha: 1)),
        ("        key = row.week\n", .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("        buckets.setdefault(key, []).append(row)\n", .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("    return {k: collect(v, \"CNY\") for k, v in buckets.items()}\n",
         .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("\n", .white),
        ("# the report needs one line per week\n", .init(red: 0.42, green: 0.55, blue: 0.42, alpha: 1)),
        ("report = summarise(load(\"weekly.csv\"))\n", .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("write(report, \"summary.json\")\n", .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("\n", .white),
        ("def load(path):\n", .init(red: 0.78, green: 0.53, blue: 0.86, alpha: 1)),
        ("    with open(path) as handle:\n", .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("        return [Row(**line) for line in csv(handle)]\n",
         .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("\n", .white),
        ("# rounding happens once, at the end\n", .init(red: 0.42, green: 0.55, blue: 0.42, alpha: 1)),
        ("for week, money in sorted(report.items()):\n",
         .init(red: 0.78, green: 0.53, blue: 0.86, alpha: 1)),
        ("    print(week, money.round(2))\n", .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("\n", .white),
        ("# keep the header row for the CSV export\n", .init(red: 0.42, green: 0.55, blue: 0.42, alpha: 1)),
        ("header = [\"week\", \"total\", \"currency\"]\n", .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)),
        ("export(report, header, \"summary.csv\")\n", .init(red: 0.84, green: 0.86, blue: 0.88, alpha: 1))
    ]

    private static let files = ["README.md", "report.py", "weekly.csv", "schema.sql", "notes.txt"]

    static func make(size: CGSize, scale: CGFloat) -> CGImage {
        let width = max(1, Int(size.width * scale))
        let height = max(1, Int(size.height * scale))
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fatalError("demo image") }

        // Desktop wash.
        let colors = [CGColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1),
                      CGColor(red: 0.16, green: 0.21, blue: 0.29, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero,
                               end: CGPoint(x: CGFloat(width), y: CGFloat(height)),
                               options: [])

        // A window, drawn in flipped-style coordinates by hand.
        let margin = CGFloat(width) * 0.08
        let window = CGRect(x: margin,
                            y: CGFloat(height) * 0.10,
                            width: CGFloat(width) - margin * 2,
                            height: CGFloat(height) * 0.80)
        let radius = 14 * scale

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale),
                      blur: 30 * scale,
                      color: CGColor(gray: 0, alpha: 0.45))
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius,
                           transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        // Title bar.
        let titleBar = CGRect(x: window.minX, y: window.maxY - 34 * scale,
                              width: window.width, height: 34 * scale)
        ctx.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1))
        ctx.addPath(CGPath(roundedRect: titleBar, cornerWidth: radius, cornerHeight: radius,
                           transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1))
        ctx.fill(CGRect(x: titleBar.minX, y: titleBar.minY,
                        width: titleBar.width, height: radius))

        for (index, colour) in [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1),
                                CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                                CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            let dot = 11 * scale
            ctx.setFillColor(colour)
            ctx.fillEllipse(in: CGRect(x: titleBar.minX + (16 + CGFloat(index) * 20) * scale,
                                       y: titleBar.midY - dot / 2,
                                       width: dot, height: dot))
        }

        // Sidebar.
        let sidebar = CGRect(x: window.minX, y: window.minY,
                             width: 190 * scale, height: window.height - titleBar.height)
        ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1))
        ctx.fill(sidebar)

        for (index, name) in files.enumerated() {
            let selected = index == 1
            let row = CGRect(x: sidebar.minX + 10 * scale,
                             y: sidebar.maxY - (30 + CGFloat(index) * 26) * scale,
                             width: sidebar.width - 20 * scale,
                             height: 22 * scale)
            if selected {
                ctx.setFillColor(CGColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1))
                ctx.addPath(CGPath(roundedRect: row, cornerWidth: 5 * scale,
                                   cornerHeight: 5 * scale, transform: nil))
                ctx.fillPath()
            }
            draw(text: name,
                 in: CGRect(x: row.minX + 8 * scale, y: row.minY + 4 * scale,
                            width: row.width, height: 16 * scale),
                 size: 12 * scale,
                 colour: NSColor(calibratedWhite: selected ? 0.92 : 0.62, alpha: 1),
                 ctx: ctx)
        }

        // Code area.
        let gutterX = sidebar.maxX + 16 * scale
        let codeTop = titleBar.minY - 18 * scale
        let font = NSFont.monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
        let lineStep = 19 * scale

        for (index, line) in code.enumerated() {
            let y = codeTop - CGFloat(index) * lineStep - lineStep
            draw(text: "\(index + 1)",
                 in: CGRect(x: sidebar.maxX + 8 * scale, y: y, width: 30 * scale, height: lineStep),
                 size: 11 * scale,
                 colour: NSColor(calibratedWhite: 1, alpha: 0.22),
                 ctx: ctx)
            draw(text: line.0.trimmingCharacters(in: .newlines),
                 in: CGRect(x: gutterX + 34 * scale, y: y, width: window.width - 80 * scale,
                            height: lineStep),
                 size: 12 * scale,
                 colour: line.1,
                 ctx: ctx)
        }
        _ = font

        return ctx.makeImage()!
    }

    private static func draw(text: String, in rect: CGRect, size: CGFloat,
                             colour: NSColor, ctx: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: colour
        ])
        NSGraphicsContext.current = previous
    }
}
