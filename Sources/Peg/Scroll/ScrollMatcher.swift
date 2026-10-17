import CoreGraphics

/// One captured frame of the scrolling region: RGBA8, row 0 = top row.
struct ScrollFrame {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // A bitmap context already stores the top row first.
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard ok else { return nil }

        self.width = width
        self.height = height
        self.bytes = buffer
    }
}

extension ScrollFrame {
    /// (1, 2, 1) vertical blur. Browsers and ProMotion displays scroll at
    /// fractional offsets, which resamples text; without this every row differs
    /// slightly and no integer shift wins.
    func blurredVertically() -> ScrollFrame {
        guard height > 2 else { return self }
        var output = bytes
        let rowBytes = width * 4
        for y in 1..<(height - 1) {
            let above = (y - 1) * rowBytes
            let here = y * rowBytes
            let below = (y + 1) * rowBytes
            for i in 0..<rowBytes {
                let value = (Int(bytes[above + i]) + 2 * Int(bytes[here + i]) + Int(bytes[below + i])) / 4
                output[here + i] = UInt8(value)
            }
        }
        return ScrollFrame(width: width, height: height, bytes: output)
    }
}

enum ScrollMatch: Equatable {
    /// Nothing moved (or only a caret blinked).
    case unchanged
    /// Content moved by `rows`: positive means the page scrolled down (content
    /// moved up), negative means it scrolled up. `stickyTop` / `stickyBottom`
    /// rows never move and must be emitted only once.
    case advance(rows: Int, stickyTop: Int, stickyBottom: Int)
    /// Too fast, too little overlap, or repeating content: refuse to guess.
    case failed
}

/// Finds how far the content moved between two frames.
///
/// Every row is reduced to a short fingerprint (its brightness profile). The
/// two sequences of fingerprints are then aligned by brute force over every
/// plausible shift. Correlation over sampled pixels was tried first and kept
/// picking aliases on sparse pages — a row fingerprint is what actually
/// identifies "this row is *that* row, 570 lines earlier".
enum ScrollMatcher {
    /// How many evenly spaced samples make up one row's fingerprint.
    private static let samples = 16
    /// A perfect match is ~0; above this the frames do not really line up.
    private static let acceptCost = 0.03

    static func compare(_ previous: ScrollFrame, _ current: ScrollFrame) -> ScrollMatch {
        if previous.bytes == current.bytes { return .unchanged }

        let top = stickyRun(previous, current, fromTop: true)
        let bottom = stickyRun(previous, current, fromTop: false)
        let body = min(previous.height, current.height) - top - bottom
        guard body >= 48 else { return .failed }

        let minOverlap = max(48, body / 12)

        let a = RowProfile(previous, samples: samples)
        let b = RowProfile(current, samples: samples)
        guard a.height == b.height, a.stride == b.stride else { return .failed }

        // Coarse pass over every shift in both directions, every third row.
        var coarse: [(shift: Int, cost: Double)] = []
        let limit = body - minOverlap
        guard limit >= 6 else { return .failed }
        for shift in -limit...limit {
            coarse.append((shift, cost(a, b, shift: shift, top: top, bottom: bottom, step: 3)))
        }
        guard let best = coarse.min(by: { $0.cost < $1.cost }) else { return .failed }

        let zeroCost = cost(a, b, shift: 0, top: top, bottom: bottom, step: 1)

        // Refine around the winner on every row.
        var winner = best
        for shift in max(-limit, best.shift - 4)...min(limit, best.shift + 4) {
            let value = cost(a, b, shift: shift, top: top, bottom: bottom, step: 1)
            if value < winner.cost { winner = (shift, value) }
        }
        guard winner.shift != 0 else { return .unchanged }
        guard winner.cost <= acceptCost else {
            // No shift explains the difference; if standing still is no worse
            // this was a redraw (caret, clock, spinner), not a scroll.
            return zeroCost <= acceptCost ? .unchanged : .failed
        }
        // Standing still explains the frames just as well: a redraw, not a scroll.
        if zeroCost <= winner.cost * 1.6 + 0.0005 { return .unchanged }

        // Repeating layouts give several equally good shifts; refuse rather
        // than duplicating a screen.
        let rivals = coarse.filter {
            abs($0.shift - winner.shift) > 12 && $0.cost <= winner.cost + 0.004
        }
        if !rivals.isEmpty {
            for rival in rivals.prefix(4) {
                let value = cost(a, b, shift: rival.shift, top: top, bottom: bottom, step: 1)
                if value <= winner.cost + 0.004 { return .failed }
            }
        }

        return .advance(rows: winner.shift, stickyTop: top, stickyBottom: bottom)
    }

    /// Per-row fingerprint.
    ///
    /// Brightness samples alone cannot tell two lines of text apart on a sparse
    /// page — most columns are blank. Ink density, contrast spread and where
    /// the ink starts are what actually identify a row, so they are part of the
    /// fingerprint too. Everything is kept on the same 0...255 scale so one
    /// cost function covers all of it.
    private struct RowProfile {
        let width: Int
        let height: Int
        let stride: Int
        let values: [Float]

        init(_ frame: ScrollFrame, samples: Int) {
            let width = frame.width
            let height = frame.height
            let stride = samples + 4
            var values = [Float](repeating: 0, count: height * stride)

            let margin = max(1, width / 16)
            let span = max(1, width - margin * 2)
            var columns = [Int](repeating: 0, count: samples)
            for i in 0..<samples {
                columns[i] = min(width - 1, margin + i * (span - 1) / max(1, samples - 1))
            }

            for y in 0..<height {
                let rowBase = y * width * 4
                var sum = 0.0
                var sumSquares = 0.0
                var ink = 0.0
                var count = 0.0
                var firstInk = -1

                // Every other pixel is plenty for density and contrast.
                var x = 0
                while x < width {
                    let index = rowBase + x * 4
                    let luma = Double(frame.bytes[index]) * 0.299
                        + Double(frame.bytes[index + 1]) * 0.587
                        + Double(frame.bytes[index + 2]) * 0.114
                    sum += luma
                    sumSquares += luma * luma
                    if luma < 128 {
                        ink += 1
                        if firstInk < 0 { firstInk = x }
                    }
                    count += 1
                    x += 2
                }
                let mean = count > 0 ? sum / count : 0
                let variance = max(0, (count > 0 ? sumSquares / count : 0) - mean * mean)

                let out = y * stride
                values[out] = Float(mean)
                values[out + 1] = Float(min(255, variance.squareRoot() * 2))
                values[out + 2] = Float(ink / max(1, count) * 255)
                values[out + 3] = Float(firstInk >= 0 ? min(255, Double(firstInk) / Double(width) * 255) : 255)

                for i in 0..<samples {
                    let index = rowBase + columns[i] * 4
                    let luma = Double(frame.bytes[index]) * 0.299
                        + Double(frame.bytes[index + 1]) * 0.587
                        + Double(frame.bytes[index + 2]) * 0.114
                    values[out + 4 + i] = Float(luma - mean)
                }
            }
            self.width = width
            self.height = height
            self.stride = stride
            self.values = values
        }
    }

    /// Mean squared difference of the overlapping row fingerprints, in [0, 1].
    private static func cost(_ a: RowProfile, _ b: RowProfile, shift: Int,
                             top: Int, bottom: Int, step: Int) -> Double {
        let first = top
        let last = min(a.height - bottom - shift, b.height - bottom)
        guard last > first else { return 1 }

        let stride = a.stride
        var total = 0.0
        var rows = 0
        var row = first
        while row < last {
            let source = row + shift
            if source < 0 || source >= a.height {
                row += step
                continue
            }
            let ai = source * stride
            let bi = row * stride
            var rowCost = 0.0
            for k in 0..<stride {
                let d = Double(a.values[ai + k] - b.values[bi + k])
                rowCost += d * d
            }
            // Each row's mean sits in slot 0; the samples are centred, so both
            // halves are on the same 0...255 scale.
            total += rowCost
            rows += 1
            row += step
        }
        guard rows > 0 else { return 1 }
        return total / (Double(rows) * Double(stride) * 255.0 * 255.0)
    }

    /// Human-readable scoring, used by the matcher CLI and PEG_DEBUG.
    static func diagnose(_ rawPrevious: ScrollFrame, _ rawCurrent: ScrollFrame) -> String {
        guard rawPrevious.width == rawCurrent.width, rawPrevious.height == rawCurrent.height else {
            return "size mismatch"
        }
        let top = stickyRun(rawPrevious, rawCurrent, fromTop: true)
        let bottom = stickyRun(rawPrevious, rawCurrent, fromTop: false)
        let body = rawPrevious.height - top - bottom
        guard body >= 48 else { return "body too small top=\(top) bottom=\(bottom)" }

        let a = RowProfile(rawPrevious.blurredVertically(), samples: samples)
        let b = RowProfile(rawCurrent.blurredVertically(), samples: samples)
        let limit = body - max(48, body / 12)
        guard limit >= 6 else { return "no room to scroll" }

        var ranked: [(Int, Double)] = []
        for shift in -limit...limit {
            ranked.append((shift, cost(a, b, shift: shift, top: top, bottom: bottom, step: 3)))
        }
        ranked.sort { $0.1 < $1.1 }
        let head = ranked.prefix(5).map { "\($0.0):" + String(format: "%.3f", $0.1) }.joined(separator: " ")
        let zero = cost(a, b, shift: 0, top: top, bottom: bottom, step: 1)
        return "top=\(top) bottom=\(bottom) limit=\(limit) still=" + String(format: "%.3f", zero)
            + " best=[\(head)] -> " + "\(compare(rawPrevious, rawCurrent))"
    }

    /// How many leading (or trailing) rows are identical in both frames.
    /// A sticky header or footer should be stitched once, not on every screen.
    private static func stickyRun(_ a: ScrollFrame, _ b: ScrollFrame, fromTop: Bool) -> Int {
        let limit = a.height / 4
        var count = 0
        while count < limit {
            let row = fromTop ? count : a.height - 1 - count
            if rowDistance(a, b, row: row, columns: 32) > 0.8 { break }
            count += 1
        }
        return count >= 4 ? count : 0
    }

    /// Mean absolute luma difference of one raw row, used to spot rows that
    /// do not move at all (a header, a footer).
    private static func rowDistance(_ a: ScrollFrame, _ b: ScrollFrame, row: Int, columns: Int) -> Double {
        guard row >= 0, row < a.height else { return 255 }
        let width = a.width
        let margin = max(1, width / 12)
        let span = max(1, width - margin * 2)
        var total = 0.0
        for column in 0..<columns {
            let x = min(width - 1, margin + column * (span - 1) / max(1, columns - 1))
            total += abs(luma(a, row: row, x: x) - luma(b, row: row, x: x))
        }
        return total / Double(columns)
    }

    private static func luma(_ frame: ScrollFrame, row: Int, x: Int) -> Double {
        let index = (row * frame.width + x) * 4
        return Double(frame.bytes[index]) * 0.299
            + Double(frame.bytes[index + 1]) * 0.587
            + Double(frame.bytes[index + 2]) * 0.114
    }
}
