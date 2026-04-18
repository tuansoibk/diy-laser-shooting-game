import CoreVideo
import CoreGraphics

struct DotDetectionResult {
    /// Dot centroid in original pixel coordinates (post-portrait-rotation frame)
    let center: CGPoint
    /// Normalised 0–1 coordinates (0.5, 0.5 = frame centre)
    let normalizedCenter: CGPoint
    /// Number of qualifying red pixels found (useful for threshold tuning)
    let clusterSize: Int
}

class RedDotDetector {
    // --- Tunable thresholds ---
    // Raise minRedValue / minRedDominance if you get false positives on non-laser reds.
    // Lower them if the dot isn't being picked up.
    var minRedValue: Float = 150       // R channel must be at least this bright
    var minRedDominance: Float = 80    // R must exceed both G and B by at least this much
    var minClusterSize: Int = 20       // too few pixels → noise, ignore
    var maxClusterSize: Int = 5000     // too many pixels → large red object, not a dot

    // Scan every Nth pixel row and column for speed (2 = quarter the pixels, still fine resolution)
    private let stride = 2

    func detect(in pixelBuffer: CVPixelBuffer) -> DotDetectionResult? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let buf = base.assumingMemoryBound(to: UInt8.self)

        var sumX = 0, sumY = 0, count = 0

        // Pixel format is BGRA — byte order: [B, G, R, A]
        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let offset = y * bytesPerRow + x * 4
                let b = Float(buf[offset])
                let g = Float(buf[offset + 1])
                let r = Float(buf[offset + 2])

                if r >= minRedValue && r - g >= minRedDominance && r - b >= minRedDominance {
                    sumX += x
                    sumY += y
                    count += 1
                }
            }
        }

        guard count >= minClusterSize && count <= maxClusterSize else { return nil }

        let cx = Double(sumX) / Double(count)
        let cy = Double(sumY) / Double(count)

        return DotDetectionResult(
            center: CGPoint(x: cx, y: cy),
            normalizedCenter: CGPoint(x: cx / Double(width), y: cy / Double(height)),
            clusterSize: count
        )
    }
}
