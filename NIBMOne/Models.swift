import Foundation

enum EmployeeRole: String, CaseIterable, Identifiable {
    case employee = "Employee", approver = "Approver", support = "Support"
    var id: String { rawValue }
}

enum AttendanceStatus: String, CaseIterable, Identifiable, Codable {
    case present = "Present", late = "Late", absent = "Absent", halfDay = "Half day"
    case missingPunch = "Missing punch", leave = "Leave", offDay = "Off day"
    case holiday = "Holiday", noPay = "No pay"
    var id: String { rawValue }
}

enum PunchDirection: String, Codable { case inbound = "IN", outbound = "OUT" }

struct Punch: Identifiable, Codable {
    var id = UUID()
    let timestamp: Date
    let direction: PunchDirection
    let machine: String
    let branch: String
    var time: String { timestamp.formatted(date: .omitted, time: .shortened) }
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
        var open: Date?
        var seconds: TimeInterval = 0
        var incomplete = false
        for punch in sorted {
            switch punch.direction {
            case .inbound:
                if open != nil { incomplete = true } else { open = punch.timestamp }
            case .outbound:
                if let start = open { seconds += punch.timestamp.timeIntervalSince(start); open = nil }
                else { incomplete = true }
            }
        }
        return AttendanceSummary(firstIn: sorted.first { $0.direction == .inbound }?.timestamp,
                                 lastOut: sorted.last { $0.direction == .outbound }?.timestamp,
                                 workedMinutes: Int(seconds / 60), missingPunch: incomplete || open != nil)
    }
}

struct AttendanceDay: Identifiable {
    var id: Date { date }
    let date: Date
    let status: AttendanceStatus
    let punches: [Punch]
    var summary: AttendanceSummary { AttendanceRules.summary(for: punches) }
    var firstIn: String { summary.firstIn?.formatted(date: .omitted, time: .shortened) ?? "--" }
    var lastOut: String { summary.lastOut?.formatted(date: .omitted, time: .shortened) ?? "--" }
    var worked: String { summary.worked }
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
        guard calendar.startOfDay(for: start) >= calendar.startOfDay(for: today) else {
            throw FormError.invalid("Choose today or a future date.")
        }
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
