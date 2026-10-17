import AppKit
import CoreGraphics

/// A small, in-memory ring of what has been copied recently.
///
/// macOS gives apps the *current* pasteboard only — there is no system API for
/// clipboard history (that is why clipboard managers all watch `changeCount`
/// themselves). Without this, pressing the pin shortcut twice on an unchanged
/// clipboard stacks the same picture again.
///
/// Nothing is written to disk and nothing survives a relaunch. Passwords and
/// other secrets do get caught by this, which is the trade for being able to
/// walk back through copies; the buffer is deliberately short.
@MainActor
final class ClipboardHistory {
    static let shared = ClipboardHistory()

    enum Content {
        case image(Data)   // PNG bytes, so the buffer stays small
        case text(String)
    }

    struct Entry {
        var content: Content
        var date: Date
        /// Pixel size, only for images: used to spot the same shot twice.
        var pixelSize: CGSize?
    }

    private(set) var entries: [Entry] = []
    private var changeCount = NSPasteboard.general.changeCount
    private var cursor = 0
    private var timer: Timer?

    private let limit = 15
    private let maxTextLength = 20_000

    func start() {
        guard timer == nil else { return }
        record() // whatever is on the clipboard right now counts as the newest
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        record()
        // A fresh copy makes the next pin start from the newest again.
        cursor = 0
    }

    private func record() {
        let pasteboard = NSPasteboard.general
        if let data = pngData(from: pasteboard) {
            if case .image(let previous)? = entries.first?.content, previous == data { return }
            entries.insert(Entry(content: .image(data),
                                 date: Date(),
                                 pixelSize: pixelSize(ofPNG: data)), at: 0)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty,
                  text.count <= maxTextLength {
            if case .text(let previous)? = entries.first?.content, previous == text { return }
            entries.insert(Entry(content: .text(text), date: Date(), pixelSize: nil), at: 0)
        } else {
            return
        }
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        cursor = 0
    }

    private func pixelSize(ofPNG data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    private func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) { return data }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        if let image = NSImage(pasteboard: pasteboard) {
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                return nil
            }
            return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        }
        return nil
    }

    func clear() {
        entries.removeAll()
        cursor = 0
    }
}
