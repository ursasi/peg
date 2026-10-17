import AppKit
import CoreGraphics

/// Headless checks for the stitcher: build a tall synthetic document, slide a
/// viewport over it, and make sure the matcher reports the exact movement.
/// Run with `PEG_SELFTEST=1`.
enum ScrollSelfTest {
    static func run() -> Int32 {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("  ok   \(name)")
            } else {
                failures += 1
                print("  FAIL \(name) \(detail())")
            }
        }

        let width = 640
        let viewport = 600
        let doc = makeDoc(width: width, height: 4000, seed: 20_260_517)

        print("scroll matcher")

        // Straight scrolls, no chrome.
        for delta in [137, 300, 41, 512] {
            let a = frame(doc, offset: 0, height: viewport)
            let b = frame(doc, offset: delta, height: viewport)
            switch ScrollMatcher.compare(a, b) {
            case .advance(let rows, let top, let bottom):
                check("advance \(delta)", rows == delta && top == 0 && bottom == 0,
                      "got rows=\(rows) top=\(top) bottom=\(bottom)")
            case let other:
                check("advance \(delta)", false, "got \(other)")
            }
        }

        // Standing still.
        let still = frame(doc, offset: 240, height: viewport)
        check("unchanged", ScrollMatcher.compare(still, frame(doc, offset: 240, height: viewport)) == .unchanged)

        // A blinking caret must not look like a scroll.
        var caret = frame(doc, offset: 240, height: viewport)
        var caretBytes = caret.bytes
        for x in 40..<44 {
            for channel in 0..<3 {
                caretBytes[((viewport / 2) * width + x) * 4 + channel] = 20
            }
        }
        caret = ScrollFrame(width: caret.width, height: caret.height, bytes: caretBytes)
        let caretMatch = ScrollMatcher.compare(still, caret)
        if caretMatch != .unchanged { print("       caret diagnose: \(ScrollMatcher.diagnose(still, caret))") }
        check("caret is not a scroll", caretMatch == .unchanged)

        // Sticky header and footer: reported once, exact shift underneath.
        let header = makeBandRows(width: width, count: 36, seed: 7)
        let footer = makeBandRows(width: width, count: 28, seed: 9)
        for delta in [86, 233, 410] {
            let a = frame(doc, offset: 120, height: viewport, header: header, footer: footer)
            let b = frame(doc, offset: 120 + delta, height: viewport, header: header, footer: footer)
            switch ScrollMatcher.compare(a, b) {
            case .advance(let rows, let top, let bottom):
                check("sticky advance \(delta)",
                      rows == delta && abs(top - header.count) <= 2 && abs(bottom - footer.count) <= 2,
                      "got rows=\(rows) top=\(top) bottom=\(bottom)")
            case let other:
                check("sticky advance \(delta)", false, "got \(other)")
            }
        }

        // Jumping further than the overlap allows must fail, not guess.
        let jump = ScrollMatcher.compare(frame(doc, offset: 0, height: viewport),
                                         frame(doc, offset: 900, height: viewport))
        check("too fast fails", jump == .failed, "got \(jump)")

        // Repeating content is ambiguous: refuse.
        let periodic = makePeriodicDoc(width: width, height: 2600, period: 60)
        let repeatMatch = ScrollMatcher.compare(frame(periodic, offset: 0, height: viewport),
                                                frame(periodic, offset: 137, height: viewport))
        check("repeating content fails", repeatMatch == .failed, "got \(repeatMatch)")

        // A whole session: seed, then many appends with sticky chrome.
        print("stitcher")
        var stitcher = ScrollStitcher()
        let headerRows = makeBandRows(width: width, count: 36, seed: 7)
        let footerRows = makeBandRows(width: width, count: 28, seed: 9)
        let step = 96
        let lastOffset = 1344
        var offset = 0
        var stepsExact = true
        while offset <= lastOffset {
            let view = frame(doc, offset: offset, height: viewport, header: headerRows, footer: footerRows)
            let update = stitcher.ingest(view)
            if case .appended(let appended, _) = update, appended != step {
                stepsExact = false
                print("       step at offset \(offset) appended \(appended)")
            }
            if case .failed = update {
                print("       step at offset \(offset) failed")
            }
            offset += step
        }
        check("every step appended \(step) rows", stepsExact)

        let bodyRows = viewport - headerRows.count - footerRows.count
        let expectedTotal = headerRows.count + lastOffset + bodyRows + footerRows.count
        check("stitched height", stitcher.rows + footerRows.count == expectedTotal,
              "got \(stitcher.rows + footerRows.count) want \(expectedTotal)")

        var expected: [UInt8] = []
        for row in headerRows { expected.append(contentsOf: row) }
        // The body sits below the sticky header, so the first body row is
        // doc[header.count] rather than doc[0].
        for index in headerRows.count..<(headerRows.count + lastOffset + bodyRows) {
            expected.append(contentsOf: doc.rows[index])
        }
        for row in footerRows { expected.append(contentsOf: row) }

        var produced = stitcher.flattenedRows
        for row in footerRows { produced.append(contentsOf: row) }
        if produced != expected {
            let rowBytes = width * 4
            var firstRow = -1
            for index in 0..<min(produced.count, expected.count) where produced[index] != expected[index] {
                firstRow = index / rowBytes
                break
            }
            print("       first differing row: \(firstRow) of \(expected.count / rowBytes)")
        }
        check("stitched pixels match the document", produced == expected,
              "got \(produced.count) bytes want \(expected.count)")

        // Annotation rendering: shapes are stored in image pixels and must
        // land at the same place in the flattened bitmap.
        print("annotations")
        if let base = makeWhiteImage(width: 200, height: 100) {
            var rectShape = AnnotationShape(tool: .rect, color: .systemRed, lineWidth: 6)
            rectShape.start = CGPoint(x: 20, y: 10)
            rectShape.end = CGPoint(x: 120, y: 60)

            var textShape = AnnotationShape(tool: .text, color: .systemBlue, lineWidth: 2)
            textShape.start = CGPoint(x: 20, y: 70)
            textShape.text = "PEG"
            textShape.fontSize = 20

            if let flat = AnnotationRenderer.flatten(base, shapes: [rectShape, textShape]) {
                check("flatten keeps the size", flat.width == 200 && flat.height == 100,
                      "got \(flat.width)x\(flat.height)")
                if let pixels = PixelSampler(flat) {
                    let onEdge = pixels.rgb(x: 70, y: 10)
                    let outside = pixels.rgb(x: 70, y: 2)
                    let red = onEdge.map { $0.0 > 150 && $0.1 < 120 } ?? false
                    let clean = outside.map { $0.0 > 200 && $0.1 > 200 && $0.2 > 200 } ?? false
                    check("rect is drawn at the top, not mirrored", red && clean,
                          "edge=\(String(describing: onEdge)) outside=\(String(describing: outside))")
                    let textInk = (20..<80).contains { x in
                        (70..<95).contains { y in
                            (pixels.rgb(x: x, y: y)?.0 ?? 255) < 200
                        }
                    }
                    check("text is drawn", textInk)
                }
            } else {
                check("flatten produces an image", false)
            }

            var mosaic = AnnotationShape(tool: .mosaic, color: .white, lineWidth: 2)
            mosaic.start = CGPoint(x: 10, y: 10)
            mosaic.end = CGPoint(x: 190, y: 90)
            if let flat = AnnotationRenderer.flatten(base, shapes: [mosaic]) {
                check("mosaic keeps the size", flat.width == 200 && flat.height == 100)
            } else {
                check("mosaic flattens", false)
            }
        } else {
            check("white test image", false)
        }

        print(failures == 0 ? "all good" : "\(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func makeWhiteImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Synthetic documents

    private struct Doc {
        let width: Int
        let rows: [[UInt8]]
    }

    private static func makeDoc(width: Int, height: Int, seed: UInt32) -> Doc {
        var state = seed
        func random() -> UInt32 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return state >> 8
        }
        var rows: [[UInt8]] = []
        rows.reserveCapacity(height)
        for _ in 0..<height {
            var row = [UInt8](repeating: 255, count: width * 4)
            for _ in 0..<(1 + Int(random() % 4)) {
                let start = Int(random() % UInt32(width))
                let length = 8 + Int(random() % 70)
                for x in start..<min(width, start + length) {
                    let value = UInt8(30 + Int(random() % 70))
                    row[x * 4] = value
                    row[x * 4 + 1] = value
                    row[x * 4 + 2] = value
                }
            }
            rows.append(row)
        }
        return Doc(width: width, rows: rows)
    }

    private static func makePeriodicDoc(width: Int, height: Int, period: Int) -> Doc {
        let block = makeDoc(width: width, height: period, seed: 4242)
        let rows = (0..<height).map { block.rows[$0 % period] }
        return Doc(width: width, rows: rows)
    }

    private static func makeBandRows(width: Int, count: Int, seed: UInt32) -> [[UInt8]] {
        var state = seed
        var rows: [[UInt8]] = []
        for _ in 0..<count {
            var row = [UInt8](repeating: 200, count: width * 4)
            let start = Int(state % UInt32(width / 2))
            state = state &* 1_664_525 &+ 1_013_904_223
            for x in start..<min(width, start + 120) {
                row[x * 4] = 90
                row[x * 4 + 1] = 110
                row[x * 4 + 2] = 140
            }
            rows.append(row)
        }
        return rows
    }

    private static func frame(_ doc: Doc, offset: Int, height: Int,
                              header: [[UInt8]]? = nil, footer: [[UInt8]]? = nil) -> ScrollFrame {
        var rows: [[UInt8]] = []
        rows.reserveCapacity(height)
        for index in 0..<height {
            let clamped = min(max(0, offset + index), doc.rows.count - 1)
            rows.append(doc.rows[clamped])
        }
        if let header {
            for (index, row) in header.enumerated() where index < height {
                rows[index] = row
            }
        }
        if let footer {
            let start = height - footer.count
            if start >= 0 {
                for (index, row) in footer.enumerated() where start + index < height {
                    rows[start + index] = row
                }
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(height * doc.width * 4)
        for row in rows { bytes.append(contentsOf: row) }
        return ScrollFrame(width: doc.width, height: height, bytes: bytes)
    }
}
