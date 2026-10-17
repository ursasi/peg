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

    enum Entry {
        case image(Data)   // PNG bytes, so the buffer stays small
        case text(String)
    }

    private(set) var entries: [Entry] = []
    private var changeCount = NSPasteboard.general.changeCount
    private var cursor = 0
    private var lastUsed = Date.distantPast
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
            if case .image(let previous)? = entries.first, previous == data { return }
            entries.insert(.image(data), at: 0)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty,
                  text.count <= maxTextLength {
            if case .text(let previous)? = entries.first, previous == text { return }
            entries.insert(.text(text), at: 0)
        } else {
            return
        }
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        cursor = 0
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

    /// Next older copy. Pressing the shortcut repeatedly walks back, then loops.
    /// After a pause it starts over from the newest, the way the shelf's pin
    /// walk behaves.
    func next() -> Entry? {
        guard !entries.isEmpty else { return nil }
        if Date().timeIntervalSince(lastUsed) > 12 { cursor = 0 }
        lastUsed = Date()
        let entry = entries[min(cursor, entries.count - 1)]
        cursor = (cursor + 1) % entries.count
        return entry
    }

    func resetCursor() {
        cursor = 0
        lastUsed = .distantPast
    }

    func clear() {
        entries.removeAll()
        cursor = 0
    }
}
