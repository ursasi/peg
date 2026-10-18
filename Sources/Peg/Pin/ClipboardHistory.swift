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

        if let data = pasteboard.data(forType: .png) {
            commitImage(data)
            return
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty,
           text.count <= maxTextLength {
            commitText(text)
            return
        }
        // Re-encoding (TIFF or a raw NSImage) costs tens of milliseconds on a
        // large picture; Data is Sendable, so the work can leave this thread.
        guard let tiff = pasteboard.data(forType: .tiff) else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let data = ClipboardHistory.pngData(fromTIFF: tiff) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ClipboardHistory.shared.commitImage(data) }
            }
        }
    }

    fileprivate func commitImage(_ data: Data) {
        if case .image(let previous)? = entries.first?.content, previous == data { return }
        entries.insert(Entry(content: .image(data), date: Date(), pixelSize: pixelSize(ofPNG: data)),
                       at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        cursor = 0
    }

    fileprivate func commitText(_ text: String) {
        if case .text(let previous)? = entries.first?.content, previous == text { return }
        entries.insert(Entry(content: .text(text), date: Date(), pixelSize: nil), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        cursor = 0
    }

    private nonisolated static func pngData(fromTIFF tiff: Data) -> Data? {
        if let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        guard let image = NSImage(data: tiff) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private func pixelSize(ofPNG data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    func clear() {
        entries.removeAll()
        cursor = 0
    }
}
