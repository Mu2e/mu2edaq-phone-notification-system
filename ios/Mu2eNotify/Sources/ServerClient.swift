import Foundation

/// Thin async client for the notification server's JSON API.
struct ServerClient {
    let baseURL: URL
    let bearerToken: String?

    enum ClientError: LocalizedError {
        case badStatus(Int, String)
        var errorDescription: String? {
            if case let .badStatus(code, body) = self {
                return "Server returned \(code): \(body)"
            }
            return nil
        }
    }

    private func request(_ path: String, method: String = "GET",
                         json: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 15
        if let token = bearerToken {
            req.setValue("Bearer \(token)",
                         forHTTPHeaderField: "Authorization")
        }
        if let json = json {
            req.setValue("application/json",
                         forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClientError.badStatus(
                status, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Register this phone with a one-time enrollment token; returns the
    /// permanent device bearer token.
    static func register(serverUrl: URL, enrollmentToken: String,
                         name: String, apnsToken: String?)
        async throws -> RegistrationResponse {
        let client = ServerClient(baseURL: serverUrl, bearerToken: nil)
        var body: [String: Any] = ["enrollment_token": enrollmentToken,
                                   "name": name]
        if let apnsToken = apnsToken { body["apns_token"] = apnsToken }
        let data = try await client.request("api/devices/register",
                                            method: "POST", json: body)
        return try JSONDecoder().decode(RegistrationResponse.self, from: data)
    }

    func fetchEvents(limit: Int = 200) async throws -> [NotifyEvent] {
        let data = try await request("api/events?limit=\(limit)")
        return try JSONDecoder().decode(EventListResponse.self,
                                        from: data).events
    }

    func updateApnsToken(_ apnsToken: String) async throws {
        _ = try await request("api/devices/token", method: "POST",
                              json: ["apns_token": apnsToken])
    }

    func updateSettings(name: String?, minSeverity: Severity?) async throws {
        var body: [String: Any] = [:]
        if let name = name { body["name"] = name }
        if let sev = minSeverity { body["min_severity"] = sev.rawValue }
        _ = try await request("api/devices/settings", method: "POST",
                              json: body)
    }
}
