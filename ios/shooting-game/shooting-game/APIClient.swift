import Foundation

// MARK: - Response types

struct GameResponse: Decodable {
    let id: Int
    let playerName: String
    enum CodingKeys: String, CodingKey {
        case id
        case playerName = "player_name"
    }
}

struct RoundResponse: Decodable {
    let id: Int
    let roundNumber: Int
    enum CodingKeys: String, CodingKey {
        case id
        case roundNumber = "round_number"
    }
}

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

// MARK: - Client

class APIClient {
    var baseURL: String   // e.g. "http://192.168.1.10:8000"

    init(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
    }

    // MARK: Games

    func createGame(playerName: String) async throws -> GameResponse {
        let body = try JSONEncoder().encode(["player_name": playerName])
        return try await post(path: "/games", body: body)
    }

    // MARK: Rounds

    func createRound(gameId: Int) async throws -> RoundResponse {
        return try await post(path: "/games/\(gameId)/rounds", body: nil)
    }

    func endRound(roundId: Int) async throws {
        _ = try await raw(method: "PATCH", path: "/rounds/\(roundId)/end", body: nil)
    }

    // MARK: Shot detection

    func detectShot(roundId: Int, jpeg: Data) async throws -> ShotResult {
        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"frame\"; filename=\"frame.jpg\"\r\n")
        body.append("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n")

        guard let url = URL(string: "\(baseURL)/rounds/\(roundId)/detect") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(ShotResult.self, from: data)
    }

    // MARK: Helpers

    private func post<T: Decodable>(path: String, body: Data?) async throws -> T {
        let data = try await raw(method: "POST", path: path, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func raw(method: String, path: String, body: Data?) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
