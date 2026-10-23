import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Clip {
    static func copy(_ image: CGImage) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        pasteboard.setString("", forType: .string) // keep text tools from pasting stale text
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func copy(contentsOf url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // A GIF copied as a picture pastes as its first frame, which is the one
        // thing it must not do. Put the file on the clipboard instead so Finder,
        // mail and chat all get the animation.
        if url.pathExtension.lowercased() == "gif" {
            pasteboard.writeObjects([url as NSURL])
            return
        }
        if let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.writeObjects([url as NSURL])
        }
    }
}

enum Storage {
    /// Wherever the settings window points, ~/Pictures/Peg by default.
    static var folder: URL { Prefs.ensureFolder() }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    @discardableResult
    static func save(_ image: CGImage) -> URL? {
        let format = Prefs.format
        // Rounded corners are transparent; JPEG would render them black.
        let image = Rounded.flattenedForOpaqueFormats(image)
        let folder = folder
        var url = folder.appendingPathComponent("Peg \(stamp.string(from: Date())).\(format.fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(
                "Peg \(stamp.string(from: Date()))-\(counter).\(format.fileExtension)")
            counter += 1
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                               format.utType.identifier as CFString,
                                                               1, nil) else { return nil }
        if format == .jpeg {
            // JPEG has no alpha; flatten onto white first so the result is not
            // a black rectangle where the screenshot was transparent.
            let properties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: Prefs.quality
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

enum Thumbnailer {
    /// Decoding is the expensive half of both the line and the hover preview —
    /// a 5K capture costs ~190 ms every time it is decoded — so results are
    /// kept, keyed by path, size and modification date.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 160
        return cache
    }()

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(maxPixel)|\(stamp)" as NSString
    }

    static func make(_ url: URL, maxPixel: Int = 560) -> NSImage? {
        let key = key(url, maxPixel)
        if let hit = cache.object(forKey: key) { return hit }
        let image = decode(url, maxPixel: maxPixel)
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static func decode(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
    }
}
