import AVFoundation

class CameraManager: NSObject {
    let session = AVCaptureSession()

    private let videoOutput = AVCaptureVideoDataOutput()
    // Serial queue — isArmed flag and frame processing both run here, so no lock needed
    let processingQueue = DispatchQueue(label: "camera.processing", qos: .userInteractive)
    // Separate queue for session start/stop so it never blocks processingQueue
    private let sessionQueue = DispatchQueue(label: "camera.session")

    var onFrame: ((CVPixelBuffer) -> Void)?
    // One-shot capture: set before the next frame arrives, cleared immediately after.
    private var pendingCapture: ((CVPixelBuffer) -> Void)?

    override init() {
        super.init()
        configure()
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        guard
            let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }

        session.addInput(input)

        // Pick a 4:3 format (full sensor, matching Camera app photo mode) at
        // ~720p–1080p width that supports 30 fps. 16:9 formats crop the sensor
        // top/bottom, making the view appear more zoomed in than photo mode.
        let target = device.formats.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let w = Int(d.width), h = Int(d.height)
            guard w > h, w >= 1280, w <= 1920 else { return false }
            let ratio = Double(w) / Double(h)
            let is4by3 = abs(ratio - 4.0 / 3.0) < 0.05
            let supports30fps = $0.videoSupportedFrameRateRanges
                .contains { $0.maxFrameRate >= 30 }
            return is4by3 && supports30fps
        }.max(by: { $0.videoFieldOfView < $1.videoFieldOfView })

        try? device.lockForConfiguration()
        if let fmt = target { device.activeFormat = fmt }
        device.videoZoomFactor = 1.0
        device.unlockForConfiguration()

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // Rotate frames to portrait so pixel coords match screen orientation
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        session.commitConfiguration()
    }

    /// Deliver the very next camera frame to `completion` (called on processingQueue).
    func captureFrame(completion: @escaping (CVPixelBuffer) -> Void) {
        processingQueue.async { self.pendingCapture = completion }
    }

    func start() {
        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    // Lock exposure and white balance on the current scene.
    // Call this once the board is framed — prevents auto-exposure from washing out the laser dot.
    func lockExposure() {
        guard let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else { return }
        try? device.lockForConfiguration()
        if device.isExposureModeSupported(.custom) {
            let iso = device.iso.clamped(to: device.activeFormat.minISO...device.activeFormat.maxISO)
            device.setExposureModeCustom(duration: device.exposureDuration, iso: iso, completionHandler: nil)
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }
        device.unlockForConfiguration()
    }

    // Restore auto-exposure and auto white balance so the camera re-adjusts to a new scene.
    func unlockExposure() {
        guard let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else { return }
        try? device.lockForConfiguration()
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        device.unlockForConfiguration()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let capture = pendingCapture {
            pendingCapture = nil
            capture(pixelBuffer)
        }
        onFrame?(pixelBuffer)
    }
}
