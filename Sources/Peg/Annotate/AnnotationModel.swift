import AppKit

enum AnnotationTool: Int, CaseIterable {
    case rect, ellipse, arrow, pen, marker, text, mosaic, blur

    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3.fill"
        case .blur: return "drop.fill"
        }
    }

    /// The key that picks this tool. A letter is easier to remember than its
    /// position in a row of eight.
    var key: String {
        switch self {
        case .rect: return "r"
        case .ellipse: return "o"
        case .arrow: return "a"
        case .pen: return "p"
        case .marker: return "h"
        case .text: return "t"
        case .mosaic: return "m"
        case .blur: return "b"
        }
    }

    /// Letters first, then the old digits so both keep working.
    static func tool(forKey key: String) -> AnnotationTool? {
        if let letter = allCases.first(where: { $0.key == key.lowercased() }) { return letter }
        guard let digit = Int(key), digit >= 1 else { return nil }
        return AnnotationTool(rawValue: digit - 1)
    }

    var title: String {
        switch self {
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .pen: return "铅笔"
        case .marker: return "马克笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        case .blur: return "模糊"
        }
    }

}

/// One mark on the image. Coordinates are always in image pixels, top-left
/// origin, so the same shape draws identically on screen and into the output
/// bitmap.
struct AnnotationShape {
    var tool: AnnotationTool
    var color: NSColor
    var lineWidth: CGFloat
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var points: [CGPoint] = []
    var text: String = ""
    var fontSize: CGFloat = 0

    /// Re-express a shape drawn in one coordinate system in another: used to
    /// turn marks made on the frozen screen into marks on the cropped bitmap.
    func transformed(scale: CGFloat, offset: CGPoint) -> AnnotationShape {
        var copy = self
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - offset.x) * scale, y: (point.y - offset.y) * scale)
        }
        copy.start = map(start)
        copy.end = map(end)
        copy.points = points.map(map)
        copy.lineWidth = lineWidth * scale
        copy.fontSize = fontSize * scale
        return copy
    }

    var rect: CGRect {
        let box = CGRect(x: min(start.x, end.x),
                         y: min(start.y, end.y),
                         width: abs(start.x - end.x),
                         height: abs(start.y - end.y))
        // Freehand strokes carry their extent in `points`; start/end are unused
        // there, so unioning them would drag the box back to (0, 0).
        guard !points.isEmpty else { return box }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return box }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Too small to keep (a stray click).
    var isDegenerate: Bool {
        switch tool {
        case .text:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .pen, .marker:
            // A single tap is a deliberate dot, not an accident.
            return points.isEmpty
        default:
            let bounds = rect
            return bounds.width < 4 || bounds.height < 4
        }
    }
}

enum AnnotationPalette {
    static let colors: [NSColor] = [
        .systemRed,
        .systemYellow,
        .systemGreen,
        .systemBlue,
        .white,
        .black
    ]

    static let widths: [CGFloat] = [2, 4, 8]
}
