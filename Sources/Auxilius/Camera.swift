@preconcurrency import AVFoundation

/// Runs the capture session and hands every frame to `onFrame` on the capture queue.
/// Unchecked Sendable: the session and its configuration are only touched on `queue`.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    // Desk View streams are 1920x1440; anything larger only costs processing time.
    private static let maxFormatWidth: Int32 = 2560

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "auxilius.camera", qos: .userInitiated)
    private let onFrame: (CVPixelBuffer, TimeInterval) -> Void

    init(onFrame: @escaping (CVPixelBuffer, TimeInterval) -> Void) {
        self.onFrame = onFrame
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Desk View cameras first, because they already look down at the desk.
    static func availableDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.deskViewCamera, .continuityCamera, .builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let deskView = discovery.devices.filter { $0.deviceType == .deskViewCamera }
        let others = discovery.devices.filter { $0.deviceType != .deskViewCamera }
        return deskView + others
    }

    func start(_ device: AVCaptureDevice) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try configure(device)
                    if !session.isRunning {
                        session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            session.stopRunning()
        }
    }

    private func configure(_ device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotUse(device.localizedName)
        }
        session.addInput(input)
        if session.outputs.isEmpty {
            session.addOutput(output)
        }
        try selectLargestFormat(of: device)
    }

    private func selectLargestFormat(of device: AVCaptureDevice) throws {
        let candidates = device.formats.filter { $0.formatDescription.dimensions.width <= Self.maxFormatWidth }
        let largest = candidates.max { pixelCount($0) < pixelCount($1) }
        guard let largest, largest != device.activeFormat else { return }

        try device.lockForConfiguration()
        device.activeFormat = largest
        device.unlockForConfiguration()
    }

    private func pixelCount(_ format: AVCaptureDevice.Format) -> Int32 {
        format.formatDescription.dimensions.width * format.formatDescription.dimensions.height
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }
}

enum CameraError: LocalizedError {
    case cannotUse(String)

    var errorDescription: String? {
        switch self {
        case .cannotUse(let name): "\(name) is in use by another app."
        }
    }
}
