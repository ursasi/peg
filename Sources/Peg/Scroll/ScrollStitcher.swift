import CoreGraphics
import Foundation

/// Accumulates frames into one tall image.
///
/// The first frame is the seed. Every later frame contributes only the rows
/// that scrolled into view at the bottom, with the fixed footer taken out and
/// added back exactly once at the end.
struct ScrollStitcher {
    enum Update: Equatable {
        case seeded(rows: Int)
        case unchanged
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

        case .advance(let advance, _, let bottom):
            guard !reachedLimit else { return .ignored }
            if stickyBottom < 0 {
                // The seed still contains the footer. Now that we know where it
                // is, drop it so it is not repeated on every screen.
                stickyBottom = bottom
                if bottom > 0, rows > bottom {
                    bytes.removeLast(bottom * width * 4)
                    rows -= bottom
                }
                lastFooter = footerRows(of: frame, count: bottom)
            }
            let start = frame.height - bottom - advance
            let end = frame.height - bottom
            guard start >= 0, end <= frame.height, advance > 0 else {
                last = frame
                return .failed
            }
            bytes.append(contentsOf: frame.bytes[(start * width * 4)..<(end * width * 4)])
            rows += advance
            frames += 1
            last = frame
            if stickyBottom > 0 {
                lastFooter = footerRows(of: frame, count: stickyBottom)
            }
            if rows >= maxRows {
                reachedLimit = true
                return .ignored
            }
            return .appended(rows: advance, total: rows)

        case .failed:
            return .failed
        }
        return .unchanged
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

    /// Exposed for the headless self test only.
    var flattenedRows: [UInt8] { bytes }

    private func footerRows(of frame: ScrollFrame, count: Int) -> [UInt8] {
        guard count > 0, count <= frame.height else { return [] }
        let start = (frame.height - count) * width * 4
        return Array(frame.bytes[start..<(frame.height * width * 4)])
    }
}
