import AppKit
import CoreImage

/// Where a shape is being drawn: the on-screen canvas (flipped, points per
/// pixel) or the output bitmap (CG's y-up, one unit per pixel).
struct DrawSpace {
    let scale: CGFloat
    let flipped: Bool
    let height: CGFloat

    func point(_ p: CGPoint) -> CGPoint {
        let x = p.x * scale
        let y = p.y * scale
        return flipped ? CGPoint(x: x, y: y) : CGPoint(x: x, y: height - y)
    }

    func rect(_ r: CGRect) -> CGRect {
        let scaled = r.scaled(by: scale)
        guard !flipped else { return scaled }
        return CGRect(x: scaled.minX,
                      y: height - scaled.maxY,
                      width: scaled.width,
                      height: scaled.height)
    }
}

/// Converts a base image and a list of marks into the final bitmap, and draws
/// the same marks on screen. Shapes live in image pixels; only the space
/// differs.
enum AnnotationRenderer {
    static func makeMosaic(_ image: CGImage, block: Int = 14) -> CGImage? {
        let smallWidth = max(1, image.width / block)
        let smallHeight = max(1, image.height / block)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let small = CGContext(data: nil, width: smallWidth, height: smallHeight,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        small.interpolationQuality = .high
        small.draw(image, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let low = small.makeImage() else { return nil }

        guard let big = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        big.interpolationQuality = .none
        big.draw(low, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return big.makeImage()
    }

    static func makeBlur(_ image: CGImage, radius: Double = 18) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        return context.createCGImage(output, from: input.extent)
    }

    static func draw(_ shape: AnnotationShape,
                     space: DrawSpace,
                     mosaic: CGImage?,
                     blurred: CGImage?,
                     imageSize: CGSize) {
        let lineWidth = max(1, shape.lineWidth * space.scale)

        switch shape.tool {
        case .rect, .ellipse:
            let rect = space.rect(shape.rect)
            let path = shape.tool == .rect ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)
            path.lineWidth = lineWidth
            shape.color.setStroke()
            path.stroke()

        case .arrow:
            drawArrow(from: space.point(shape.start), to: space.point(shape.end),
                      color: shape.color, lineWidth: lineWidth)

        case .pen, .marker:
            guard !shape.points.isEmpty else { return }
            let points = shape.points.map(space.point)
            let path = NSBezierPath()
            path.lineWidth = shape.tool == .marker ? max(lineWidth, 12 * space.scale) : lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if points.count == 1 {
                // A click with no drag still leaves a dot.
                let dot = CGRect(x: points[0].x - path.lineWidth / 2,
                                 y: points[0].y - path.lineWidth / 2,
                                 width: path.lineWidth,
                                 height: path.lineWidth)
                shape.color.setFill()
                NSBezierPath(ovalIn: dot).fill()
                return
            }
            // Smooth through the midpoints: the pointer samples are coarse, and
            // joining them straight looks like a polygon instead of a stroke.
            path.move(to: points[0])
            if points.count == 2 {
                path.line(to: points[1])
            } else {
                var from = points[0]
                for index in 1..<(points.count - 1) {
                    let control = points[index]
                    let next = points[index + 1]
                    let middle = CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
                    // Quadratic through (from, control, middle), spelled as cubic:
                    // NSBezierPath has no quadratic.
                    let c1 = CGPoint(x: from.x + 2.0 / 3.0 * (control.x - from.x),
                                     y: from.y + 2.0 / 3.0 * (control.y - from.y))
                    let c2 = CGPoint(x: middle.x + 2.0 / 3.0 * (control.x - middle.x),
                                     y: middle.y + 2.0 / 3.0 * (control.y - middle.y))
                    path.curve(to: middle, controlPoint1: c1, controlPoint2: c2)
                    from = middle
                }
                path.line(to: points[points.count - 1])
            }
            let colour = shape.tool == .marker ? shape.color.withAlphaComponent(0.35) : shape.color
            colour.setStroke()
            path.stroke()

        case .text:
            guard !shape.text.isEmpty else { return }
            let font = NSFont.systemFont(ofSize: max(8, shape.fontSize * space.scale), weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: shape.color
            ]
            let width = max(40, imageSize.width - shape.start.x - 8)
            // A caption can hold line breaks, so its box has to be measured
            // rather than assumed to be one line tall.
            let measured = (shape.text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes)
            let box = CGRect(x: shape.start.x,
                             y: shape.start.y,
                             width: width,
                             height: ceil(measured.height) + 2)
            (shape.text as NSString).draw(in: space.rect(box), withAttributes: attributes)

        case .mosaic, .blur:
            guard let source = shape.tool == .mosaic ? mosaic : blurred else { return }
            let area = space.rect(shape.rect)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: area).addClip()
            let full = CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
            if let context = NSGraphicsContext.current?.cgContext {
                context.interpolationQuality = .none
            }
            // The mosaic/blur source is a full-size image; draw it through the
            // same space so it lines up with the base.
            if space.flipped {
                NSImage(cgImage: source, size: NSSize(width: source.width, height: source.height))
                    .draw(in: NSRect(x: 0, y: 0,
                                     width: imageSize.width * space.scale,
                                     height: imageSize.height * space.scale))
            } else {
                let destination = space.rect(full)
                if let context = NSGraphicsContext.current?.cgContext {
                    context.draw(source, in: destination)
                }
            }
            NSGraphicsContext.restoreGraphicsState()

            shape.color.withAlphaComponent(0.3).setStroke()
            let outline = NSBezierPath(rect: area)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint,
                                  color: NSColor, lineWidth: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1 else { return }
        let angle = atan2(dy, dx)
        let head = min(length * 0.4, max(12, lineWidth * 4))

        let shaft = NSBezierPath()
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.move(to: start)
        shaft.line(to: end)
        color.setStroke()
        shaft.stroke()

        let left = CGPoint(x: end.x - head * cos(angle - .pi / 7),
                           y: end.y - head * sin(angle - .pi / 7))
        let right = CGPoint(x: end.x - head * cos(angle + .pi / 7),
                            y: end.y - head * sin(angle + .pi / 7))
        let tip = NSBezierPath()
        tip.lineWidth = lineWidth
        tip.lineCapStyle = .round
        tip.lineJoinStyle = .round
        tip.move(to: left)
        tip.line(to: end)
        tip.line(to: right)
        color.setStroke()
        tip.stroke()
    }

    /// Flatten the marks into a new image at native resolution. Uses an
    /// explicit bitmap so the result is the same size on any display and works
    /// without a window.
    /// Full-size mosaic/blur sources, so the live preview can show them before
    /// anything is committed.
    static func previewSources(for base: CGImage) -> (mosaic: CGImage?, blur: CGImage?) {
        (makeMosaic(base), makeBlur(base))
    }

    static func flatten(_ base: CGImage, shapes: [AnnotationShape]) -> CGImage? {
        guard !shapes.isEmpty else { return base }
        let width = base.width
        let height = base.height
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // CG's bitmap origin is bottom-left; drawing the image here puts its
        // top row at the top of the result.
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

        let space = DrawSpace(scale: 1, flipped: false, height: CGFloat(height))
        let needsMosaic = shapes.contains { $0.tool == .mosaic }
        let needsBlur = shapes.contains { $0.tool == .blur }
        let mosaic = needsMosaic ? makeMosaic(base) : nil
        let blurred = needsBlur ? makeBlur(base) : nil

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for shape in shapes {
            draw(shape, space: space, mosaic: mosaic, blurred: blurred,
                 imageSize: CGSize(width: width, height: height))
        }
        NSGraphicsContext.current = previous

        return context.makeImage()
    }
}

extension CGRect {
    func scaled(by factor: CGFloat) -> CGRect {
        CGRect(x: minX * factor, y: minY * factor, width: width * factor, height: height * factor)
    }
}
