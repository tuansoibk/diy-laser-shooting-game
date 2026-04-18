import CoreVideo
import CoreGraphics

struct DotDetectionResult {
    /// Dot centroid in original pixel coordinates
    let center: CGPoint
    /// Normalised 0–1 coordinates (0.5, 0.5 = frame centre)
    let normalizedCenter: CGPoint
    /// Number of qualifying red pixels in this blob
    let clusterSize: Int
}

class RedDotDetector {
    // --- Tunable thresholds ---
    var minRedValue: Float = 160
    var minRedDominance: Float = 100
    var minClusterSize: Int = 20
    var maxClusterSize: Int = 5000
    /// Max distance (px) between a red pixel and a cluster centroid to be considered the same blob.
    /// Wider radius merges nearby lens-flare streaks into the main dot cluster.
    var clusterMergeRadius: Int = 70

    private let stride = 2

    /// Returns one result per detected red blob, sorted largest first.
    func detect(in pixelBuffer: CVPixelBuffer) -> [DotDetectionResult] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width       = CVPixelBufferGetWidth(pixelBuffer)
        let height      = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        let buf = base.assumingMemoryBound(to: UInt8.self)

        // Each cluster tracks its running sum and current centroid for fast nearest-cluster search.
        struct Cluster { var sumX, sumY, count, cx, cy: Int }
        var clusters: [Cluster] = []
        let mergeR2 = clusterMergeRadius * clusterMergeRadius

        // Pixel format is BGRA — byte order: [B, G, R, A]
        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let offset = y * bytesPerRow + x * 4
                let b = Float(buf[offset])
                let g = Float(buf[offset + 1])
                let r = Float(buf[offset + 2])

                guard r >= minRedValue,
                      r - g >= minRedDominance,
                      r - b >= minRedDominance else { continue }

                // Assign to nearest cluster within mergeRadius, or start a new one
                var bestIdx = -1
                var bestDist = mergeR2
                for i in clusters.indices {
                    let dx = x - clusters[i].cx
                    let dy = y - clusters[i].cy
                    let d2 = dx*dx + dy*dy
                    if d2 < bestDist { bestDist = d2; bestIdx = i }
                }

                if bestIdx >= 0 {
                    clusters[bestIdx].sumX += x
                    clusters[bestIdx].sumY += y
                    clusters[bestIdx].count += 1
                    clusters[bestIdx].cx = clusters[bestIdx].sumX / clusters[bestIdx].count
                    clusters[bestIdx].cy = clusters[bestIdx].sumY / clusters[bestIdx].count
                } else {
                    clusters.append(Cluster(sumX: x, sumY: y, count: 1, cx: x, cy: y))
                }
            }
        }

        return clusters
            .filter { $0.count >= minClusterSize && $0.count <= maxClusterSize }
            .sorted { $0.count > $1.count }
            .map { c in
                let cx = Double(c.sumX) / Double(c.count)
                let cy = Double(c.sumY) / Double(c.count)
                return DotDetectionResult(
                    center: CGPoint(x: cx, y: cy),
                    normalizedCenter: CGPoint(x: cx / Double(width), y: cy / Double(height)),
                    clusterSize: c.count
                )
            }
    }
}
