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

    var isDrag: Bool {
        switch self {
        case .pen, .marker: return false
        default: return true
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

    var rect: CGRect {
        CGRect(x: min(start.x, end.x),
               y: min(start.y, end.y),
               width: abs(start.x - end.x),
               height: abs(start.y - end.y))
    }

    /// Too small to keep (a stray click).
    var isDegenerate: Bool {
        switch tool {
        case .text:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .pen, .marker:
            return points.count < 2
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
