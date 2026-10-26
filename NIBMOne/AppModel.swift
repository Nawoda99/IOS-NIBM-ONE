import Foundation
import LocalAuthentication
import CoreLocation

final class AppModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var appLockEnabled = false
    @Published var selectedTab = 0
    @Published var leaveRequests: [LeaveRequest] = [
        LeaveRequest(type: .annual, dates: "12 - 13 Aug 2026", days: 2, reason: "Family commitment", status: .approved),
        LeaveRequest(type: .casual, dates: "28 Oct 2026", days: 1, reason: "Personal work", status: .pending)
    ]
    @Published var tickets: [Ticket] = [
        Ticket(number: "NIBM-1042", title: "Projector not displaying", category: "Projector", room: "Room B204", priority: "High", status: .inProgress, updated: "Today, 9:42 AM", coordinate: CLLocationCoordinate2D(latitude: 6.9271, longitude: 79.8612)),
        Ticket(number: "NIBM-1038", title: "Air conditioner leaking", category: "Air conditioning", room: "Room A103", priority: "Normal", status: .resolved, updated: "Yesterday", coordinate: CLLocationCoordinate2D(latitude: 6.9258, longitude: 79.8620))
    ]

    let attendance: [AttendanceDay] = {
        let calendar = Calendar.current
        let now = Date()
        return (-9...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            let isToday = offset == 0
            return AttendanceDay(date: date, status: isToday ? .late : .present, firstIn: isToday ? "08:47 AM" : "08:32 AM", lastOut: isToday ? "--" : "05:08 PM", worked: isToday ? "04h 12m" : "08h 18m", punches: [Punch(time: isToday ? "08:47 AM" : "08:32 AM", direction: "IN", machine: "Gate 01", branch: "Colombo")])
        }
    }()

    func signIn() { isAuthenticated = true }
    func signOut() { isAuthenticated = false; appLockEnabled = false }
    func authenticateWithFaceID() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock NIBM ONE")) ?? false
    }
}
