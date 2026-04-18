import Vision
import CoreVideo

/// Four corners of the detected board in normalised coordinates (0–1, top-left origin).
struct BoardQuad {
    let topLeft:     CGPoint
    let topRight:    CGPoint
    let bottomRight: CGPoint
    let bottomLeft:  CGPoint

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    func contains(_ point: CGPoint) -> Bool {
        let path = CGMutablePath()
        path.move(to: topLeft)
        path.addLine(to: topRight)
        path.addLine(to: bottomRight)
        path.addLine(to: bottomLeft)
        path.closeSubpath()
        return path.contains(point)
    }
}

class BoardDetector {
    /// Call once at startup on a background thread to force Vision to load its
    /// rectangle-detection model. Without this the first real detect() call blocks
    /// for several seconds while the model initialises.
    func warmUp() {
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buf)
        guard let dummy = buf else { return }
        _ = detect(in: dummy)
    }

    func detect(in pixelBuffer: CVPixelBuffer) -> BoardQuad? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio  = 0.4
        request.maximumAspectRatio  = 2.5
        request.minimumSize         = 0.2
        request.maximumObservations = 1
        request.minimumConfidence   = 0.6

        // Pixel buffer is portrait-rotated — pass .up so Vision coordinates
        // align with the same top-left origin used by RedDotDetector.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])

        guard let obs = request.results?.first else { return nil }

        // Vision uses bottom-left origin; flip Y for top-left origin (UIKit / our normalised space).
        return BoardQuad(
            topLeft:     CGPoint(x: obs.topLeft.x,     y: 1 - obs.topLeft.y),
            topRight:    CGPoint(x: obs.topRight.x,    y: 1 - obs.topRight.y),
            bottomRight: CGPoint(x: obs.bottomRight.x, y: 1 - obs.bottomRight.y),
            bottomLeft:  CGPoint(x: obs.bottomLeft.x,  y: 1 - obs.bottomLeft.y)
        )
    }
}
