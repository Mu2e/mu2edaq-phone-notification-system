import SwiftUI

enum Severity: String, CaseIterable, Codable, Comparable {
    case debug, info, warning, error, critical

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 1 }
    static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rank < rhs.rank
    }

    var color: Color {
        switch self {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .critical: return .purple
        }
    }

    var symbol: String {
        switch self {
        case .debug: return "ladybug"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .critical: return "bolt.trianglebadge.exclamationmark"
        }
    }
}

struct NotifyEvent: Identifiable, Codable, Equatable {
    let id: Int
    let source: String
    let host: String
    let severity: String
    let title: String
    let message: String
    let timestamp: String
    let receivedAt: String
    let meta: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, source, host, severity, title, message, timestamp, meta
        case receivedAt = "received_at"
    }

    var sev: Severity { Severity(rawValue: severity) ?? .info }
}

struct EventListResponse: Codable {
    let events: [NotifyEvent]
}

struct HealthResponse: Codable {
    let apnsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case apnsEnabled = "apns_enabled"
    }
}

/// Payload of the enrollment QR code shown by the server's web UI.
struct EnrollmentConfig: Codable {
    let type: String
    let serverUrl: String
    let enrollmentToken: String

    enum CodingKeys: String, CodingKey {
        case type
        case serverUrl = "server_url"
        case enrollmentToken = "enrollment_token"
    }

    static func parse(_ text: String) -> EnrollmentConfig? {
        guard let data = text.data(using: .utf8),
              let cfg = try? JSONDecoder().decode(EnrollmentConfig.self,
                                                  from: data),
              cfg.type == "mu2edaq-notify-config" else { return nil }
        return cfg
    }
}

struct RegistrationResponse: Codable {
    let deviceToken: String
    let serverUrl: String

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case serverUrl = "server_url"
    }
}
