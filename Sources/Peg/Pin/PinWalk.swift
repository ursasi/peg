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
        DebugLog.log("pinwalk \(cursor)/\(items.count) -> \(PinWalk.describe(item))")
        return item
    }

    /// Called when a new capture joins the shelf.
    func reset() {
        cursor = 0
        lastUsed = .distantPast
        builtAt = .distantPast
    }

    private func rebuild() {
        struct Candidate {
            let date: Date
            let item: Item
        }

        var candidates: [Candidate] = []
        var clipboardShots: [(date: Date, size: CGSize)] = []

        for entry in ClipboardHistory.shared.entries {
            switch entry.content {
            case .image(let data):
                candidates.append(Candidate(date: entry.date, item: .image(data)))
                if let size = entry.pixelSize { clipboardShots.append((entry.date, size)) }
            case .text(let text):
                candidates.append(Candidate(date: entry.date, item: .text(text)))
            }
        }

        // Shots on disk that were never seen on the clipboard. The same shot is
        // re-encoded on its way to disk and to the pasteboard, so the bytes
        // differ: match on "written at about the same moment, same pixels".
        for url in HistoryStore.files() {
            let written = modificationDate(of: url)
            if isAlreadyOnClipboard(written: written, size: pixelSize(of: url),
                                    in: clipboardShots) { continue }
            candidates.append(Candidate(date: written, item: .file(url)))
        }

        // One merged timeline: newest first, no matter which side it came from.
        // Appending the disk shots after the clipboard ones would put an old
        // capture ahead of something copied a second ago.
        candidates.sort { $0.date > $1.date }
        items = candidates.map(\.item)
        builtAt = Date()
    }

    private static func describe(_ item: Item) -> String {
        switch item {
        case .image(let data): return "image(\(data.count) bytes)"
        case .text(let text): return "text(\(text.prefix(24)))"
        case .file(let url): return "file(\(url.lastPathComponent))"
        }
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private func isAlreadyOnClipboard(written: Date,
                                      size: CGSize?,
                                      in shots: [(date: Date, size: CGSize)]) -> Bool {
        guard !shots.isEmpty, let size else { return false }
        guard Date().timeIntervalSince(written) < 120 else { return false }
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
