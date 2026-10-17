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
    /// Content moved up (or left) by `rows`; `stickyTop` / `stickyBottom` rows
    /// never move and must be emitted only once.
    case advance(rows: Int, stickyTop: Int, stickyBottom: Int)
    /// Too fast, too little overlap, or repeating content: refuse to guess.
    case failed
}

/// Finds how far the content moved between two frames by matching rows.
///
/// The whole thing is deliberately conservative: a wrong stitch is worse than
/// a missing piece, so ambiguous matches are rejected instead of guessed.
enum ScrollMatcher {
    private static let identicalThreshold = 0.02
    private static let acceptThreshold = 0.25

    static func compare(_ previous: ScrollFrame, _ current: ScrollFrame) -> ScrollMatch {
        if previous.bytes == current.bytes { return .unchanged }

        // Browsers and ProMotion scroll at fractional offsets, so the same text
        // can be resampled differently in every frame. A gentle vertical blur
        // turns that noise back into a clean minimum.
        // Sticky chrome is judged on untouched pixels: after blurring, the row
        // where the header meets the content no longer looks identical.
        let top = stickyRun(previous, current, fromTop: true)
        let bottom = stickyRun(previous, current, fromTop: false)
        let match = compareBlurred(previous.blurredVertically(), current.blurredVertically(),
                                   top: top, bottom: bottom)
        guard case .advance(let rows, let top, let bottom) = match else { return match }
        // The blur finds the right neighbourhood but can wobble by a row.
        // Settle the exact integer offset on the untouched pixels.
        return .advance(rows: exactShift(rows, previous, current, top: top, bottom: bottom),
                        stickyTop: top, stickyBottom: bottom)
    }

    /// Re-score the neighbours on sharp pixels. Only overrules the blurred
    /// winner when one candidate is clearly better; on real, antialiased
    /// content all neighbours score alike and the blurred answer stands.
    private static func exactShift(_ shift: Int, _ a: ScrollFrame, _ b: ScrollFrame,
                                   top: Int, bottom: Int) -> Int {
        let lower = max(1, shift - 2)
        let upper = min(a.height - bottom - 1, shift + 2)
        guard lower <= upper else { return shift }
        var scores: [(Int, Double)] = []
        for candidate in lower...upper {
            scores.append((candidate, score(a, b, shift: candidate, top: top, bottom: bottom,
                                           columns: 64, rowStep: 1)))
        }
        scores.sort { $0.1 < $1.1 }
        guard let best = scores.first else { return shift }
        let decisive = scores.dropFirst().allSatisfy { $0.1 > best.1 + 0.004 }
        return decisive ? best.0 : shift
    }

    /// Quarter-resolution luma, used for the search. Sparse sampling at full
    /// resolution was noisy enough to rank the wrong shift first.
    private struct Pyramid {
        let width: Int
        let height: Int
        let values: [Double]

        init(_ frame: ScrollFrame, factor: Int) {
            let w = max(1, frame.width / factor)
            let h = max(1, frame.height / factor)
            var values = [Double](repeating: 0, count: w * h)
            // Average the block: point sampling aliases text into noise and
            // ranks the wrong shift first.
            for y in 0..<h {
                for x in 0..<w {
                    var total = 0.0
                    for dy in 0..<factor {
                        for dx in 0..<factor {
                            let row = min(frame.height - 1, y * factor + dy)
                            let column = min(frame.width - 1, x * factor + dx)
                            total += luma(frame, row: row, x: column)
                        }
                    }
                    values[y * w + x] = total / Double(factor * factor)
                }
            }
            self.width = w
            self.height = h
            self.values = values
        }

        func correlation(against other: Pyramid, shift: Int, top: Int, bottom: Int) -> Double {
            let first = top
            let last = height - bottom - shift
            guard last > first, other.height == height else { return 1 }
            let margin = max(1, width / 12)
            let span = max(1, width - margin * 2)
            let columns = 48
            var sumA = 0.0, sumB = 0.0, sumAB = 0.0, sumAA = 0.0, sumBB = 0.0
            var count = 0
            var row = first
            while row < last {
                let sourceRow = row + shift
                if sourceRow >= 0, sourceRow < height {
                    for column in 0..<columns {
                        let x = min(width - 1, margin + column * (span - 1) / (columns - 1))
                        let va = values[sourceRow * width + x]
                        let vb = other.values[row * other.width + x]
                        sumA += va; sumB += vb
                        sumAB += va * vb; sumAA += va * va; sumBB += vb * vb
                        count += 1
                    }
                }
                row += 1
            }
            guard count > 32 else { return 1 }
            let n = Double(count)
            let meanA = sumA / n, meanB = sumB / n
            let covariance = sumAB - n * meanA * meanB
            let varianceA = sumAA - n * meanA * meanA
            let varianceB = sumBB - n * meanB * meanB
            guard varianceA > 1, varianceB > 1 else { return 1 }
            return 1 - min(1, max(-1, covariance / (varianceA.squareRoot() * varianceB.squareRoot())))
        }
    }

    private static func compareBlurred(_ previous: ScrollFrame, _ current: ScrollFrame,
                                       top topInset: Int, bottom bottomInset: Int) -> ScrollMatch {
        guard previous.width == current.width,
              previous.height == current.height,
              previous.width > 16,
              previous.height > 64
        else { return .failed }

        let height = previous.height

        // Sparsely filled regions (dark pages, mostly empty lists) make a real
        // scroll score low even at shift 0, so "unchanged" is decided later by
        // comparing against the best shift instead of against a constant.

        let top = topInset
        let bottom = bottomInset
        let body = height - top - bottom
        guard body >= 48 else { return .failed }

        let minOverlap = max(32, body / 8)
        let maxShift = body - minOverlap
        guard maxShift >= 8 else { return .failed }

        // Search a quarter-resolution pyramid, then settle at full resolution.
        let factor = 4
        let coarseA = Pyramid(previous, factor: factor)
        let coarseB = Pyramid(current, factor: factor)
        let coarseTop = top / factor
        let coarseBottom = bottom / factor
        let coarseMax = max(1, (coarseB.height - coarseTop - coarseBottom) - 8)

        var best = 0
        var bestScore = Double.infinity
        for shift in 1...coarseMax {
            let value = coarseA.correlation(against: coarseB, shift: shift,
                                            top: coarseTop, bottom: coarseBottom)
            if value < bestScore {
                bestScore = value
                best = shift
            }
        }
        guard best > 0 else { return .failed }

        // The pyramid can overshoot the full-resolution limit; clamp before
        // building the refinement window or the range is empty.
        var refined = min(max(1, best * factor), maxShift)
        var refinedScore = Double.infinity
        let lower = max(1, refined - factor)
        let upper = min(maxShift, refined + factor)
        for shift in lower...upper {
            let value = score(previous, current, shift: shift, top: top, bottom: bottom,
                              columns: 64, rowStep: 1)
            if value < refinedScore {
                refinedScore = value
                refined = shift
            }
        }
        // Same vantage point, same density: how well does "nothing moved"
        // explain the frames?
        let zero = score(previous, current, shift: 0, top: top, bottom: bottom,
                         columns: 64, rowStep: 1)
        if zero <= identicalThreshold { return .unchanged }

        guard refinedScore <= acceptThreshold else {
            // No shift explains the difference; if standing still is just as
            // good, this was a redraw (caret, clock, spinner), not a scroll.
            return zero <= bestScore + 0.01 ? .unchanged : .failed
        }
        if zero <= refinedScore + 0.01 { return .unchanged }

        // Repeating layouts (blank pages, identical rows) produce several
        // equally good shifts. Refuse rather than duplicating a screen.
        let rivals = (1...maxShift).filter { shift in
            guard abs(shift - refined) > factor else { return false }
            let coarseShift = shift / factor
            guard coarseShift >= 1, coarseShift <= coarseMax else { return false }
            let value = coarseA.correlation(against: coarseB, shift: coarseShift,
                                            top: coarseTop, bottom: coarseBottom)
            return value <= bestScore + 0.05
        }
        for rival in rivals.prefix(6) {
            let value = score(previous, current, shift: rival, top: top, bottom: bottom,
                              columns: 64, rowStep: 1)
            if value <= refinedScore + 0.01 { return .failed }
        }

        return .advance(rows: refined, stickyTop: top, stickyBottom: bottom)
    }

    /// Human-readable scoring, used by the matcher CLI and PEG_DEBUG.
    static func diagnose(_ rawPrevious: ScrollFrame, _ rawCurrent: ScrollFrame) -> String {
        let previous = rawPrevious.blurredVertically()
        let current = rawCurrent.blurredVertically()
        guard previous.width == current.width, previous.height == current.height else {
            return "size mismatch"
        }
        let top = stickyRun(rawPrevious, rawCurrent, fromTop: true)
        let bottom = stickyRun(rawPrevious, rawCurrent, fromTop: false)
        let body = previous.height - top - bottom
        guard body >= 48 else { return "body too small top=\(top) bottom=\(bottom)" }

        let maxShift = body - max(32, body / 8)
        let factor = 4
        let coarseA = Pyramid(previous, factor: factor)
        let coarseB = Pyramid(current, factor: factor)
        let coarseTop = top / factor
        let coarseBottom = bottom / factor
        let coarseMax = max(1, (coarseB.height - coarseTop - coarseBottom) - 8)

        var pyramid: [(Int, Double)] = []
        for shift in 1...coarseMax {
            pyramid.append((shift, coarseA.correlation(against: coarseB, shift: shift,
                                                       top: coarseTop, bottom: coarseBottom)))
        }
        let ranked = pyramid.sorted { $0.1 < $1.1 }.prefix(4)

        let zero = score(previous, current, shift: 0, top: top, bottom: bottom, columns: 64, rowStep: 1)
        var text = "top=\(top) bottom=\(bottom) maxShift=\(maxShift) zero=\(fmt(zero)) pyramid=["
        text += ranked.map { "\($0.0 * factor):\(fmt($0.1))" }.joined(separator: " ")
        text += "] "

        if let best = ranked.first {
            let centre = best.0 * factor
            var fine: [String] = []
            let lower = max(1, centre - factor)
            let upper = min(maxShift, centre + factor)
            for shift in lower...Swift.max(lower, upper) {
                let value = score(previous, current, shift: shift, top: top, bottom: bottom,
                                  columns: 64, rowStep: 1)
                fine.append("\(shift):\(fmt(value))")
            }
            text += "fine=[" + fine.joined(separator: " ") + "] "
        }
        text += "-> \(compareBlurred(previous, current, top: top, bottom: bottom))"
        return text
    }

    /// Best candidate shifts, for debugging real captures.
    static func ranking(_ a: ScrollFrame, _ b: ScrollFrame, limit: Int = 8) -> [(shift: Int, score: Double)] {
        let top = stickyRun(a, b, fromTop: true)
        let bottom = stickyRun(a, b, fromTop: false)
        let body = a.height - top - bottom
        guard body >= 48 else { return [] }
        let maxShift = body - max(32, body / 8)
        guard maxShift >= 8 else { return [] }
        var all: [(Int, Double)] = []
        for shift in 0...maxShift {
            all.append((shift, score(a, b, shift: shift, top: top, bottom: bottom, columns: 64, rowStep: 2)))
        }
        return all.sorted { $0.1 < $1.1 }.prefix(limit).map { (shift: $0.0, score: $0.1) }
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// 1 − Pearson correlation of the sampled luma values.
    ///
    /// A plain absolute difference is dominated by empty background: a dark
    /// page scrolled by 200 pixels still scores "almost the same". Correlation
    /// ignores the flat parts and judges the structure that actually moves.
    private static func score(_ a: ScrollFrame, _ b: ScrollFrame, shift: Int,
                              top: Int, bottom: Int, columns: Int, rowStep: Int) -> Double {
        let first = top
        let last = a.height - bottom - shift
        guard last > first else { return 1 }

        var sumA = 0.0
        var sumB = 0.0
        var sumAB = 0.0
        var sumAA = 0.0
        var sumBB = 0.0
        var count = 0

        let width = a.width
        let margin = max(1, width / 12)
        let span = max(1, width - margin * 2)

        var row = first
        while row < last {
            let aRow = row + shift
            if aRow >= 0, aRow < a.height {
                for column in 0..<columns {
                    let x = min(width - 1, margin + column * (span - 1) / max(1, columns - 1))
                    let va = luma(a, row: aRow, x: x)
                    let vb = luma(b, row: row, x: x)
                    sumA += va
                    sumB += vb
                    sumAB += va * vb
                    sumAA += va * va
                    sumBB += vb * vb
                    count += 1
                }
            }
            row += rowStep
        }

        guard count > 8 else { return 1 }
        let n = Double(count)
        let meanA = sumA / n
        let meanB = sumB / n
        let covariance = sumAB - n * meanA * meanB
        let varianceA = sumAA - n * meanA * meanA
        let varianceB = sumBB - n * meanB * meanB
        guard varianceA > 1, varianceB > 1 else { return 1 }
        let correlation = covariance / (varianceA.squareRoot() * varianceB.squareRoot())
        return 1 - min(1, max(-1, correlation))
    }

    private static func luma(_ frame: ScrollFrame, row: Int, x: Int) -> Double {
        let index = (row * frame.width + x) * 4
        return Double(frame.bytes[index]) * 0.299
            + Double(frame.bytes[index + 1]) * 0.587
            + Double(frame.bytes[index + 2]) * 0.114
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
}
