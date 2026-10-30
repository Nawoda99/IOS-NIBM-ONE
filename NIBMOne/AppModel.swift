import Foundation
import Combine
import LocalAuthentication

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var appLockEnabled = false
    @Published private(set) var role: EmployeeRole = .employee
    @Published var selectedTab = 0
    @Published private(set) var leaveRequests: [LeaveRequest] = []
    @Published private(set) var tickets: [Ticket] = []
    @Published private(set) var notices: [AppNotice] = []
    @Published var storageError: String?

    let attendance: [AttendanceDay]
    let sampleLoadedAt = Date()
    private var sessionID = UUID()
    private let saveURL: URL?

    init() {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let count = calendar.dateComponents([.day], from: start, to: now).day ?? 0
        attendance = (0...count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            if calendar.isDateInWeekend(day) { return AttendanceDay(date: day, status: .offDay, punches: []) }
            let today = calendar.isDate(day, inSameDayAs: now)
            let times: [(Int, Int, PunchDirection)] = today ? [(8, 47, .inbound)] : [
                (8, 32, PunchDirection.inbound), (12, 0, .outbound), (13, 0, .inbound), (17, 8, .outbound)
            ]
            let punches = times.compactMap { item -> Punch? in
                let (hour, minute, direction) = item
                guard let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { return nil }
                return Punch(timestamp: date, direction: direction, machine: "Gate 01", branch: "Colombo")
            }
            return AttendanceDay(date: day, status: today ? .missingPunch : .present, punches: punches)
        }
        saveURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NIBMOne", isDirectory: true).appendingPathComponent("demo-state-v1.json")
        if let saveURL, FileManager.default.fileExists(atPath: saveURL.path) {
            do {
                let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: saveURL))
                leaveRequests = state.leaveRequests; tickets = state.tickets; notices = state.notices
            } catch {
                // Keep the original file intact so a bad save is not silently overwritten.
                storageError = "Saved demo data could not be loaded: \(error.localizedDescription)"
            }
        } else {
            seedDemoData(now: now, calendar: calendar)
        }
    }

    private func seedDemoData(now: Date, calendar: Calendar) {
        let prior = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        leaveRequests = [LeaveRequest(type: .annual, startDate: prior, endDate: prior, days: 1,
                                      reason: "Family commitment", status: .approved)]
        tickets = [Ticket(number: "NIBM-1042", title: "Projector not displaying",
                          description: "The projector shows no image when connected to a laptop.",
                          category: "Projector", room: "Room B204", assetID: "PROJ-B204", priority: "High",
                          status: .inProgress, coordinate: Asset.samples[1].coordinate,
                          events: [TicketEvent(status: .open), TicketEvent(status: .assigned), TicketEvent(status: .inProgress)],
                          assignedTo: "IT support")]
        notices = [AppNotice(title: "Leave request approved", destination: .leave(leaveRequests[0].id)),
                   AppNotice(title: "Ticket NIBM-1042 updated", destination: .ticket(tickets[0].id)),
                   AppNotice(title: "Sample attendance includes an unmatched IN punch", destination: .attendance)]
    }

    func signIn(employeeID: String, password: String, role: EmployeeRole) throws {
        guard employeeID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "NIBM-00321",
              password == "Demo@123" else {
            throw FormError.invalid("Use the displayed demo credentials. Institutional login is not connected yet.")
        }
        self.role = role
        sessionID = UUID(); selectedTab = 0; isLocked = false; isAuthenticated = true
    }

    func signOut() {
        sessionID = UUID(); isAuthenticated = false; isLocked = false
        appLockEnabled = false; selectedTab = 0; role = .employee
    }

    func lock() { if isAuthenticated && appLockEnabled { isLocked = true } }

    func configureAppLock(enabled: Bool) async throws {
        guard enabled else { appLockEnabled = false; isLocked = false; return }
        guard try await authenticate() else { throw FormError.invalid("Authentication was not completed. App lock is still off.") }
        if isAuthenticated { appLockEnabled = true }
    }

    func unlock() async throws {
        if try await authenticate(), isAuthenticated { isLocked = false }
    }

    private func authenticate() async throws -> Bool {
        guard !isAuthenticating else { return false }
        let context = LAContext()
        var error: NSError?
        // System passcode is the fallback for devices without available biometrics.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw FormError.invalid(error?.localizedDescription ?? "Set up a device passcode or biometrics first.")
        }
        isAuthenticating = true
        let currentSession = sessionID
        defer { isAuthenticating = false }
        let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock NIBM ONE")
        return success && currentSession == sessionID && isAuthenticated
    }

    func balance(for type: LeaveType, date: Date = Date()) -> Double {
        LeaveRules.availableBalance(for: type, requests: leaveRequests, year: Calendar.current.component(.year, from: date))
    }

    @discardableResult
    func submitLeave(type: LeaveType, start: Date, end: Date, halfDay: Bool, reason: String, attachment: Attachment?) throws -> LeaveRequest {
        let days = try LeaveRules.validate(start: start, end: end, halfDay: halfDay, reason: reason,
                                           balance: balance(for: type, date: start), requests: leaveRequests)
        let request = LeaveRequest(type: type, startDate: start, endDate: end, days: days,
                                   reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), attachment: attachment)
        var state = savedState
        state.leaveRequests.insert(request, at: 0)
        try commit(state)
        return request
    }

    func decideLeave(id: UUID, approve: Bool, reason: String) throws {
        guard role == .approver else { throw FormError.invalid("Switch to the approver demo role to record decisions.") }
        guard let index = leaveRequests.firstIndex(where: { $0.id == id }), leaveRequests[index].status == .pending else {
            throw FormError.invalid("This request is no longer pending.")
        }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard approve || !reason.isEmpty else { throw FormError.invalid("Enter a rejection reason.") }
        var state = savedState
        state.leaveRequests[index].status = approve ? .approved : .rejected
        state.leaveRequests[index].rejectionReason = approve ? nil : reason
        state.notices.insert(AppNotice(title: "Leave request \(approve ? "approved" : "rejected")", destination: .leave(id)), at: 0)
        try commit(state)
    }

    @discardableResult
    func submitTicket(title: String, description: String, category: String, priority: String,
                      room: String, assetID: String, coordinate: Coordinate?, photo: Attachment?) throws -> Ticket {
        try TicketRules.validate(title: title, description: description, room: room)
        let ticket = Ticket(number: TicketRules.nextNumber(tickets: tickets),
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                            category: category, room: room, assetID: assetID, priority: priority,
                            coordinate: coordinate, photo: photo)
        var state = savedState
        state.tickets.insert(ticket, at: 0)
        try commit(state)
        return ticket
    }

    func addComment(ticketID: UUID, text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FormError.invalid("Enter a comment before sending.") }
        guard let index = tickets.firstIndex(where: { $0.id == ticketID }) else { throw FormError.invalid("Ticket not found.") }
        var state = savedState
        state.tickets[index].comments.append(TicketComment(author: role == .support ? "Support (demo)" : "Alex Perera", text: text))
        state.tickets[index].updatedAt = Date()
        state.notices.insert(AppNotice(title: "New comment on \(tickets[index].number)", destination: .ticket(ticketID)), at: 0)
        try commit(state)
    }

    func advanceTicket(id: UUID) throws {
        guard role == .support else { throw FormError.invalid("Support access is required.") }
        guard let index = tickets.firstIndex(where: { $0.id == id }),
              let current = TicketStatus.allCases.firstIndex(of: tickets[index].status),
              current + 1 < TicketStatus.allCases.count else { throw FormError.invalid("This ticket has no further status changes.") }
        var state = savedState
        let next = TicketStatus.allCases[current + 1]
        state.tickets[index].status = next
        state.tickets[index].assignedTo = "Support team (demo)"
        state.tickets[index].events.append(TicketEvent(status: next))
        state.tickets[index].updatedAt = Date()
        state.notices.insert(AppNotice(title: "\(tickets[index].number): \(next.rawValue)", destination: .ticket(id)), at: 0)
        try commit(state)
    }

    func markRead(_ id: UUID) {
        guard let index = notices.firstIndex(where: { $0.id == id }), !notices[index].isRead else { return }
        var state = savedState; state.notices[index].isRead = true
        do { try commit(state) } catch { storageError = error.localizedDescription }
    }

    private var savedState: SavedState { SavedState(leaveRequests: leaveRequests, tickets: tickets, notices: notices) }

    private func commit(_ state: SavedState) throws {
        // Persist first. A failed write leaves the form and current data unchanged for retry.
        guard storageError == nil else { throw FormError.invalid("Resolve the saved-data error before making changes. Your original file is preserved.") }
        guard let saveURL else { throw FormError.invalid("The application storage folder is unavailable.") }
        try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: saveURL, options: [.atomic, .completeFileProtection])
        leaveRequests = state.leaveRequests; tickets = state.tickets; notices = state.notices
    }
}
