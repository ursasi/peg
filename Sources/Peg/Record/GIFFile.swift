import AppKit
import CoreGraphics
import ImageIO

/// Animated GIF support for the shelf's hover preview: the shelf otherwise only
/// ever sees a still frame, which makes a recording look like a plain capture.
enum GIFFile {
    /// Decoding a 145-frame GIF costs a couple of hundred milliseconds, and the
    /// hover preview used to do it again every time the pointer came back.
    private static var cache: (url: URL, frames: [CGImage], delays: [Double])?

    static func cachedFrames(_ url: URL) -> ([CGImage], [Double]) {
        if let cache, cache.url == url { return (cache.frames, cache.delays) }
        let frames = frames(url)
        let delays = delays(url)
        cache = (url, frames, delays)
        return (frames, delays)
    }

    static func frames(_ url: URL, maxPixel: CGFloat = 1400) -> [CGImage] {
        guard isAnimated(url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return [] }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return [] }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            if let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
                frames.append(frame)
            }
        }
        return frames
    }

    static func delays(_ url: URL) -> [Double] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        var delays: [Double] = []
        delays.reserveCapacity(count)
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
            let delay = unclamped ?? clamped ?? 0.1
            delays.append(max(0.03, min(0.5, delay)))
        }
        return delays
    }

    static func isAnimated(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gif"
    }
}
