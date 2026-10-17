import CoreImage
import CoreImage.CIFilterBuiltins
import OSLog
import Vision

/// The page's corners in normalized image coordinates, origin bottom-left, as Vision and Core Image use.
struct Quad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Shoelace formula, as a fraction of the frame.
    var area: CGFloat {
        let points = corners
        var sum: CGFloat = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            sum += current.x * next.y - next.x * current.y
        }
        return abs(sum) / 2
    }

    func largestCornerShift(from other: Quad) -> CGFloat {
        zip(corners, other.corners).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
    }
}

enum PageDetector {
    // Smaller than this is a sticky note or a phone, not the page being written on.
    private static let minimumArea: CGFloat = 0.12
    private static let minimumConfidence: Float = 0.5
    private static let logger = Logger(subsystem: "auxilius", category: "page")

    static func detect(in buffer: CVPixelBuffer) -> Quad? {
        let request = VNDetectDocumentSegmentationRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        } catch {
            logger.error("Page detection failed: \(error.localizedDescription)")
            return nil
        }

        guard let observation = request.results?.first, observation.confidence >= minimumConfidence else { return nil }
        let quad = Quad(
            topLeft: observation.topLeft,
            topRight: observation.topRight,
            bottomRight: observation.bottomRight,
            bottomLeft: observation.bottomLeft
        )
        return quad.area >= minimumArea ? quad : nil
    }
}

/// Holds the page outline steady, so the corrected page does not shimmer from frame to frame.
struct PageTracker {
    // Detections within 2% of the frame of the current outline are the same page sitting still.
    private static let snapDistance: CGFloat = 0.02
    // A hand over the page can hide it for a moment; only give up on it after this long.
    private static let lostAfter: TimeInterval = 2.0

    private(set) var quad: Quad?
    private var lastSeen: TimeInterval = 0

    mutating func update(detected: Quad?, at time: TimeInterval) {
        if let detected {
            if quad == nil || detected.largestCornerShift(from: quad!) > Self.snapDistance {
                quad = detected
            }
            lastSeen = time
        } else if time - lastSeen > Self.lostAfter {
            quad = nil
        }
    }
}

/// The frame warped so the page fills it, top-down and square-on, with its origin at zero.
func rectified(_ frame: CIImage, to quad: Quad) -> CIImage {
    let size = frame.extent.size
    func pixel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: frame.extent.minX + point.x * size.width, y: frame.extent.minY + point.y * size.height)
    }

    let filter = CIFilter.perspectiveCorrection()
    filter.inputImage = frame
    filter.topLeft = pixel(quad.topLeft)
    filter.topRight = pixel(quad.topRight)
    filter.bottomRight = pixel(quad.bottomRight)
    filter.bottomLeft = pixel(quad.bottomLeft)
    guard let output = filter.outputImage else { return frame }

    return output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
}
