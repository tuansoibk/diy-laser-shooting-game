import Foundation

// MARK: - Response types

struct ShotResult: Decodable {
    let detected: Bool
    let multipleDots: Bool
    let score: Int?
    let x: Double?
    let y: Double?
    let distancePx: Double?
    let shotId: Int?
    enum CodingKeys: String, CodingKey {
        case detected, score, x, y
        case multipleDots = "multiple_dots"
        case distancePx   = "distance_px"
        case shotId       = "shot_id"
    }
}

struct DebugContour: Decodable, Identifiable {
    let cx: Int
    let cy: Int
    let area: Double
    let circularity: Double
    let passed: Bool
    let failReason: String?
    var id: String { "\(cx)-\(cy)-\(area)" }
    enum CodingKeys: String, CodingKey {
        case cx, cy, area, circularity, passed
        case failReason = "fail_reason"
    }
}

struct DebugDetectResponse: Decodable {
    let stage: String
    let arucoIds: [Int]
    let contours: [DebugContour]
    let result: ShotResult?
    let debugImage: String?   // base64 JPEG
    enum CodingKeys: String, CodingKey {
        case stage, contours, result
        case arucoIds  = "aruco_ids"
        case debugImage = "debug_image"
    }
}

// MARK: - Client

class APIClient {
    var baseURL: String

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 3
        cfg.timeoutIntervalForResource = 3
        return URLSession(configuration: cfg)
    }()

    init(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
    }

    /// POST /detect — auto-discovers the current active round on the backend.
    func detectShot(jpeg: Data, hintX: Double? = nil, hintY: Double? = nil) async throws -> ShotResult {
        let boundary = UUID().uuidString
        var body = Data()

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"frame\"; filename=\"frame.jpg\"\r\n")
        body.append("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        body.append("\r\n")

        if let x = hintX, let y = hintY {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"hint_x\"\r\n\r\n")
            body.append("\(x)\r\n")
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"hint_y\"\r\n\r\n")
            body.append("\(y)\r\n")
        }

        body.append("--\(boundary)--\r\n")

        guard let url = URL(string: "\(baseURL)/detect") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, resp) = try await APIClient.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ShotResult.self, from: data)
    }

    /// POST /debug/detect — full pipeline diagnostics without persisting a shot.
    func debugDetect(jpeg: Data) async throws -> DebugDetectResponse {
        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"frame\"; filename=\"frame.jpg\"\r\n")
        body.append("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n")

        guard let url = URL(string: "\(baseURL)/debug/detect") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, resp) = try await APIClient.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(DebugDetectResponse.self, from: data)
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
