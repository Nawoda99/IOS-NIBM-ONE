import Foundation

struct EmployeeProfileDetails: Codable {
    var firstName: String?
    var lastName: String?
    var initials: String?
    var title: String?
    var gender: String?
    var identityNumber: String?
    var passportNumber: String?
    var department: String?
    var employmentType: String?
    var grade: String?
    var employmentStatus: String?
    var previousEPFNumber: String?
    var erpEmployeeID: String?
    var joinedDate: String?
    var appointmentDate: String?
    var probationEndDate: String?
    var assignmentStartDate: String?
    var officialEmail: String?
    var personalEmail: String?
    var primaryMobile: String?
    var secondaryMobile: String?
    var primaryTelephone: String?
    var secondaryTelephone: String?
    var primaryAddress: String?
    var secondaryAddress: String?
    var emergencyContactName: String?
    var emergencyContactPhone: String?
    var emergencyContactAddress: String?
    var emergencyContactRelationship: String?

    static let demo = EmployeeProfileDetails(firstName: "Alex", lastName: "Perera", initials: "A.P.")

    static func displayDate(_ value: String?) -> String? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_LK")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return nil }
        formatter.dateFormat = "dd MMM yyyy"
        return formatter.string(from: date)
    }
}

enum EmployeeRole: String, CaseIterable, Identifiable, Codable {
    case employee = "Employee", approver = "Approver", support = "Support", administrator = "Administrator"
    var id: String { rawValue }
    var defaultPermissions: Set<String> {
        let own: Set<String> = ["attendance.view", "leave.view", "leave.apply", "tickets.view", "tickets.create", "map.view", "vehicles.request"]
        switch self {
        case .employee: return own
        case .approver: return own.union(["leave.approve", "machines.manage", "vehicles.recommend"])
        case .support: return own.union(["tickets.manage", "machines.manage"])
        case .administrator: return own.union(["leave.approve", "tickets.manage", "machines.manage", "users.manage", "roles.manage", "branches.manage", "vehicles.recommend", "vehicles.manage"])
        }
    }
}

enum AttendanceStatus: String, CaseIterable, Identifiable, Codable {
    case present = "Present", late = "Late", absent = "Absent", halfDay = "Half day"
    case missingPunch = "Missing punch", leave = "Leave", offDay = "Off day"
    case holiday = "Holiday", noPay = "No pay", noRecord = "No record"
    var id: String { rawValue }
}

enum PunchDirection: String, Codable { case inbound = "IN", outbound = "OUT", unknown = "UNKNOWN" }

struct Punch: Identifiable, Codable {
    var id = UUID()
    let timestamp: Date
    let direction: PunchDirection
    let machine: String
    let branch: String
    var time: String { AttendanceCalendarRules.time(timestamp) }
}

struct AttendanceSummary {
    let firstIn: Date?
    let lastOut: Date?
    let workedMinutes: Int
    let missingPunch: Bool
    var worked: String { "\(workedMinutes / 60)h \(workedMinutes % 60)m" }
}

enum AttendanceRules {
    /// Pair IN/OUT intervals, excluding breaks. Flag unmatched records for review.
    static func summary(for punches: [Punch]) -> AttendanceSummary {
        let sorted = punches.sorted { $0.timestamp < $1.timestamp }
        var pendingIn: Date?
        var seconds: TimeInterval = 0
        var incomplete = false
        for punch in sorted {
            switch punch.direction {
            case .inbound:
                if pendingIn != nil { incomplete = true } else { pendingIn = punch.timestamp }
            case .outbound:
                if let start = pendingIn { seconds += punch.timestamp.timeIntervalSince(start); pendingIn = nil }
                else { incomplete = true }
            case .unknown:
                incomplete = true; pendingIn = nil
            }
        }
        return AttendanceSummary(firstIn: sorted.first { $0.direction == .inbound }?.timestamp,
                                 lastOut: sorted.last { $0.direction == .outbound }?.timestamp,
                                 workedMinutes: Int(seconds / 60), missingPunch: incomplete || pendingIn != nil)
    }
}

enum AttendanceCalendarRules {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Colombo")!
        value.firstWeekday = 2
        return value
    }
    static func startOfMonth(_ date: Date) -> Date { calendar.dateInterval(of: .month, for: date)!.start }
    static func sameMonth(_ lhs: Date, _ rhs: Date) -> Bool { calendar.isDate(lhs, equalTo: rhs, toGranularity: .month) }
    static func dates(in month: Date) -> [Date] {
        let start = startOfMonth(month)
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    static func leadingDays(in month: Date) -> Int { (calendar.component(.weekday, from: startOfMonth(month)) + 5) % 7 }
    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
    static func time(_ date: Date?) -> String { date.map { format($0, "HH:mm") } ?? "--:--" }
    static func monthKey(_ date: Date) -> String { format(date, "yyyy-MM") }
    static func monthTitle(_ date: Date) -> String { format(date, "MMMM yyyy") }
    static func dayTitle(_ date: Date) -> String { format(date, "EEEE, d MMMM yyyy") }
    static func shortDate(_ date: Date) -> String { format(date, "EEE d MMM") }
    /// The employee requested first punch as IN and last distinct punch as OUT.
    /// This is an elapsed span, not paid hours or a break-deducted total.
    static func summary(for punches: [Punch]) -> AttendanceSummary {
        let times = Set(punches.map(\.timestamp)).sorted()
        let first = times.first
        let last = times.count > 1 ? times.last : nil
        let minutes = first.flatMap { start in last.map { max(0, Int($0.timeIntervalSince(start) / 60)) } } ?? 0
        return AttendanceSummary(firstIn: first, lastOut: last, workedMinutes: minutes, missingPunch: first != nil && last == nil)
    }
    static func days(punches: [Punch], leaves: [LeaveRequest] = [], month: Date) -> [AttendanceDay] {
        let grouped = Dictionary(grouping: punches.filter { sameMonth($0.timestamp, month) }, by: { calendar.startOfDay(for: $0.timestamp) })
        return dates(in: month).compactMap { date in
            if let records = grouped[date], !records.isEmpty {
                return AttendanceDay(date: date, status: summary(for: records).missingPunch ? .missingPunch : .present,
                                     punches: records.sorted { $0.timestamp < $1.timestamp })
            }
            if let leave = leaves.first(where: { $0.status == .approved && date >= calendar.startOfDay(for: $0.startDate) && date <= calendar.startOfDay(for: $0.endDate) }) {
                return AttendanceDay(date: date, status: leave.days == 0.5 ? .halfDay : .leave, punches: [])
            }
            return nil // No record does not establish absence or a non-working day.
        }
    }
}

struct AttendanceDay: Identifiable {
    var id: Date { date }
    let date: Date
    let status: AttendanceStatus
    let punches: [Punch]
    var summary: AttendanceSummary { AttendanceCalendarRules.summary(for: punches) }
    var firstIn: String { AttendanceCalendarRules.time(summary.firstIn) }
    var lastOut: String { AttendanceCalendarRules.time(summary.lastOut) }
    var worked: String { summary.lastOut == nil ? "--" : summary.worked }
}

enum LeaveType: String, CaseIterable, Identifiable, Codable {
    case annual = "Annual", casual = "Casual", medical = "Medical", special = "Special"
    var id: String { rawValue }
    var entitlement: Double {
        switch self { case .annual: return 14; case .casual: return 5; case .medical: return 7; case .special: return 2 }
    }
}

enum RequestStatus: String, CaseIterable, Codable { case pending = "Pending", approved = "Approved", rejected = "Rejected" }

struct Attachment: Identifiable, Codable {
    var id = UUID()
    let name: String
    let data: Data
}

struct LeaveRequest: Identifiable, Codable {
    var id = UUID()
    let type: LeaveType
    let startDate: Date
    let endDate: Date
    let days: Double
    let reason: String
    var status: RequestStatus = .pending
    var rejectionReason: String?
    var attachment: Attachment?
    var employeeName: String?
    var epfNo: String?
    var dates: String {
        if Calendar.current.isDate(startDate, inSameDayAs: endDate) {
            return startDate.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(startDate.formatted(date: .abbreviated, time: .omitted)) - \(endDate.formatted(date: .abbreviated, time: .omitted))"
    }
}

enum FormError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

enum LeaveRules {
    // Calendar days are a demo rule; institutional working-day rules belong to the API.
    static func requestedDays(from start: Date, to end: Date, halfDay: Bool, calendar: Calendar = .current) throws -> Double {
        let start = calendar.startOfDay(for: start)
        let end = calendar.startOfDay(for: end)
        guard end >= start else { throw FormError.invalid("The end date must be on or after the start date.") }
        if halfDay {
            guard start == end else { throw FormError.invalid("Half-day leave must start and end on the same date.") }
            return 0.5
        }
        return Double((calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }

    static func availableBalance(for type: LeaveType, requests: [LeaveRequest], year: Int, calendar: Calendar = .current) -> Double {
        // Pending requests reserve days to prevent overbooking; rejected requests release them.
        type.entitlement - requests.filter {
            $0.type == type && $0.status != .rejected && calendar.component(.year, from: $0.startDate) == year
        }.reduce(0) { $0 + $1.days }
    }

    static func validate(start: Date, end: Date, halfDay: Bool, reason: String, balance: Double,
                         requests: [LeaveRequest], today: Date = Date(), calendar: Calendar = .current) throws -> Double {
        let days = try requestedDays(from: start, to: end, halfDay: halfDay, calendar: calendar)
        guard calendar.component(.year, from: start) == calendar.component(.year, from: end) else {
            throw FormError.invalid("Submit separate requests for different calendar years.")
        }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FormError.invalid("Enter a reason for your leave.")
        }
        guard days <= balance else { throw FormError.invalid("The request exceeds the available leave balance.") }
        guard !requests.contains(where: {
            $0.status != .rejected && calendar.startOfDay(for: start) <= calendar.startOfDay(for: $0.endDate)
                && calendar.startOfDay(for: end) >= calendar.startOfDay(for: $0.startDate)
        }) else { throw FormError.invalid("These dates overlap an existing pending or approved request.") }
        return days
    }
}

enum TicketStatus: String, CaseIterable, Identifiable, Codable {
    case open = "Open", assigned = "Assigned", inProgress = "In Progress", resolved = "Resolved", closed = "Closed"
    var id: String { rawValue }
}

struct Coordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    static let campus = Coordinate(latitude: 6.9271, longitude: 79.8612)
}

struct Asset: Identifiable {
    let id: String
    let name: String
    let building: String
    let room: String
    let coordinate: Coordinate
    static let samples: [Asset] = [
        Asset(id: "AC-305-01", name: "Air Conditioner", building: "Main Building", room: "Room 305", coordinate: .campus),
        Asset(id: "PROJ-B204", name: "Projector", building: "Building B", room: "Room B204", coordinate: Coordinate(latitude: 6.9275, longitude: 79.8618)),
        Asset(id: "ROOM-A103", name: "Room A103", building: "Building A", room: "Room A103", coordinate: Coordinate(latitude: 6.9258, longitude: 79.8620))
    ]
    static func identify(_ code: String) -> Asset? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return samples.first { $0.id == code }
    }
}

struct TicketComment: Identifiable, Codable {
    var id = UUID()
    let author: String
    let text: String
    var createdAt = Date()
}

struct TicketEvent: Identifiable, Codable {
    var id = UUID()
    let status: TicketStatus
    var date = Date()
}

struct Ticket: Identifiable, Codable {
    var id = UUID()
    let number: String
    let title: String
    let description: String
    let category: String
    let room: String
    let assetID: String
    let priority: String
    var status: TicketStatus = .open
    var updatedAt = Date()
    var coordinate: Coordinate?
    var photo: Attachment?
    var comments: [TicketComment] = []
    var events: [TicketEvent] = [TicketEvent(status: .open)]
    var assignedTo: String?
    var updated: String { updatedAt.formatted(date: .abbreviated, time: .shortened) }
}

enum TicketRules {
    static func nextNumber(tickets: [Ticket]) -> String {
        let maximum = tickets.compactMap { Int($0.number.replacingOccurrences(of: "NIBM-", with: "")) }.max() ?? 1042
        return "NIBM-\(maximum + 1)"
    }
    static func validate(title: String, description: String, room: String) throws {
        for (label, value) in [("title", title), ("description", description), ("room or asset", room)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FormError.invalid("Enter a \(label) before submitting the ticket.")
            }
        }
    }
}

enum NoticeDestination: Codable { case attendance, leave(UUID), ticket(UUID) }

struct AppNotice: Identifiable, Codable {
    var id = UUID()
    let title: String
    let destination: NoticeDestination
    var date = Date()
    var isRead = false
}

struct SavedState: Codable {
    var leaveRequests: [LeaveRequest]
    var tickets: [Ticket]
    var notices: [AppNotice]
}
