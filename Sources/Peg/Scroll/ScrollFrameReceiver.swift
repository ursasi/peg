import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

/// Turns stream buffers into images off the main thread.
final class ScrollFrameReceiver: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "com.zhangshuohua.peg.scroll-frames", qos: .userInteractive)
    private let onImage: (CGImage, Double) -> Void

    init(onImage: @escaping (CGImage, Double) -> Void) {
        self.onImage = onImage
        super.init()
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        // The stream also delivers idle, blank and started frames; stitching
        // those would poison the join.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw),
              status == .complete
        else { return }

        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return }
        // ScreenCaptureKit can deliver frames out of order; the presentation
        // timestamp is what lets the stitcher drop the stale ones.
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = time.isValid ? CMTimeGetSeconds(time) : 0
        let handler = onImage
        DispatchQueue.main.async { handler(image, seconds) }
    }
}
