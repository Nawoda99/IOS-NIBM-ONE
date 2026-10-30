import XCTest
@testable import NIBMOneDomain

final class WidgetSummaryTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func summary(at value: String) -> WidgetSummary {
        WidgetSummary(updatedAt: date(value), isDemo: false, firstIn: "08:30", lastOut: "17:30", pendingLeave: 2, openTickets: 3)
    }
    func testSummaryExpiresAtEightHours() {
        let value = summary(at: "2026-10-30T02:30:00Z")
        XCTAssertTrue(value.isCurrent(at: date("2026-10-30T10:29:59Z")))
        XCTAssertFalse(value.isCurrent(at: date("2026-10-30T10:30:00Z")))
        XCTAssertFalse(value.isCurrent(at: date("2026-10-30T02:29:59Z")))
    }
    func testSummaryExpiresAtSriLankanMidnight() {
        let value = summary(at: "2026-10-30T17:00:00Z")
        XCTAssertTrue(value.isCurrent(at: date("2026-10-30T18:29:59Z")))
        XCTAssertFalse(value.isCurrent(at: date("2026-10-30T18:30:00Z")))
    }
    func testSummaryRoundTripContainsOnlyDisplayData() throws {
        let value = summary(at: "2026-10-30T02:30:00Z")
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSummary.self, from: data), value)
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        XCTAssertEqual(keys, ["updatedAt", "isDemo", "firstIn", "lastOut", "pendingLeave", "openTickets"])
    }
}
