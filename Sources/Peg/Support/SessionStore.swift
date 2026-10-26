import AppKit

/// Keeps the frozen frame of recent captures so a snip can be reopened later:
/// the whole screen as it looked, plus the selection and the marks, so a region
/// can be re-chosen and the annotations redone instead of starting over.
///
/// The frame is a JPEG (quality 0.9) because these are working copies, not the
/// saved screenshot; keeping 50 of them has to stay a few dozen megabytes.
enum SessionStore {
    struct Shape: Codable {
        var tool: Int
        var red: Double, green: Double, blue: Double
        var lineWidth: Double
        var start: [Double]
        var end: [Double]
        var points: [[Double]]
        var text: String
        var fontSize: Double
    }

    struct Meta: Codable {
        var createdAt: Date
        var displayID: UInt32
        var selection: [Double]
        var shapes: [Shape]
    }

    struct Entry {
        let base: URL
        let meta: Meta
        var frameURL: URL { base.appendingPathExtension("jpg") }
        var date: Date { meta.createdAt }
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Peg/sessions", isDirectory: true)
    }

    private static var stamp: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    // MARK: - Writing

    static func save(frame: CGImage, displayID: CGDirectDisplayID,
                     selection: CGRect, shapes: [AnnotationShape]) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let now = Date()
        let name = "session-\(Int(now.timeIntervalSince1970 * 1000))"
        let base = folder.appendingPathComponent(name)
        let meta = Meta(createdAt: now,
                        displayID: displayID,
                        selection: [selection.minX, selection.minY, selection.width, selection.height],
                        shapes: shapes.map { shape in
                            let rgb = shape.color.usingColorSpace(.sRGB) ?? .systemRed
                            return Shape(tool: shape.tool.rawValue,
                                         red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent,
                                         lineWidth: shape.lineWidth,
                                         start: [shape.start.x, shape.start.y],
                                         end: [shape.end.x, shape.end.y],
                                         points: shape.points.map { [$0.x, $0.y] },
                                         text: shape.text,
                                         fontSize: shape.fontSize)
                        })

        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: base.appendingPathExtension("json"))

        let bitmap = NSBitmapImageRep(cgImage: frame)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
        try? jpeg.write(to: base.appendingPathExtension("jpg"))

        prune()
        DebugLog.log("session saved \(name) shapes=\(shapes.count)")
    }

    /// Newest first. Leftovers without a frame are skipped.
    static func entries() -> [Entry] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return names
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Entry? in
                guard let data = try? Data(contentsOf: url),
                      let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
                let base = url.deletingPathExtension()
                guard manager.fileExists(atPath: base.appendingPathExtension("jpg").path) else { return nil }
                return Entry(base: base, meta: meta)
            }
            .sorted { $0.date > $1.date }
    }

    static func load(_ entry: Entry) -> (CGImage, Meta)? {
        guard let data = try? Data(contentsOf: entry.frameURL),
              let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return (cg, entry.meta)
    }

    /// Fixed count, oldest first out — no time-based expiry.
    static func prune() {
        let all = entries()
        let limit = Prefs.sessionLimit
        guard all.count > limit else { return }
        for old in all.dropFirst(limit) {
            try? FileManager.default.removeItem(at: old.base.appendingPathExtension("json"))
            try? FileManager.default.removeItem(at: old.frameURL)
        }
        DebugLog.log("session prune kept \(limit) of \(all.count)")
    }

    static func shape(from stored: Shape) -> AnnotationShape {
        var shape = AnnotationShape(tool: AnnotationTool(rawValue: stored.tool) ?? .rect,
                                    color: NSColor(srgbRed: stored.red, green: stored.green,
                                                   blue: stored.blue, alpha: 1),
                                    lineWidth: stored.lineWidth)
        shape.start = CGPoint(x: stored.start.first ?? 0, y: stored.start.last ?? 0)
        shape.end = CGPoint(x: stored.end.first ?? 0, y: stored.end.last ?? 0)
        shape.points = stored.points.map { CGPoint(x: $0.first ?? 0, y: $0.last ?? 0) }
        shape.text = stored.text
        shape.fontSize = stored.fontSize
        return shape
    }
}
