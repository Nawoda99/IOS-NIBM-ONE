import Foundation
import CoreLocation

enum AttendanceStatus: String, CaseIterable, Identifiable {
    case present = "Present", late = "Late", absent = "Absent", leave = "Leave", holiday = "Holiday"
    var id: String { rawValue }
}

struct Punch: Identifiable {
    let id = UUID()
    let time: String
    let direction: String
    let machine: String
    let branch: String
}

struct AttendanceDay: Identifiable {
    let id = UUID()
    let date: Date
    let status: AttendanceStatus
    let firstIn: String
    let lastOut: String
    let worked: String
    let punches: [Punch]
}

enum LeaveType: String, CaseIterable, Identifiable {
    case annual = "Annual", casual = "Casual", medical = "Medical", special = "Special"
    var id: String { rawValue }
}

enum RequestStatus: String { case pending = "Pending", approved = "Approved", rejected = "Rejected" }

struct LeaveRequest: Identifiable {
    let id = UUID()
    let type: LeaveType
    let dates: String
    let days: Double
    let reason: String
    var status: RequestStatus
}

enum TicketStatus: String, CaseIterable, Identifiable {
    case open = "Open", assigned = "Assigned", inProgress = "In Progress", resolved = "Resolved", closed = "Closed"
    var id: String { rawValue }
}

struct Ticket: Identifiable {
    let id = UUID()
    let number: String
    let title: String
    let category: String
    let room: String
    let priority: String
    var status: TicketStatus
    let updated: String
    let coordinate: CLLocationCoordinate2D
}
