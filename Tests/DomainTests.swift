import XCTest
@testable import NIBMOneDomain

final class DomainTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func date(_ day: Int, hour: Int = 0, minute: Int = 0, month: Int = 10, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    private func request(status: RequestStatus = .pending, days: Double = 2, year: Int = 2026) -> LeaveRequest {
        LeaveRequest(type: .annual, startDate: date(29, year: year), endDate: date(30, year: year), days: days, reason: "Family", status: status)
    }
    private func validate(start: Date? = nil, end: Date? = nil, halfDay: Bool = false, reason: String = "Family",
                          balance: Double = 14, requests: [LeaveRequest] = []) throws -> Double {
        try LeaveRules.validate(start: start ?? date(29), end: end ?? date(30), halfDay: halfDay,
                                reason: reason, balance: balance, requests: requests, today: date(29), calendar: calendar)
    }
    private func punch(_ hour: Int, _ direction: PunchDirection, minute: Int = 0) -> Punch {
        Punch(timestamp: date(29, hour: hour, minute: minute), direction: direction, machine: "Gate 01", branch: "Colombo")
    }
    private func ticket(number: String = "NIBM-1043") -> Ticket {
        Ticket(number: number, title: "Broken projector", description: "No image on screen", category: "Projector",
               room: "B204", assetID: "PROJ-B204", priority: "High", coordinate: .campus,
               photo: Attachment(name: "photo.jpg", data: Data([1, 2, 3])),
               comments: [TicketComment(author: "Alex", text: "Please check")])
    }

    func testFullDaysIncludeBothEndpoints() throws { XCTAssertEqual(try validate(), 2) }
    func testHalfDayUsesOneDate() throws { XCTAssertEqual(try validate(end: date(29), halfDay: true), 0.5) }
    func testReversedDatesAreRejected() { XCTAssertThrowsError(try validate(start: date(30), end: date(29))) }
    func testHalfDayRangeIsRejected() { XCTAssertThrowsError(try validate(halfDay: true)) }
    func testPastDatesAreRejected() { XCTAssertThrowsError(try validate(start: date(28))) }
    func testWhitespaceReasonIsRejected() { XCTAssertThrowsError(try validate(reason: " \n ")) }
    func testInsufficientBalanceIsRejected() { XCTAssertThrowsError(try validate(balance: 1)) }
    func testYearBoundaryRequiresSeparateRequests() {
        XCTAssertThrowsError(try validate(start: date(31, month: 12), end: date(1, month: 1, year: 2027)))
    }
    func testPendingAndApprovedOverlapAreRejected() {
        for status in [RequestStatus.pending, .approved] {
            XCTAssertThrowsError(try validate(start: date(30), end: date(31), requests: [request(status: status)]))
        }
    }
    func testRejectedRequestAllowsResubmission() throws {
        XCTAssertEqual(try validate(requests: [request(status: .rejected)]), 2)
    }
    func testAdjacentNonoverlappingDatesAreAllowed() throws {
        XCTAssertEqual(try validate(start: date(31), end: date(31), requests: [request()]), 1)
    }
    func testBalanceReservesPendingButExcludesRejectedAndOtherYears() {
        let requests = [request(), request(status: .approved, days: 3), request(status: .rejected, days: 4), request(year: 2025)]
        XCTAssertEqual(LeaveRules.availableBalance(for: .annual, requests: requests, year: 2026, calendar: calendar), 9)
        XCTAssertEqual(LeaveRules.availableBalance(for: .medical, requests: requests, year: 2026, calendar: calendar), 7)
    }
    func testCalendarDaysAcrossDaylightSaving() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: "America/New_York")!
        let start = local.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        let end = local.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        XCTAssertEqual(try LeaveRules.requestedDays(from: start, to: end, halfDay: false, calendar: local), 3)
    }
    func testPairedPunchesExcludeBreaksAndSortRecords() {
        let punches = [punch(17, .outbound), punch(8, .inbound), punch(13, .inbound), punch(12, .outbound)]
        let summary = AttendanceRules.summary(for: punches)
        XCTAssertEqual(summary.workedMinutes, 480)
        XCTAssertFalse(summary.missingPunch)
        XCTAssertEqual(summary.firstIn, date(29, hour: 8))
        XCTAssertEqual(summary.lastOut, date(29, hour: 17))
    }
    func testUnmatchedInDoesNotInventHours() {
        let summary = AttendanceRules.summary(for: [punch(8, .inbound)])
        XCTAssertEqual(summary.workedMinutes, 0); XCTAssertTrue(summary.missingPunch); XCTAssertNil(summary.lastOut)
    }
    func testOrphanOutAndDuplicateInRequireReview() {
        XCTAssertTrue(AttendanceRules.summary(for: [punch(9, .outbound)]).missingPunch)
        let summary = AttendanceRules.summary(for: [punch(8, .inbound), punch(9, .inbound), punch(17, .outbound)])
        XCTAssertTrue(summary.missingPunch); XCTAssertEqual(summary.workedMinutes, 540)
    }
    func testEmptyPunchListIsSafe() {
        let summary = AttendanceRules.summary(for: [])
        XCTAssertEqual(summary.workedMinutes, 0); XCTAssertFalse(summary.missingPunch); XCTAssertNil(summary.firstIn)
    }
    func testAssetLookupNormalisesCodeAndRejectsUnknownCode() {
        XCTAssertEqual(Asset.identify("  ac-305-01\n")?.room, "Room 305")
        XCTAssertNil(Asset.identify("unknown")); XCTAssertNil(Asset.identify("https://untrusted.example/AC-305-01"))
    }
    func testTicketNumbersUseMaximumRatherThanListLength() {
        XCTAssertEqual(TicketRules.nextNumber(tickets: [ticket(number: "NIBM-1050"), ticket(number: "NIBM-1043")]), "NIBM-1051")
        XCTAssertEqual(TicketRules.nextNumber(tickets: []), "NIBM-1043")
    }
    func testTicketRequiredFieldsAreValidated() {
        XCTAssertThrowsError(try TicketRules.validate(title: " ", description: "Fault", room: "A103"))
        XCTAssertThrowsError(try TicketRules.validate(title: "Fault", description: "\n", room: "A103"))
        XCTAssertThrowsError(try TicketRules.validate(title: "Fault", description: "Fault", room: " "))
        XCTAssertNoThrow(try TicketRules.validate(title: "Fault", description: "Fault", room: "A103"))
    }
    func testSavedStateRoundTripKeepsRelationshipsAndAttachments() throws {
        var leave = request(status: .rejected)
        leave.rejectionReason = "Insufficient cover"
        leave.attachment = Attachment(name: "note.pdf", data: Data([4, 5, 6]))
        let ticket = ticket()
        let notices = [AppNotice(title: "Leave", destination: .leave(leave.id)), AppNotice(title: "Ticket", destination: .ticket(ticket.id)), AppNotice(title: "Punch", destination: .attendance)]
        let state = SavedState(leaveRequests: [leave], tickets: [ticket], notices: notices)
        let decoded = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.leaveRequests[0].id, leave.id)
        XCTAssertEqual(decoded.leaveRequests[0].attachment?.data, Data([4, 5, 6]))
        XCTAssertEqual(decoded.leaveRequests[0].rejectionReason, "Insufficient cover")
        XCTAssertEqual(decoded.tickets[0].description, "No image on screen")
        XCTAssertEqual(decoded.tickets[0].photo?.data, Data([1, 2, 3]))
        XCTAssertEqual(decoded.tickets[0].comments[0].text, "Please check")
        XCTAssertEqual(decoded.tickets[0].events.first?.status, .open)
        XCTAssertEqual(decoded.tickets[0].coordinate, .campus)
        if case .ticket(let id) = decoded.notices[1].destination { XCTAssertEqual(id, ticket.id) } else { XCTFail("Lost ticket route") }
    }
}
