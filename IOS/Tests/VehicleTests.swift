import XCTest
@testable import NIBMOneDomain

final class VehicleTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-30T04:00:00Z")!
    private func validate(outward: String = "2026-10-30T03:00:00Z", inward: String = "2026-10-30T11:30:00Z", supervisor: UUID? = UUID(), cost: String = "CC-10") throws {
        try VehicleRules.validate(costCode: cost, supervisorID: supervisor, place: "Colombo", duty: "Official meeting", date: now,
            outward: ISO8601DateFormatter().date(from: outward)!, inward: ISO8601DateFormatter().date(from: inward)!, now: now)
    }
    func testRequestRequiresSupervisorAndIncreasingSameDayTimes() throws {
        try validate()
        XCTAssertThrowsError(try validate(supervisor: nil))
        XCTAssertThrowsError(try validate(cost: " \n "))
        XCTAssertThrowsError(try validate(inward: "2026-10-30T03:00:00Z"))
        XCTAssertThrowsError(try validate(outward: "2026-10-30T17:30:00Z", inward: "2026-10-30T19:30:00Z"))
    }
    func testVehicleDatesAndTimesUseSriLankaCalendarDay() {
        let midnight = ISO8601DateFormatter().date(from: "2026-10-30T18:45:00Z")!
        XCTAssertEqual(VehicleRules.dateKey(midnight), "2026-10-31")
        XCTAssertEqual(VehicleRules.timeKey(midnight), "00:15")
    }
    func testPausedAndOldPositionsAreNeverLive() {
        let point = Coordinate(latitude: 6.9, longitude: 79.8)
        XCTAssertTrue(VehicleLocation(coordinate: point, accuracy: 10, capturedAt: now, receivedAt: now, isSharing: true).isFresh(at: now))
        XCTAssertFalse(VehicleLocation(coordinate: point, accuracy: 10, capturedAt: now, receivedAt: now, isSharing: false).isFresh(at: now))
        XCTAssertFalse(VehicleLocation(coordinate: point, accuracy: 10, capturedAt: now.addingTimeInterval(-91), receivedAt: now, isSharing: true).isFresh(at: now))
    }
    func testActiveAndCompletedTripsCannotBeCancelled() {
        XCTAssertTrue(VehicleRequestStatus.assigned.canCancel)
        XCTAssertFalse(VehicleRequestStatus.inProgress.canCancel)
        XCTAssertFalse(VehicleRequestStatus.completed.canCancel)
    }
}
