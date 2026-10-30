import Foundation

enum VehicleRequestStatus: String, Codable, CaseIterable {
    case pendingRecommendation = "Pending recommendation", pendingApproval = "Pending approval"
    case approved = "Approved", assigned = "Assigned", inProgress = "In progress", completed = "Completed"
    case rejected = "Rejected", cancelled = "Cancelled"
    var canCancel: Bool { [.pendingRecommendation, .pendingApproval, .approved, .assigned].contains(self) }
}

struct VehiclePerson: Codable, Identifiable {
    let id: UUID
    let name: String
    let epfNo: String
}

struct VehicleRequest: Codable, Identifiable {
    let id: UUID
    let number: String
    let requesterID: UUID
    let requesterName: String
    let epfNo: String
    let supervisorID: UUID
    let supervisorName: String
    let costCode: String
    let placeToVisit: String
    let dutyStatus: String
    let requiredDate: String
    let outwardTime: String
    let inwardTime: String
    let status: VehicleRequestStatus
    let vehicleID: UUID?
    let vehiclePlate: String?
    let vehicleName: String?
    let driverID: UUID?
    let driverName: String?
    let remarks: String?
    let createdAt: Date
    let startedAt: Date?
    let sharingKey: String?
    var schedule: String { "\(EmployeeProfileDetails.displayDate(requiredDate) ?? requiredDate) · \(outwardTime)–\(inwardTime)" }
}

struct CompanyVehicle: Codable, Identifiable {
    let id: UUID
    let plate: String
    let name: String
    let active: Bool
    let trip: VehicleRequest?
    let tracking: VehicleTracking?
}

struct VehicleDirectory: Decodable {
    let supervisors: [VehiclePerson]
    let drivers: [VehiclePerson]
    let vehicles: [CompanyVehicle]
}

struct VehicleTracking: Codable {
    let requestID: UUID
    let status: VehicleRequestStatus
    let location: VehicleLocation?
}

struct VehicleLocation: Codable {
    let coordinate: Coordinate
    let accuracy: Double
    let capturedAt: Date
    let receivedAt: Date
    let isSharing: Bool
    func isFresh(at now: Date = Date()) -> Bool {
        isSharing && (-30...90).contains(now.timeIntervalSince(capturedAt))
    }
}

struct VehicleRequestBody: Encodable {
    let costCode: String
    let supervisorID: UUID
    let placeToVisit: String
    let dutyStatus: String
    let requiredDate: String
    let outwardTime: String
    let inwardTime: String
}
struct VehicleDecisionBody: Encodable { let approve: Bool; let remarks: String }
struct VehicleAssignmentBody: Encodable { let vehicleID: UUID; let driverID: UUID }
struct CompanyVehicleBody: Encodable { let plate: String; let name: String }
struct VehicleLocationBody: Encodable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let capturedAt: Date
    let sharingKey: String
}
struct VehicleLocationReceipt: Decodable { let accepted: Bool }
struct VehiclePauseBody: Encodable { let sharingKey: String }

enum VehicleRules {
    static let timeZone = TimeZone(identifier: "Asia/Colombo")!
    static func dateKey(_ date: Date) -> String { format(date, "yyyy-MM-dd") }
    static func timeKey(_ date: Date) -> String { format(date, "HH:mm") }
    static func timeDate(hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
    static func validate(costCode: String, supervisorID: UUID?, place: String, duty: String,
                         date: Date, outward: Date, inward: Date, now: Date = Date()) throws {
        for (text, label, limit) in [(costCode, "cost code", 100), (place, "place to be visited", 500), (duty, "duty status", 500)] {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf16.count <= limit else { throw FormError.invalid("Enter a valid \(label) (maximum \(limit) characters).") }
        }
        guard supervisorID != nil else { throw FormError.invalid("Select your recommendation person.") }
        guard dateKey(date) >= dateKey(now) else { throw FormError.invalid("Choose today or a future required date.") }
        guard timeKey(inward) > timeKey(outward) else { throw FormError.invalid("Inward time must be later than outward time on the required date.") }
    }
}
