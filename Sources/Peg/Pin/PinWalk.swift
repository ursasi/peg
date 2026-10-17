import AppKit
import CoreGraphics
import ImageIO

/// One continuous walk for the pin shortcut: the most recent copies first, then
/// the shots on disk that were never copied, newest first, looping at the end.
///
/// Two segments rather than two commands: the clipboard is only ever the last
/// thing copied, so without the disk tail the walk dead-ends quickly — and the
/// disk tail on its own would ignore everything copied from other apps.
@MainActor
final class PinWalk {
    static let shared = PinWalk()

    enum Item {
        case image(Data)
        case text(String)
        case file(URL)
    }

    private var items: [Item] = []
    private var builtAt = Date.distantPast
    private var cursor = 0
    private var lastUsed = Date.distantPast

    /// How stale the list may get before it is rebuilt. Copies and captures are
    /// both spotted live; the disk scan is the only expensive part.
    private let lifetime: TimeInterval = 2
    private let restartAfter: TimeInterval = 12

    func next() -> Item? {
        if Date().timeIntervalSince(lastUsed) > restartAfter { cursor = 0 }
        lastUsed = Date()

        if Date().timeIntervalSince(builtAt) > lifetime || items.isEmpty {
            rebuild()
        }
        guard !items.isEmpty else { return nil }
        let item = items[min(cursor, items.count - 1)]
        cursor = (cursor + 1) % items.count
        return item
    }

    /// Called when a new capture joins the shelf.
    func reset() {
        cursor = 0
        lastUsed = .distantPast
        builtAt = .distantPast
    }

    private func rebuild() {
        var next: [Item] = []
        var clipboardShots: [(date: Date, size: CGSize)] = []

        for entry in ClipboardHistory.shared.entries {
            switch entry.content {
            case .image(let data):
                next.append(.image(data))
                if let size = entry.pixelSize { clipboardShots.append((entry.date, size)) }
            case .text(let text):
                next.append(.text(text))
            }
        }

        // Shots on disk that were never seen on the clipboard. The same shot is
        // re-encoded on its way to disk and to the pasteboard, so the bytes
        // differ: match on "written at about the same moment, same pixels".
        for url in HistoryStore.files() {
            if isAlreadyOnClipboard(url, in: clipboardShots) { continue }
            next.append(.file(url))
        }

        items = next
        builtAt = Date()
    }

    private func isAlreadyOnClipboard(_ url: URL,
                                      in shots: [(date: Date, size: CGSize)]) -> Bool {
        guard !shots.isEmpty else { return false }
        let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        guard Date().timeIntervalSince(written) < 120 else { return false }
        guard let size = pixelSize(of: url) else { return false }
        return shots.contains { shot in
            abs(shot.date.timeIntervalSince(written)) < 5 && shot.size == size
        }
    }

    private func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
