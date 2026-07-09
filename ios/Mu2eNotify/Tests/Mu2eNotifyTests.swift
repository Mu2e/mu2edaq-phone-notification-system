import XCTest
@testable import Mu2eNotify

final class Mu2eNotifyTests: XCTestCase {

    func testEventDecoding() throws {
        let json = """
        {"events": [{"id": 7, "source": "dtc-monitor", "host": "mu2edaq09",
          "severity": "error", "title": "DTC link down",
          "message": "ROC link 3 lost lock",
          "timestamp": "2026-07-07T12:00:00+00:00",
          "received_at": "2026-07-07T12:00:01+00:00",
          "meta": {"run": "107001"}}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EventListResponse.self,
                                               from: json)
        XCTAssertEqual(decoded.events.count, 1)
        let event = decoded.events[0]
        XCTAssertEqual(event.id, 7)
        XCTAssertEqual(event.sev, .error)
        XCTAssertEqual(event.meta["run"], "107001")
    }

    func testUnknownSeverityFallsBackToInfo() throws {
        let json = """
        {"id": 1, "source": "x", "host": "h", "severity": "bogus",
         "title": "t", "message": "", "timestamp": "",
         "received_at": "", "meta": {}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(NotifyEvent.self, from: json)
        XCTAssertEqual(event.sev, .info)
    }

    func testSeverityOrdering() {
        XCTAssertTrue(Severity.warning < Severity.error)
        XCTAssertTrue(Severity.error < Severity.critical)
        XCTAssertFalse(Severity.critical < Severity.debug)
    }

    func testEnrollmentConfigParsing() {
        let good = """
        {"type":"mu2edaq-notify-config",
         "server_url":"http://mu2edaq01:8095","enrollment_token":"abc"}
        """
        let cfg = EnrollmentConfig.parse(good)
        XCTAssertEqual(cfg?.serverUrl, "http://mu2edaq01:8095")
        XCTAssertEqual(cfg?.enrollmentToken, "abc")

        XCTAssertNil(EnrollmentConfig.parse("not json"))
        XCTAssertNil(EnrollmentConfig.parse(
            "{\"type\":\"other\",\"server_url\":\"x\",\"enrollment_token\":\"y\"}"))
    }

    func testServerClientBuildsQueryURL() throws {
        let client = ServerClient(baseURL: URL(string: "https://notify.example")!,
                                  bearerToken: "token")
        let url = try client.url(
            path: "api/events",
            queryItems: [URLQueryItem(name: "limit", value: "200")])
        XCTAssertEqual(url.absoluteString,
                       "https://notify.example/api/events?limit=200")
    }

    func testHealthDecoding() throws {
        let json = #"{"status":"ok","apns_enabled":false}"#
            .data(using: .utf8)!
        let health = try JSONDecoder().decode(HealthResponse.self, from: json)
        XCTAssertFalse(health.apnsEnabled)
    }
}
