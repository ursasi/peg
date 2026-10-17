import AppKit

/// Canned marks, used by the demo mode and the sample renderer.
enum AnnotationSample {
    static func shapes(for image: CGImage) -> [AnnotationShape] {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        var rect = AnnotationShape(tool: .rect, color: .systemRed, lineWidth: 6)
        rect.start = CGPoint(x: width * 0.12, y: height * 0.18)
        rect.end = CGPoint(x: width * 0.42, y: height * 0.36)

        var ellipse = AnnotationShape(tool: .ellipse, color: .systemYellow, lineWidth: 6)
        ellipse.start = CGPoint(x: width * 0.48, y: height * 0.20)
        ellipse.end = CGPoint(x: width * 0.68, y: height * 0.40)

        var arrow = AnnotationShape(tool: .arrow, color: .systemGreen, lineWidth: 6)
        arrow.start = CGPoint(x: width * 0.20, y: height * 0.62)
        arrow.end = CGPoint(x: width * 0.52, y: height * 0.78)

        var marker = AnnotationShape(tool: .marker, color: .systemYellow, lineWidth: 8)
        marker.points = stride(from: 0.55, through: 0.9, by: 0.01).map {
            CGPoint(x: width * $0, y: height * (0.60 + 0.01 * sin($0 * 40)))
        }

        var mosaic = AnnotationShape(tool: .mosaic, color: .white, lineWidth: 2)
        mosaic.start = CGPoint(x: width * 0.72, y: height * 0.50)
        mosaic.end = CGPoint(x: width * 0.90, y: height * 0.62)

        var text = AnnotationShape(tool: .text, color: .systemBlue, lineWidth: 2)
        text.start = CGPoint(x: width * 0.12, y: height * 0.80)
        text.text = "Peg 标注"
        text.fontSize = 34

        return [rect, ellipse, arrow, marker, mosaic, text]
    }
}
