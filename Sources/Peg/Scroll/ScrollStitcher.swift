import CoreGraphics
import Foundation

/// Accumulates frames into one tall image.
///
/// The first frame is the seed. A frame that moves the view downwards
/// contributes the rows that scrolled in at the bottom; a frame that moves it
/// upwards contributes the rows that scrolled in at the top. Revisiting rows
/// that are already in the picture contributes nothing, which is what makes
/// "scroll up a bit, then down again" safe.
struct ScrollStitcher {
    enum Update: Equatable {
        case seeded(rows: Int)
        case unchanged
        /// `rows` is signed: positive when the picture grew at the bottom.
        case appended(rows: Int, total: Int)
        /// Too fast, ambiguous, or the content did not line up.
        case failed
        /// Size changed, or the length limit was reached.
        case ignored
    }

    private(set) var width = 0
    private(set) var rows = 0
    private(set) var frames = 0

    private var bytes: [UInt8] = []
    private var last: ScrollFrame?
    private var lastFooter: [UInt8] = []
    private var stickyBottom = -1
    /// How many of the picture's rows sit above the top of the current view.
    private var viewOffset = 0
    private var reachedLimit = false
    private let maxRows: Int

    init(maxRows: Int = 40_000) {
        self.maxRows = maxRows
    }

    mutating func ingest(_ frame: ScrollFrame) -> Update {
        guard frame.width > 0, frame.height > 0 else { return .ignored }
        if width == 0 { width = frame.width }
        guard frame.width == width else { return .ignored }

        guard let previous = last else {
            last = frame
            bytes = frame.bytes
            rows = frame.height
            frames = 1
            return .seeded(rows: rows)
        }

        let result = ScrollMatcher.compare(previous, frame)
        switch result {
        case .unchanged:
            last = frame

        case .advance(let shift, let top, let bottom):
            guard !reachedLimit else { return .ignored }
            if stickyBottom < 0 {
                // The seed still contains the footer. Now that we know where it
                // is, drop it so it is not repeated on every screen.
                stickyBottom = bottom
                if bottom > 0, rows > bottom {
                    bytes.removeLast(bottom * width * 4)
                    rows -= bottom
                }
            }
            last = frame
            if shift > 0 {
                return scrollDown(frame, by: shift, bottom: bottom)
            } else if shift < 0 {
                return scrollUp(frame, by: -shift, top: top, bottom: bottom)
            } else {
                return .unchanged
            }

        case .failed:
            return .failed
        }
        return .unchanged
    }

    /// The view moved down: the picture only grows if we went past its bottom.
    private mutating func scrollDown(_ frame: ScrollFrame, by shift: Int, bottom: Int) -> Update {
        viewOffset += shift
        let visible = frame.height - max(0, bottom)
        let overflow = viewOffset + visible - rows
        guard overflow > 0 else { return .unchanged }

        let take = min(overflow, visible)
        let start = visible - take
        guard start >= 0, take > 0, rows + take <= maxRows else {
            reachedLimit = rows + take > maxRows
            return .ignored
        }
        let rowBytes = width * 4
        bytes.append(contentsOf: frame.bytes[(start * rowBytes)..<((start + take) * rowBytes)])
        rows += take
        viewOffset = max(0, rows - visible)
        frames += 1
        if stickyBottom > 0 {
            lastFooter = footerRows(of: frame, count: stickyBottom)
        }
        if rows >= maxRows { reachedLimit = true }
        return .appended(rows: take, total: rows)
    }

    /// The view moved up: rows that were already captured are skipped, rows
    /// above the top of the picture are added there.
    private mutating func scrollUp(_ frame: ScrollFrame, by shift: Int,
                                   top: Int, bottom: Int) -> Update {
        if viewOffset >= shift {
            viewOffset -= shift
            return .unchanged
        }
        let need = shift - viewOffset
        let available = frame.height - top - max(0, bottom)
        let take = min(need, available)
        guard take > 0, rows + take <= maxRows else {
            reachedLimit = take > 0 && rows + take > maxRows
            return .ignored
        }
        let rowBytes = width * 4
        bytes.insert(contentsOf: frame.bytes[(top * rowBytes)..<((top + take) * rowBytes)], at: 0)
        rows += take
        viewOffset = 0
        frames += 1
        if rows >= maxRows { reachedLimit = true }
        return .appended(rows: -take, total: rows)
    }

    func image() -> CGImage? {
        guard width > 0, rows > 0 else { return nil }
        var output = bytes
        if stickyBottom > 0, !lastFooter.isEmpty {
            output.append(contentsOf: lastFooter)
        }
        let total = rows + (stickyBottom > 0 ? stickyBottom : 0)
        guard output.count >= width * total * 4,
              let provider = CGDataProvider(data: Data(output[0..<(width * total * 4)]) as CFData)
        else { return nil }

        return CGImage(width: width,
                       height: total,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// A small stand-in for `image()`, sampled straight from the row store so a
    /// live preview does not have to materialise the whole tall picture on
    /// every captured frame. Aspect ratio is preserved and the result fits in
    /// `maxWidth` × `maxHeight` pixels.
    func previewImage(maxWidth: Int = 512, maxHeight: Int = 512) -> CGImage? {
        let rowBytes = width * 4
        let footerRows = stickyBottom > 0 ? lastFooter.count / rowBytes : 0
        let total = rows + footerRows
        guard width > 0, total > 0, maxWidth > 0, maxHeight > 0 else { return nil }

        let scale = min(1, min(Double(maxWidth) / Double(width),
                               Double(maxHeight) / Double(total)))
        let targetWidth = max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(total) * scale).rounded()))
        var output = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)

        for ty in 0..<targetHeight {
            // Centre each target pixel on the source row it represents.
            let sourceRow = min(total - 1, ((2 * ty + 1) * total) / (2 * targetHeight))
            let fromFooter = sourceRow >= rows
            let rowOffset = (fromFooter ? sourceRow - rows : sourceRow) * rowBytes
            let source = fromFooter ? lastFooter : bytes
            guard rowOffset >= 0, rowOffset + rowBytes <= source.count else { continue }
            let destinationRow = ty * targetWidth * 4
            for tx in 0..<targetWidth {
                let sourceColumn = min(width - 1, ((2 * tx + 1) * width) / (2 * targetWidth))
                let from = rowOffset + sourceColumn * 4
                let to = destinationRow + tx * 4
                output[to] = source[from]
                output[to + 1] = source[from + 1]
                output[to + 2] = source[from + 2]
                output[to + 3] = source[from + 3]
            }
        }

        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        return CGImage(width: targetWidth,
                       height: targetHeight,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: targetWidth * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// Exposed for the headless self test only.
    var flattenedRows: [UInt8] { bytes }

    private func footerRows(of frame: ScrollFrame, count: Int) -> [UInt8] {
        guard count > 0, count <= frame.height else { return [] }
        let start = (frame.height - count) * width * 4
        return Array(frame.bytes[start..<(frame.height * width * 4)])
    }
}
