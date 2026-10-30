import XCTest
@testable import NIBMOneDomain

final class AttendanceCalendarTests: XCTestCase {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private func punch(_ value: String, direction: PunchDirection = .unknown) -> Punch {
        Punch(timestamp: date(value), direction: direction, machine: "T900", branch: "Colombo")
    }
    func testFirstAndLastPunchPolicyDoesNotNeedUnconfirmedDirectionCodes() {
        let rows = [punch("2026-10-01T11:30:00Z"), punch("2026-10-01T03:00:00Z"), punch("2026-10-01T07:00:00Z")]
        let summary = AttendanceCalendarRules.summary(for: rows)
        XCTAssertEqual(summary.firstIn, date("2026-10-01T03:00:00Z"))
        XCTAssertEqual(summary.lastOut, date("2026-10-01T11:30:00Z"))
        XCTAssertEqual(summary.workedMinutes, 510)
        XCTAssertFalse(summary.missingPunch)
        XCTAssertEqual(AttendanceCalendarRules.time(summary.firstIn), "08:30")
        XCTAssertEqual(AttendanceCalendarRules.time(summary.lastOut), "17:00")
    }
    func testOneDistinctPunchLeavesOutPending() {
        let value = punch("2026-10-01T03:00:00Z")
        for rows in [[value], [value, value]] {
            let summary = AttendanceCalendarRules.summary(for: rows)
            XCTAssertTrue(summary.missingPunch); XCTAssertNil(summary.lastOut); XCTAssertEqual(summary.workedMinutes, 0)
        }
        XCTAssertFalse(AttendanceCalendarRules.summary(for: []).missingPunch)
    }
    func testMonthGridIncludesAllDatesEvenWithNoRecordsAndMondayAlignment() {
        let october = date("2026-10-15T00:00:00Z")
        XCTAssertEqual(AttendanceCalendarRules.dates(in: october).count, 31)
        XCTAssertEqual(AttendanceCalendarRules.leadingDays(in: october), 3)
        XCTAssertEqual(AttendanceCalendarRules.dates(in: date("2024-02-10T00:00:00Z")).count, 29)
        XCTAssertEqual(AttendanceCalendarRules.leadingDays(in: date("2026-06-15T00:00:00Z")), 0)
        XCTAssertEqual(AttendanceCalendarRules.monthKey(date("2026-10-31T20:00:00Z")), "2026-11")
    }
    func testDayGroupingUsesColomboAndDoesNotInventAbsence() {
        let rows = [punch("2026-10-01T18:29:00Z"), punch("2026-10-01T18:31:00Z")]
        let days = AttendanceCalendarRules.days(punches: rows, month: date("2026-10-15T00:00:00Z"))
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.map { AttendanceCalendarRules.calendar.component(.day, from: $0.date) }, [1, 2])
        XCTAssertTrue(days.allSatisfy { $0.status == .missingPunch })
        XCTAssertTrue(AttendanceCalendarRules.days(punches: [], month: Date()).isEmpty)
    }
    func testApprovedLeaveAppearsButPendingAndRejectedLeaveDoNot() {
        let day = date("2026-10-05T03:00:00Z")
        let approved = LeaveRequest(type: .annual, startDate: day, endDate: day, days: 1, reason: "Family", status: .approved)
        var pending = approved; pending.status = .pending
        XCTAssertEqual(AttendanceCalendarRules.days(punches: [], leaves: [approved], month: day).first?.status, .leave)
        XCTAssertTrue(AttendanceCalendarRules.days(punches: [], leaves: [pending], month: day).isEmpty)
    }
}
