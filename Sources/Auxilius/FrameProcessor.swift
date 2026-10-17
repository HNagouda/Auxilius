import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum FrameEvent {
    case preview(CGImage)
    case writing(Bool)
    // `foundPage` is false when no sheet was detected and the whole frame was used instead.
    case newPage(CGImage, jpeg: Data, foundPage: Bool)
}

/// Turns camera frames into a live page preview and a new page each time the writing settles.
/// Lives on the capture queue; every event is emitted there too.
final class FrameProcessor {
    private static let detectionInterval: TimeInterval = 0.25
    private static let previewInterval: TimeInterval = 1.0 / 15
    private static let analysisInterval: TimeInterval = 0.2
    private static let previewSide: CGFloat = 1400
    // Large enough for small subscripts to stay legible to the model, small enough to upload quickly.
    private static let pageSide: CGFloat = 1800
    private static let jpegQuality = 0.82

    private let onEvent: (FrameEvent) -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var tracker = PageTracker()
    private var detector = ChangeDetector()
    private var lastDetection = -TimeInterval.infinity
    private var lastPreview = -TimeInterval.infinity
    private var lastAnalysis = -TimeInterval.infinity

    init(onEvent: @escaping (FrameEvent) -> Void) {
        self.onEvent = onEvent
    }

    func process(_ buffer: CVPixelBuffer, at time: TimeInterval) {
        if time - lastDetection >= Self.detectionInterval {
            lastDetection = time
            tracker.update(detected: PageDetector.detect(in: buffer), at: time)
        }

        let frame = CIImage(cvPixelBuffer: buffer)
        let page = tracker.quad.map { rectified(frame, to: $0) } ?? frame

        if time - lastPreview >= Self.previewInterval, let preview = render(page, longestSide: Self.previewSide) {
            lastPreview = time
            onEvent(.preview(preview))
        }

        if time - lastAnalysis >= Self.analysisInterval {
            lastAnalysis = time
            analyze(page, at: time)
        }
    }

    private func analyze(_ page: CIImage, at time: TimeInterval) {
        let wasMoving = detector.isMoving
        let isNewPage = detector.update(Thumbnail(page, context: context), at: time)
        if detector.isMoving != wasMoving {
            onEvent(.writing(detector.isMoving))
        }
        guard isNewPage, let image = render(page, longestSide: Self.pageSide), let jpeg = jpegData(image) else { return }

        onEvent(.newPage(image, jpeg: jpeg, foundPage: tracker.quad != nil))
    }

    private func render(_ image: CIImage, longestSide: CGFloat) -> CGImage? {
        let scale = min(1, longestSide / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent.integral)
    }

    private func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }

        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
