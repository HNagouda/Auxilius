import CoreImage
import CoreImage.CIFilterBuiltins

/// A small grayscale copy of the page, sharp enough that a pen stroke still shows.
struct Thumbnail {
    static let width = 360
    static let height = 480
    // How far a pixel must move, after removing overall brightness, to count as changed.
    private static let pixelThreshold = 40

    let pixels: [UInt8]
    let mean: Int

    init(_ page: CIImage, context: CIContext) {
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = page
        scale.scale = Float(CGFloat(Self.height) / page.extent.height)
        scale.aspectRatio = Float((CGFloat(Self.width) / page.extent.width) / (CGFloat(Self.height) / page.extent.height))

        // Rendered as sRGB and reduced to luma here: rendering straight to a gray format washes colours out to white.
        var rgba = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        if let image = scale.outputImage {
            context.render(
                image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)),
                toBitmap: &rgba,
                rowBytes: Self.width * 4,
                bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
        }

        // Rec. 709 luma weights, scaled to 256.
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height)
        for index in pixels.indices {
            let red = Int(rgba[index * 4]), green = Int(rgba[index * 4 + 1]), blue = Int(rgba[index * 4 + 2])
            pixels[index] = UInt8((red * 54 + green * 183 + blue * 19) >> 8)
        }

        self.init(pixels: pixels)
    }

    init(pixels: [UInt8]) {
        self.pixels = pixels
        mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
    }

    /// Fraction of pixels that differ, ignoring a change in overall exposure.
    func changedFraction(from other: Thumbnail) -> Double {
        var changed = 0
        for index in pixels.indices {
            let difference = (Int(pixels[index]) - mean) - (Int(other.pixels[index]) - other.mean)
            if abs(difference) > Self.pixelThreshold {
                changed += 1
            }
        }
        return Double(changed) / Double(pixels.count)
    }
}

/// Decides when the page has new writing on it and has stopped moving long enough to read.
struct ChangeDetector {
    // A hand or pen in motion between two looks, 0.2 s apart.
    private static let motionFraction = 0.002
    // About 10 thumbnail pixels: half a small handwritten character. Averaged noise stays near 0.001%.
    private static let newInkFraction = 0.00006
    private static let settleDelay: TimeInterval = 1.2
    // Each look's weight in the running average: about the last second of looks counts.
    private static let averageWeight: Float = 0.25

    private(set) var isMoving = false
    private var previous: Thumbnail?
    private var committed: Thumbnail?
    private var stillSince: TimeInterval = 0
    // A running average of recent looks, so sensor noise cancels out before comparing.
    private var average: [Float] = []

    /// True when the page has settled with new ink since the last page that was read.
    mutating func update(_ thumbnail: Thumbnail, at time: TimeInterval) -> Bool {
        defer { previous = thumbnail }

        // The first look also restarts the clock, so exposure can settle before anything is read.
        if previous.map({ thumbnail.changedFraction(from: $0) > Self.motionFraction }) ?? true {
            stillSince = time
            average = []
        }
        blend(thumbnail)
        isMoving = time - stillSince < Self.settleDelay
        guard !isMoving else { return false }

        let settled = Thumbnail(pixels: average.map { UInt8($0.rounded()) })
        if let committed, settled.changedFraction(from: committed) <= Self.newInkFraction {
            return false
        }
        committed = settled
        return true
    }

    private mutating func blend(_ thumbnail: Thumbnail) {
        guard !average.isEmpty else {
            average = thumbnail.pixels.map(Float.init)
            return
        }
        for index in average.indices {
            average[index] += Self.averageWeight * (Float(thumbnail.pixels[index]) - average[index])
        }
    }
}
