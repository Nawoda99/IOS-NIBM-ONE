import Foundation
import Combine
import LocalAuthentication
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isAuthenticated = false { didSet { updateWidget() } }
    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var appLockEnabled = false
    @Published private(set) var role: EmployeeRole = .employee
    @Published private(set) var permissions: Set<String> = []
    func can(_ permission: String) -> Bool { isRemoteSession ? permissions.contains(permission) : role.defaultPermissions.contains(permission) }
    @Published var selectedTab = 0
    @Published private(set) var leaveRequests: [LeaveRequest] = [] { didSet { updateWidget() } }
    @Published private(set) var tickets: [Ticket] = [] { didSet { updateWidget() } }
    @Published private(set) var notices: [AppNotice] = []
    @Published var storageError: String?
    @Published private(set) var isRemoteSession = false
    @Published private(set) var pushStatus = "Sign in to enable punch notifications."
    @Published private(set) var isLoading = false
    @Published private(set) var employeeName = "Alex Perera"
    @Published private(set) var employeeID: UUID?
    @Published private(set) var employeeDetails = EmployeeProfileDetails()
    @Published private(set) var epfNo = "900001"
    @Published private(set) var branch = "Colombo"
    @Published private(set) var remoteApprovals: [LeaveRequest] = []
    @Published private(set) var machineSync: [MachineSync] = []
    @Published private(set) var attendance: [AttendanceDay] = [] { didSet { updateWidget() } }
    @Published private(set) var sampleLoadedAt = Date()
    @Published private(set) var attendanceMonth = AttendanceCalendarRules.startOfMonth(Date())
    @Published private(set) var calendarAttendance: [AttendanceDay] = []
    @Published private(set) var isAttendanceLoading = false
    @Published private(set) var attendanceError: String?
    @Published private(set) var attendanceUpdatedAt: Date?
    private var attendanceRequestID = UUID()
    private let demoAttendance: [AttendanceDay]
    private var api: APIClient?
    private var sessionID = UUID()
    private let saveURL: URL?
    private var pendingWidgetTab: Int?

    init() {
        // Sessions are memory-only. Do not leave a prior user's summary after relaunch.
        WidgetSummaryStore.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSummary.kind)
        let calendar = AttendanceCalendarRules.calendar
        let now = Date()
        let start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let count = calendar.dateComponents([.day], from: start, to: now).day ?? 0
        let sampleAttendance: [AttendanceDay] = (0...count).compactMap { offset in
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
        demoAttendance = sampleAttendance
        saveURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NIBMOne", isDirectory: true).appendingPathComponent("demo-state-v1.json")
        attendance = sampleAttendance
        calendarAttendance = sampleAttendance
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

    func signIn(epfNo: String, password: String, role: EmployeeRole, useServer: Bool = false, serverURL: String = "http://localhost:8080") async throws {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if useServer {
            let client = try APIClient(baseURL: serverURL)
            let login: LoginResponse = try await client.request("api/login", method: "POST", body: APIClient.encode(LoginBody(epfNo: epfNo, password: password)))
            client.token = login.token
            let snapshot: RemoteSnapshot = try await client.request("api/snapshot")
            api = client; isRemoteSession = true; storageError = nil
            sessionID = UUID(); attendanceRequestID = UUID(); attendanceMonth = AttendanceCalendarRules.startOfMonth(Date())
            selectedTab = 0; isLocked = false
            apply(snapshot); isAuthenticated = true; navigateFromWidget()
            return
        }
        guard epfNo.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "900001",
              password == "Demo@123" else {
            throw FormError.invalid("Use the displayed demo credentials. Institutional login is not connected yet.")
        }
        api = nil; isRemoteSession = false; restoreDemoData()
        self.employeeName = "Alex Perera"; self.epfNo = "900001"; branch = "Colombo"
        employeeID = nil
        employeeDetails = .demo
        self.role = role
        attendanceMonth = AttendanceCalendarRules.startOfMonth(Date()); calendarAttendance = demoAttendance
        attendanceError = nil; attendanceUpdatedAt = sampleLoadedAt
        sessionID = UUID(); selectedTab = 0; isLocked = false; isAuthenticated = true; navigateFromWidget()
    }

    func signOut() {
        pendingWidgetTab = nil
        let oldAPI = api
        api = nil
        pushStatus = "Sign in to enable punch notifications."
        if let oldAPI { Task { _ = try? await oldAPI.send("api/logout"); oldAPI.token = nil } }
        sessionID = UUID(); isAuthenticated = false; isLocked = false
        appLockEnabled = false; selectedTab = 0; role = .employee; permissions = []
        isRemoteSession = false; leaveRequests = []; tickets = []; notices = []; attendance = []
        remoteApprovals = []; machineSync = []; storageError = nil
        attendanceRequestID = UUID(); calendarAttendance = []; attendanceError = nil
        attendanceUpdatedAt = nil; isAttendanceLoading = false
        attendanceMonth = AttendanceCalendarRules.startOfMonth(Date())
        employeeName = "Alex Perera"; epfNo = "900001"; branch = "Colombo"
        employeeID = nil
        employeeDetails = EmployeeProfileDetails()
    }

    func openWidgetURL(_ url: URL) {
        guard url.scheme == "nibmone", let host = url.host,
              let tab = ["attendance": 1, "leave": 2, "tickets": 3][host] else { return }
        pendingWidgetTab = tab
        if isAuthenticated { navigateFromWidget() }
    }

    func openPushDestination(_ destination: String) {
        guard isRemoteSession else { return }
        let host = destination == "ticket" ? "tickets" : destination
        if let url = URL(string: "nibmone://\(host)") { openWidgetURL(url) }
    }

    func registerPushDevice(token: String, environment: String) async {
        guard let api, isAuthenticated, isRemoteSession else { return }
        let session = sessionID
        do {
            _ = try await api.send("api/push/device", method: "PUT", body: APIClient.encode(PushDeviceBody(token: token, environment: environment)))
            let status: PushServerStatus = try await api.request("api/push/status")
            guard session == sessionID else { return }
            pushStatus = status.enabled ? "Ready for punch notifications." : "Device registered. The server still needs Apple push credentials."
        } catch {
            if session == sessionID { pushStatus = "Registration failed: \(error.localizedDescription)" }
        }
    }

    func disablePushDevice() async {
        guard let api, isAuthenticated, isRemoteSession else { return }
        let session = sessionID
        do {
            _ = try await api.send("api/push/device", method: "DELETE")
            if session == sessionID { pushStatus = "Notifications are disabled in iPhone Settings." }
        } catch {
            if session == sessionID { pushStatus = "Could not update notification settings: \(error.localizedDescription)" }
        }
    }

    private func navigateFromWidget() {
        guard let tab = pendingWidgetTab else { return }
        let required = [1: "attendance.view", 2: "leave.view", 3: "tickets.view"]
        selectedTab = required[tab].map { can($0) } == true ? tab : 0
        pendingWidgetTab = nil
    }

    private func updateWidget() {
        guard isAuthenticated else {
            WidgetSummaryStore.clear()
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSummary.kind)
            return
        }
        let today = attendance.first { AttendanceCalendarRules.calendar.isDate($0.date, inSameDayAs: Date()) }
        WidgetSummaryStore.save(WidgetSummary(updatedAt: Date(), isDemo: !isRemoteSession,
            firstIn: today?.firstIn ?? "--:--", lastOut: today?.lastOut ?? "--:--",
            pendingLeave: leaveRequests.filter { $0.status == .pending }.count,
            openTickets: tickets.filter { $0.status != .closed }.count))
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSummary.kind)
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
    func submitLeave(type: LeaveType, start: Date, end: Date, halfDay: Bool, reason: String, attachment: Attachment?) async throws -> LeaveRequest {
        if isRemoteSession {
            let request: LeaveRequest = try await remote("api/leave", method: "POST", body: APIClient.encode(LeaveBody(type: type, start: start, end: end, halfDay: halfDay, reason: reason, attachment: attachment)))
            leaveRequests.insert(request, at: 0)
            return request
        }
        let days = try LeaveRules.validate(start: start, end: end, halfDay: halfDay, reason: reason,
                                           balance: balance(for: type, date: start), requests: leaveRequests)
        let request = LeaveRequest(type: type, startDate: start, endDate: end, days: days,
                                   reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), attachment: attachment)
        var state = savedState
        state.leaveRequests.insert(request, at: 0)
        try commit(state)
        return request
    }

    func decideLeave(id: UUID, approve: Bool, reason: String) async throws {
        if isRemoteSession {
            let request: LeaveRequest = try await remote("api/leave/\(id.uuidString)/decision", method: "POST", body: APIClient.encode(DecisionBody(approve: approve, reason: reason)))
            if let index = remoteApprovals.firstIndex(where: { $0.id == id }) { remoteApprovals[index] = request }
            return
        }
        guard can("leave.approve") else { throw FormError.invalid("Leave approval access is required.") }
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
                      room: String, assetID: String, coordinate: Coordinate?, photo: Attachment?) async throws -> Ticket {
        if isRemoteSession {
            let ticket: Ticket = try await remote("api/tickets", method: "POST", body: APIClient.encode(TicketBody(title: title, description: description, category: category, priority: priority, room: room, assetID: assetID, coordinate: coordinate, photo: photo)))
            tickets.insert(ticket, at: 0)
            return ticket
        }
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

    func addComment(ticketID: UUID, text: String) async throws {
        if isRemoteSession {
            let ticket: Ticket = try await remote("api/tickets/\(ticketID.uuidString)/comments", method: "POST", body: APIClient.encode(CommentBody(text: text)))
            if let index = tickets.firstIndex(where: { $0.id == ticketID }) { tickets[index] = ticket }
            return
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FormError.invalid("Enter a comment before sending.") }
        guard let index = tickets.firstIndex(where: { $0.id == ticketID }) else { throw FormError.invalid("Ticket not found.") }
        var state = savedState
        state.tickets[index].comments.append(TicketComment(author: role == .support ? "Support (demo)" : "Alex Perera", text: text))
        state.tickets[index].updatedAt = Date()
        state.notices.insert(AppNotice(title: "New comment on \(tickets[index].number)", destination: .ticket(ticketID)), at: 0)
        try commit(state)
    }

    func advanceTicket(id: UUID) async throws {
        if isRemoteSession {
            let ticket: Ticket = try await remote("api/tickets/\(id.uuidString)/advance", method: "POST")
            if let index = tickets.firstIndex(where: { $0.id == id }) { tickets[index] = ticket }
            return
        }
        guard can("tickets.manage") else { throw FormError.invalid("Support access is required.") }
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

    func markRead(_ id: UUID) async {
        guard let index = notices.firstIndex(where: { $0.id == id }), !notices[index].isRead else { return }
        if isRemoteSession {
            do {
                _ = try await api?.send("api/notices/\(id.uuidString)/read")
                if isAuthenticated, let current = notices.firstIndex(where: { $0.id == id }) { notices[current].isRead = true }
            } catch { storageError = error.localizedDescription }
            return
        }
        var state = savedState; state.notices[index].isRead = true
        do { try commit(state) } catch { storageError = error.localizedDescription }
    }

    private var savedState: SavedState { SavedState(leaveRequests: leaveRequests, tickets: tickets, notices: notices) }

    var approvalRequests: [LeaveRequest] { isRemoteSession ? remoteApprovals : leaveRequests }
    func leaveRequest(id: UUID) -> LeaveRequest? { (leaveRequests + remoteApprovals).first { $0.id == id } }

    func refreshRemote() async {
        guard isRemoteSession, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot: RemoteSnapshot = try await remote("api/snapshot")
            apply(snapshot); storageError = nil
            if !AttendanceCalendarRules.sameMonth(attendanceMonth, Date()) { await refreshAttendanceMonth() }
        } catch { storageError = error.localizedDescription }
    }

    func moveAttendanceMonth(by offset: Int) {
        guard let next = AttendanceCalendarRules.calendar.date(byAdding: .month, value: offset, to: attendanceMonth),
              (2000...2100).contains(AttendanceCalendarRules.calendar.component(.year, from: next)) else { return }
        attendanceRequestID = UUID()
        attendanceMonth = AttendanceCalendarRules.startOfMonth(next)
        calendarAttendance = []; attendanceError = nil; attendanceUpdatedAt = nil; isAttendanceLoading = false
    }

    func showCurrentAttendanceMonth() {
        attendanceRequestID = UUID()
        attendanceMonth = AttendanceCalendarRules.startOfMonth(Date())
        calendarAttendance = attendance; attendanceError = nil; attendanceUpdatedAt = sampleLoadedAt; isAttendanceLoading = false
    }

    func refreshAttendanceMonth() async {
        guard isAuthenticated else { return }
        let month = attendanceMonth, key = AttendanceCalendarRules.monthKey(month)
        if !isRemoteSession {
            calendarAttendance = demoAttendance.filter { AttendanceCalendarRules.sameMonth($0.date, month) }
            attendanceUpdatedAt = Date(); attendanceError = nil
            return
        }
        let requestID = UUID(); attendanceRequestID = requestID; isAttendanceLoading = true
        defer { if attendanceRequestID == requestID { isAttendanceLoading = false } }
        do {
            let result: RemoteAttendanceMonth = try await remote("api/attendance", queryItems: [URLQueryItem(name: "month", value: key)])
            guard attendanceRequestID == requestID, AttendanceCalendarRules.monthKey(attendanceMonth) == key, !Task.isCancelled else { return }
            guard result.month == key, result.timeZone == "Asia/Colombo", result.method == "first-last" else { throw APIError.invalidResponse }
            calendarAttendance = AttendanceCalendarRules.days(punches: result.punches, leaves: leaveRequests, month: month)
            if AttendanceCalendarRules.sameMonth(month, Date()) { attendance = calendarAttendance }
            attendanceError = nil; attendanceUpdatedAt = Date()
        } catch {
            if attendanceRequestID == requestID && !Task.isCancelled { attendanceError = error.localizedDescription }
        }
    }

    func fingerprintMachines() async throws -> [MachineAdminStatus] { try await remote("api/machines") }
    func vehicleDirectory() async throws -> VehicleDirectory { try await remote("api/vehicles/directory") }
    func vehicleRequests() async throws -> [VehicleRequest] { try await remote("api/vehicles/requests") }
    func vehicleDriverTrips() async throws -> [VehicleRequest] { try await remote("api/vehicles/driver-trips") }
    func vehicleRequest(id: UUID) async throws -> VehicleRequest { try await remote("api/vehicles/requests/\(id.uuidString)") }
    func submitVehicleRequest(_ body: VehicleRequestBody) async throws -> VehicleRequest {
        try await remote("api/vehicles/requests", method: "POST", body: APIClient.encode(body))
    }
    func vehicleAction(id: UUID, action: String, body: Data? = nil) async throws -> VehicleRequest {
        try await remote("api/vehicles/requests/\(id.uuidString)/\(action)", method: "POST", body: body)
    }
    func vehicleTracking(id: UUID) async throws -> VehicleTracking { try await remote("api/vehicles/requests/\(id.uuidString)/tracking") }
    func companyVehicles() async throws -> [CompanyVehicle] { try await remote("api/vehicles/fleet") }
    func addCompanyVehicle(_ body: CompanyVehicleBody) async throws -> CompanyVehicle {
        try await remote("api/vehicles/fleet", method: "POST", body: APIClient.encode(body))
    }
    func sendVehicleLocation(id: UUID, body: VehicleLocationBody) async throws {
        let _: VehicleLocationReceipt = try await remote("api/vehicles/requests/\(id.uuidString)/location", method: "POST", body: APIClient.encode(body))
    }
    func pauseVehicleSharing(id: UUID, sharingKey: String) async throws {
        let _: VehicleLocationReceipt = try await remote("api/vehicles/requests/\(id.uuidString)/pause", method: "POST", body: APIClient.encode(VehiclePauseBody(sharingKey: sharingKey)))
    }
    func employeeAccounts(search: String = "", availableOnly: Bool = false) async throws -> [EmployeeAccount] {
        try await remote("api/admin/employees", queryItems: [URLQueryItem(name: "search", value: search), URLQueryItem(name: "available", value: availableOnly ? "true" : "false")])
    }
    func createEmployeeAccount(_ body: CreateEmployeeBody) async throws -> CreatedEmployee {
        try await remote("api/admin/employees", method: "POST", body: APIClient.encode(body))
    }
    func updateEmployeeAccount(id: UUID, role: EmployeeRole, branchID: Int?) async throws {
        guard let api, isAuthenticated else { throw APIError.sessionChanged }
        let session = sessionID
        _ = try await api.send("api/admin/employees/\(id.uuidString)", method: "PATCH", body: APIClient.encode(UpdateEmployeeBody(role: role, branchID: branchID)))
        guard session == sessionID, isAuthenticated else { throw APIError.sessionChanged }
        await refreshRemote()
    }
    func permissionDirectory() async throws -> PermissionDirectory { try await remote("api/admin/permissions") }
    func saveRolePermissions(role: EmployeeRole, permissions: Set<String>) async throws {
        let _: RolePermission = try await remote("api/admin/permissions/\(role.rawValue)", method: "PUT", body: APIClient.encode(PermissionBody(permissions: permissions.sorted())))
        await refreshRemote()
    }
    func branchDirectory() async throws -> BranchDirectory { try await remote("api/branches") }
    func saveBranchLocation(id: Int, address: String, coordinate: Coordinate) async throws {
        guard let api, isAuthenticated else { throw APIError.sessionChanged }
        let session = sessionID
        _ = try await api.send("api/admin/branches/\(id)/location", method: "PUT", body: APIClient.encode(BranchLocationBody(address: address, coordinate: coordinate)))
        guard session == sessionID, isAuthenticated else { throw APIError.sessionChanged }
    }
    func unmappedMachineUsers() async throws -> [UnmappedMachineUser] { try await remote("api/machines/unmapped") }
    func pullFingerprintPunches() async throws -> FingerprintResult {
        let result: FingerprintResult = try await remote("api/machines/sync", method: "POST")
        await refreshRemote()
        return result
    }
    func linkFingerprintEPF(epfNo: String) async throws {
        guard let api, isAuthenticated, isRemoteSession else { throw APIError.sessionChanged }
        let session = sessionID
        do {
            _ = try await api.send("api/machines/map", body: APIClient.encode(MachineMappingBody(epfNo: epfNo)))
            guard session == sessionID, isAuthenticated else { throw APIError.sessionChanged }
        } catch APIError.server(401, let reason) {
            if session == sessionID { signOut() }
            throw APIError.server(401, reason)
        }
        await refreshRemote()
    }

    private func remote<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, queryItems: [URLQueryItem] = []) async throws -> T {
        guard let api, isAuthenticated else { throw APIError.sessionChanged }
        let session = sessionID
        do {
            let value: T = try await api.request(path, method: method, body: body, queryItems: queryItems)
            guard session == sessionID, isAuthenticated else { throw APIError.sessionChanged }
            return value
        } catch APIError.server(401, let reason) {
            if session == sessionID { signOut() }
            throw APIError.server(401, reason)
        }
    }

    private func apply(_ snapshot: RemoteSnapshot) {
        employeeName = snapshot.profile.name; epfNo = snapshot.profile.epfNo; branch = snapshot.profile.branch; role = snapshot.profile.role
        employeeDetails = snapshot.profile.details ?? EmployeeProfileDetails()
        employeeID = snapshot.profile.id
        permissions = Set(snapshot.profile.permissions ?? Array(role.defaultPermissions))
        if (selectedTab == 1 && !can("attendance.view")) || (selectedTab == 2 && !can("leave.view")) || (selectedTab == 3 && !can("tickets.view")) { selectedTab = 0 }
        leaveRequests = snapshot.state.leaveRequests; tickets = snapshot.state.tickets; notices = snapshot.state.notices
        remoteApprovals = snapshot.approvals; machineSync = snapshot.sync
        attendance = AttendanceCalendarRules.days(punches: snapshot.punches, leaves: leaveRequests, month: Date())
        sampleLoadedAt = Date()
        if AttendanceCalendarRules.sameMonth(attendanceMonth, Date()) {
            calendarAttendance = attendance; attendanceUpdatedAt = sampleLoadedAt; attendanceError = nil
        }
    }

    private func restoreDemoData() {
        attendance = demoAttendance; remoteApprovals = []; machineSync = []; storageError = nil
        if let saveURL, FileManager.default.fileExists(atPath: saveURL.path) {
            do {
                let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: saveURL))
                leaveRequests = state.leaveRequests; tickets = state.tickets; notices = state.notices
            } catch { leaveRequests = []; tickets = []; notices = []; storageError = "Saved demo data could not be loaded: \(error.localizedDescription)" }
        } else { seedDemoData(now: Date(), calendar: .current) }
    }

    private func commit(_ state: SavedState) throws {
        // Persist first. A failed write leaves the form and current data unchanged for retry.
        guard storageError == nil else { throw FormError.invalid("Resolve the saved-data error before making changes. Your original file is preserved.") }
        guard let saveURL else { throw FormError.invalid("The application storage folder is unavailable.") }
        try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: saveURL, options: [.atomic, .completeFileProtection])
        leaveRequests = state.leaveRequests; tickets = state.tickets; notices = state.notices
    }
}
