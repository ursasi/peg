import AppKit
import Vision

/// Text recognition through Vision. Runs off the main thread; the app never
/// touches the network.
enum OCREngine {
    static let languages = ["zh-Hans", "en-US"]

    static func recognize(_ image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: recognizeSync(image))
            }
        }
    }

    /// Synchronous entry point, also used by the headless self test.
    static func recognizeSync(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("Peg OCR failed: \(error.localizedDescription)")
            return nil
        }

        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
