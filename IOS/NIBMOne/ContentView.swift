import SwiftUI
import UIKit
import CoreLocation
import MapKit
import PhotosUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                VStack(spacing: 24) {
                    Image(systemName: "building.2.crop.circle.fill").font(.system(size: 80)).foregroundStyle(Color.nibmBlue)
                    Text("Welcome to NIBM ONE").font(.largeTitle.bold())
                    Text("Review attendance, apply for leave and follow service requests in one place.")
                    Text("Connect to your MySQL backend for employee records and imported machine punches, or explore local demo data.").foregroundStyle(.secondary)
                    Button("Get started") { hasCompletedOnboarding = true }.buttonStyle(PrimaryButtonStyle())
                }.padding(28)
            } else if model.isAuthenticated {
                ZStack {
                    // Remove presented forms as well, so a sheet cannot sit above the lock.
                    if model.isLocked { AppLockView() } else { MainTabView() }
                    if scenePhase != .active && model.appLockEnabled {
                        Color.nibmBackground.ignoresSafeArea().overlay { Label("NIBM ONE", systemImage: "lock.fill").font(.title) }
                    }
                }
            } else { LoginView() }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.lock() } }
    }
}

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var epfNo = ""
    @State private var password = ""
    @State private var role: EmployeeRole = .employee
    @State private var error: String?
    @AppStorage("useMySQLBackend") private var useServer = AppConfiguration.current.useMySQLBackend
    @AppStorage("backendURL") private var serverURL = AppConfiguration.current.apiBaseURL
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "building.2.crop.circle.fill").font(.system(size: 66)).foregroundStyle(Color.nibmBlue)
                    Text("Welcome to\nNIBM ONE").font(.system(size: 36, weight: .bold)).foregroundStyle(Color.nibmNavy)
                    Text("One place for attendance, leave and service requests.").foregroundStyle(.secondary)
                    TextField("EPF No.", text: $epfNo).textContentType(.username).keyboardType(.numberPad).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    Toggle("Use MySQL backend", isOn: $useServer)
                    if useServer {
                        if let issue = AppConfiguration.loadIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                        TextField("Backend URL", text: $serverURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        Text("Simulator: http://localhost:8080. On an iPhone, use your server's LAN address. Your role comes from the server.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Demo role", selection: $role) { ForEach(EmployeeRole.allCases) { Text($0.rawValue).tag($0) } }
                    }
                    Button("Fill sample EPF credentials") { epfNo = "900001"; password = "Demo@123"; error = nil }.buttonStyle(.bordered)
                    Button("Sign in") {
                        Task {
                            do { try await model.signIn(epfNo: epfNo, password: password, role: role, useServer: useServer, serverURL: serverURL) }
                            catch { self.error = error.localizedDescription }
                        }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(model.isLoading)
                    if model.isLoading { ProgressView("Signing in") }
                    Text("Sample account only: EPF 900001 / Demo@123. Use your own registered EPF No. for actual employee records.").font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    NavigationLink("Forgot password?", destination: ResetPasswordView())
                }.padding(24)
            }.background(Color.nibmBackground.ignoresSafeArea())
        }.errorAlert($error)
    }
}

struct ResetPasswordView: View {
    @State private var email = ""
    @State private var error: String?
    @State private var showResult = false
    var body: some View {
        Form {
            Section("Recover access") {
                TextField("Institutional email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Check recovery options") {
                    let parts = email.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@")
                    guard parts.count == 2, parts[1].contains("."), !email.contains(" ") else { error = "Enter a valid email address."; return }
                    showResult = true
                }
            }
            Text("Password recovery requires the institutional API. No reset email is sent by this demo.").foregroundStyle(.secondary)
        }.navigationTitle("Reset password").errorAlert($error)
            .alert("Demo recovery", isPresented: $showResult) {
                Button("OK", role: .cancel) {}
            } message: { Text("No email was sent. Use 900001 and Demo@123 to access this build, or contact your administrator for an institutional password reset.") }
    }
}

struct AppLockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var error: String?
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill").font(.system(size: 72)).foregroundStyle(Color.nibmBlue)
            Text("NIBM ONE is locked").font(.title2.bold())
            Button("Unlock with Face ID or passcode") {
                Task { do { try await model.unlock() } catch { self.error = error.localizedDescription } }
            }.buttonStyle(PrimaryButtonStyle()).disabled(model.isAuthenticating)
            Button("Sign out", role: .destructive) { model.signOut() }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.nibmBackground.ignoresSafeArea()).errorAlert($error)
    }
}

struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TabView(selection: $model.selectedTab) {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            AttendanceView().tabItem { Label("Attendance", systemImage: "calendar") }.tag(1)
            LeaveView().tabItem { Label("Leave", systemImage: "doc.text.fill") }.tag(2)
            TicketsView().tabItem { Label("Tickets", systemImage: "wrench.and.screwdriver.fill") }.tag(3)
            MoreView().tabItem { Label("More", systemImage: "ellipsis.circle.fill") }.tag(4)
        }.tint(.nibmBlue)
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading) { Text("Welcome back,").foregroundStyle(.secondary); Text(model.employeeName).font(.title2.bold()) }
                        Spacer()
                        NavigationLink(destination: NotificationsView()) { Label("Notifications", systemImage: "bell.badge").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) }
                    }
                    Label(model.isRemoteSession ? "Connected to MySQL API" : "Local demo data", systemImage: model.isRemoteSession ? "network" : "info.circle").font(.caption).foregroundStyle(.secondary)
                    if let error = model.storageError { Text(error).foregroundStyle(.red) }
                    if let today = model.attendance.first(where: { AttendanceCalendarRules.calendar.isDateInToday($0.date) }) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Today's attendance").font(.headline)
                            HStack { Metric(title: "First IN", value: today.firstIn); Metric(title: "Last OUT", value: today.lastOut); Metric(title: "Time span", value: today.worked) }
                            StatusPill(text: today.status.rawValue, color: today.status.color)
                            NavigationLink("View punches", destination: DayDetailsView(day: today))
                        }.cardStyle()
                    } else { Text("No attendance record for today.").cardStyle() }
                    HStack(alignment: .top) {
                        NavigationLink(destination: ApplyLeaveView()) { QuickAction(title: "Apply leave", icon: "doc.badge.plus") }
                        NavigationLink(destination: CreateTicketView()) { QuickAction(title: "Create ticket", icon: "plus.circle") }
                        NavigationLink(destination: ScanToTicketView()) { QuickAction(title: "Scan QR", icon: "qrcode.viewfinder") }
                    }
                    AttendanceCalendar()
                    HStack {
                        Metric(title: "Available leave", value: "\(LeaveType.allCases.reduce(0) { $0 + model.balance(for: $1) }.formatted()) days")
                        Metric(title: "Pending leave", value: "\(model.leaveRequests.filter { $0.status == .pending }.count)")
                        Metric(title: "Open tickets", value: "\(model.tickets.filter { $0.status != .closed && $0.status != .resolved }.count)")
                    }.cardStyle()
                    NavigationLink("Recent notifications", destination: NotificationsView())
                }.padding()
            }.background(Color.nibmBackground.ignoresSafeArea()).navigationTitle("NIBM ONE")
                .refreshable { await model.refreshRemote() }
                .task { await model.refreshRemote() }
                .toolbar { NavigationLink(destination: ProfileView()) { Label("Profile", systemImage: "person.crop.circle") } }
        }
    }
}

struct AttendanceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var mode = 1
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Attendance view", selection: $mode) { Text("Records").tag(0); Text("Calendar").tag(1); Text("Summary").tag(2) }.pickerStyle(.segmented)
                    if model.isRemoteSession {
                        Text("Connected to backend • EPF \(model.epfNo). Pull to refresh.").font(.caption).foregroundStyle(.secondary)
                        if model.machineSync.isEmpty { Text("No punches are linked to this EPF yet. The employee EPF must match the machine's EPF number.").font(.caption).foregroundStyle(.orange) }
                        ForEach(model.machineSync) { machine in
                            VStack(alignment: .leading) {
                                Text(machine.name).font(.caption.bold())
                                Text(machine.lastSyncedAt.map { "Last machine sync: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Machine has not completed a sync yet.").font(.caption)
                                if let error = machine.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                            }
                        }
                    } else { Text("Sample records loaded \(model.sampleLoadedAt.formatted(date: .omitted, time: .shortened)).").font(.caption).foregroundStyle(.secondary) }
                    if let error = model.storageError { Text(error).font(.caption).foregroundStyle(.red) }
                    if mode != 1, let error = model.attendanceError { Text(error).font(.caption).foregroundStyle(.red) }
                }
                if mode != 1 { Section { AttendanceMonthControls(dark: false) } }
                if mode == 0 {
                    Section(AttendanceCalendarRules.monthTitle(model.attendanceMonth)) {
                        if model.calendarAttendance.isEmpty { Text(model.isAttendanceLoading ? "Loading attendance…" : "No attendance records for this month.").foregroundStyle(.secondary) }
                        ForEach(model.calendarAttendance.reversed()) { day in NavigationLink(destination: DayDetailsView(day: day)) { AttendanceRow(day: day) } }
                    }
                } else if mode == 1 {
                    Section { AttendanceCalendar().listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                } else {
                    Section("Monthly summary") {
                        AttendanceMonthlySummary(days: model.calendarAttendance, month: model.attendanceMonth)
                    }
                }
            }.navigationTitle("Attendance").refreshable { await model.refreshRemote(); await model.refreshAttendanceMonth() }
                .task { await model.refreshRemote() }
                .task(id: "\(mode)-\(AttendanceCalendarRules.monthKey(model.attendanceMonth))") { if mode != 1 { await model.refreshAttendanceMonth() } }
                .toolbar { NavigationLink(destination: PunchRecordsView()) { Label("Punch records", systemImage: "list.bullet.rectangle") } }
        }
    }
}

struct AttendanceCalendar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Attendance calendar").font(.title3.bold()).foregroundStyle(.white)
                    Spacer(minLength: 4)
                    Circle().fill(model.isRemoteSession && model.attendanceError == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(model.isRemoteSession ? model.attendanceError == nil ? "LIVE" : "CACHED" : "DEMO").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
                AttendanceMonthControls(dark: true)
                HStack {
                    Text("IN above • OUT below").font(.caption2).foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    if model.isAttendanceLoading { ProgressView().tint(.white).scaleEffect(0.7) }
                    Button { Task { await model.refreshAttendanceMonth() } } label: { Image(systemName: "arrow.clockwise").frame(width: 30, height: 30) }
                        .foregroundStyle(.white).accessibilityLabel("Refresh attendance").disabled(model.isAttendanceLoading)
                }
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(weekdays, id: \.self) { Text($0).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).padding(.bottom, 3) }
                    ForEach(0..<AttendanceCalendarRules.leadingDays(in: model.attendanceMonth), id: \.self) { _ in Color.clear.frame(height: 84) }
                    ForEach(AttendanceCalendarRules.dates(in: model.attendanceMonth), id: \.self) { date in
                        let day = model.calendarAttendance.first { AttendanceCalendarRules.calendar.isDate($0.date, inSameDayAs: date) }
                            ?? AttendanceDay(date: date, status: .noRecord, punches: [])
                        NavigationLink(destination: DayDetailsView(day: day)) { AttendanceDayCard(day: day) }.buttonStyle(.plain)
                    }
                }
                if let error = model.attendanceError { Text(error).font(.caption).foregroundStyle(Color(red: 1, green: 0.66, blue: 0.60)) }
                if model.calendarAttendance.isEmpty && !model.isAttendanceLoading {
                    Text(model.isRemoteSession ? "No punches for EPF \(model.epfNo) in this month. Sign in with the employee EPF recorded by the machine." : "No demo records in this month.")
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                HStack {
                    Text("EPF \(model.epfNo)")
                    Spacer()
                    Text(model.attendanceUpdatedAt.map { "Updated \(AttendanceCalendarRules.time($0))" } ?? "Waiting for records")
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }.padding(14)
                .background(LinearGradient(colors: [Color(red: 0.07, green: 0.12, blue: 0.25), Color(red: 0.10, green: 0.18, blue: 0.33)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 20))
            AttendanceMonthlySummary(days: model.calendarAttendance, month: model.attendanceMonth).cardStyle()
        }.task(id: AttendanceCalendarRules.monthKey(model.attendanceMonth) + (scenePhase == .active ? "-active" : "-inactive")) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if !model.isLocked { await model.refreshAttendanceMonth() }
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }
}

struct AttendanceMonthControls: View {
    @EnvironmentObject private var model: AppModel
    let dark: Bool
    var body: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AttendanceCalendarRules.monthTitle(model.attendanceMonth)).font(.headline)
                if !AttendanceCalendarRules.sameMonth(model.attendanceMonth, Date()) {
                    Button("This month") { model.showCurrentAttendanceMonth() }.font(.caption)
                }
            }
            Spacer(minLength: 0)
            Button { model.moveAttendanceMonth(by: -1) } label: { Image(systemName: "chevron.left").font(.headline).frame(width: 42, height: 42).background(Color.blue.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 11)) }
                .accessibilityLabel("Previous month")
            Button { model.moveAttendanceMonth(by: 1) } label: { Image(systemName: "chevron.right").font(.headline).frame(width: 42, height: 42).background(Color.blue.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 11)) }
                .accessibilityLabel("Next month")
        }.buttonStyle(.plain).foregroundStyle(dark ? Color.white : Color.primary)
    }
}

struct AttendanceMonthlySummary: View {
    let days: [AttendanceDay]
    let month: Date
    private var present: Int { days.filter { !$0.punches.isEmpty && !$0.summary.missingPunch }.count }
    private var partial: Int { days.filter { $0.summary.missingPunch }.count }
    private var leave: Int { days.filter { $0.status == .leave || $0.status == .halfDay }.count }
    private var missing: Int { max(0, AttendanceCalendarRules.dates(in: month).count - days.count) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monthly summary").font(.headline)
            summaryRow("Present", value: present, color: .green)
            summaryRow("OUT pending / one punch", value: partial, color: .orange)
            summaryRow("Approved leave", value: leave, color: .blue)
            summaryRow("No record", value: missing, color: .gray)
            let minutes = days.reduce(0) { $0 + $1.summary.workedMinutes }
            LabeledContent("Recorded time span", value: "\(minutes / 60)h \(minutes % 60)m").font(.subheadline)
            Text("First punch is IN; last distinct punch is OUT. Time span includes breaks. No record does not mean absent.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func summaryRow(_ label: String, value: Int, color: Color) -> some View {
        HStack { Circle().fill(color).frame(width: 8, height: 8); Text(label); Spacer(); Text("\(value)").fontWeight(.semibold).monospacedDigit() }.font(.subheadline)
    }
}

struct PunchRecordsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            ForEach(model.calendarAttendance.reversed().filter { !$0.punches.isEmpty }) { day in
                Section(AttendanceCalendarRules.dayTitle(day.date)) {
                    ForEach(day.punches) { punch in
                        HStack {
                            Image(systemName: punch.direction == .unknown ? "questionmark.circle.fill" : punch.direction == .inbound ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill").foregroundStyle(punch.direction == .unknown ? Color.orange : punch.direction == .inbound ? Color.green : Color.red)
                            VStack(alignment: .leading) { Text(punch.time).font(.headline); Text("\(punch.machine) - \(punch.branch)").font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Text(punch.direction.rawValue)
                        }
                    }
                }
            }
        }.navigationTitle("Fingerprint punches")
    }
}

struct DayDetailsView: View {
    let day: AttendanceDay
    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Status", value: day.status.rawValue)
                LabeledContent("Recorded time span", value: day.worked)
                LabeledContent("First IN", value: day.firstIn); LabeledContent("Last OUT", value: day.lastOut)
                if day.summary.missingPunch { Label("One punch recorded • OUT pending", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Text("IN is the first punch; OUT is the last distinct punch of the Sri Lanka calendar day. Time span includes breaks.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Punch history") {
                if day.punches.isEmpty { Text("No punches recorded for this day.").foregroundStyle(.secondary) }
                ForEach(day.punches) { punch in Text("\(punch.time) - \(punch.direction.rawValue) - \(punch.machine) - \(punch.branch)") }
            }
        }.navigationTitle(AttendanceCalendarRules.dayTitle(day.date))
    }
}

struct LeaveView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = "All"
    var body: some View {
        NavigationStack {
            List {
                Section("Available balance (pending days reserved)") {
                    ForEach(LeaveType.allCases) { type in LabeledContent(type.rawValue, value: "\(model.balance(for: type).formatted()) days") }
                    NavigationLink("Apply for leave", destination: ApplyLeaveView())
                }
                Section("Request history") {
                    Picker("Status", selection: $filter) { Text("All").tag("All"); ForEach(RequestStatus.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) } }
                    if model.leaveRequests.filter({ filter == "All" || $0.status.rawValue == filter }).isEmpty { Text("No matching requests.").foregroundStyle(.secondary) }
                    ForEach(model.leaveRequests.filter { filter == "All" || $0.status.rawValue == filter }) { request in
                        NavigationLink(destination: LeaveDetailView(requestID: request.id)) {
                            HStack { VStack(alignment: .leading) { Text(request.type.rawValue).font(.headline); Text(request.dates).font(.caption) }; Spacer(); StatusPill(text: request.status.rawValue, color: request.status.color) }
                        }
                    }
                }
            }.navigationTitle("Leave").refreshable { await model.refreshRemote() }.task { await model.refreshRemote() }
        }
    }
}

struct ApplyLeaveView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var type: LeaveType = .annual
    @State private var start = Date()
    @State private var end = Date()
    @State private var reason = ""
    @State private var halfDay = false
    @State private var attachment: Attachment?
    @State private var error: String?
    @State private var submitted: LeaveRequest?
    @State private var showConfirmation = false
    @State private var showDetails = false
    @State private var isSubmitting = false
    private var days: Double { (try? LeaveRules.requestedDays(from: start, to: end, halfDay: halfDay)) ?? 0 }
    var body: some View {
        Form {
            Section("Leave details") {
                Picker("Leave type", selection: $type) { ForEach(LeaveType.allCases) { Text($0.rawValue).tag($0) } }
                DatePicker("From", selection: $start, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                DatePicker("To", selection: $end, in: Calendar.current.startOfDay(for: start)..., displayedComponents: .date).disabled(halfDay)
                Toggle("Half-day", isOn: $halfDay)
                TextField("Reason", text: $reason, axis: .vertical)
                DocumentAttachmentPicker(attachment: $attachment)
            }
            Section("Balance preview") {
                LabeledContent("Requested", value: "\(days.formatted()) days")
                LabeledContent("Available", value: "\(model.balance(for: type, date: start).formatted()) days")
                LabeledContent("After request", value: "\((model.balance(for: type, date: start) - days).formatted()) days")
                Text("Demo rule: calendar days, including weekends. Half-day requests cover one date. Institutional rules require the API.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Submit request") {
                guard !isSubmitting else { return }; isSubmitting = true
                Task {
                    defer { isSubmitting = false }
                    do {
                        submitted = try await model.submitLeave(type: type, start: start, end: end, halfDay: halfDay, reason: reason, attachment: attachment)
                        showConfirmation = true
                    } catch { self.error = error.localizedDescription }
                }
            }.disabled(submitted != nil || isSubmitting)
            if isSubmitting { ProgressView("Saving request") }
        }.navigationTitle("Apply for leave").errorAlert($error)
            .onChange(of: start) { _, date in if halfDay || end < date { end = date } }
            .onChange(of: halfDay) { _, enabled in if enabled { end = start } }
            .alert("Request submitted", isPresented: $showConfirmation) {
                Button("View details") { showDetails = true }
                Button("Done") { dismiss() }
            } message: { Text(model.isRemoteSession ? "Your request is saved in MySQL with Pending status." : "Your demo request is saved with Pending status.") }
            .navigationDestination(isPresented: $showDetails) {
                if let submitted { LeaveDetailView(requestID: submitted.id) }
            }
    }
}

struct LeaveDetailView: View {
    @EnvironmentObject private var model: AppModel
    let requestID: UUID
    @State private var rejectionReason = ""
    @State private var error: String?
    @State private var decisionRecorded = false
    @State private var isSubmitting = false
    var body: some View {
        List {
            if let request = model.leaveRequest(id: requestID) {
                Section("Request") {
                    LabeledContent("Employee", value: request.employeeName ?? model.employeeName)
                    LabeledContent("Type", value: request.type.rawValue); LabeledContent("Dates", value: request.dates)
                    LabeledContent("Duration", value: "\(request.days.formatted()) days")
                    LabeledContent("Status", value: request.status.rawValue)
                    if !model.isRemoteSession || request.epfNo == model.epfNo { LabeledContent("Available balance", value: "\(model.balance(for: request.type, date: request.startDate).formatted()) days") }
                }
                Section("Reason") { Text(request.reason) }
                if let reason = request.rejectionReason { Section("Rejection reason") { Text(reason) } }
                if let attachment = request.attachment { Section("Supporting document") { AttachmentPreview(attachment: attachment) } }
                if model.role == .approver && request.status == .pending {
                    Section(model.isRemoteSession ? "Manager decision" : "Demo manager decision") {
                        TextField("Reason required for rejection", text: $rejectionReason, axis: .vertical)
                        Button("Approve") { decide(approve: true) }
                        Button("Reject", role: .destructive) { decide(approve: false) }
                    }.disabled(isSubmitting)
                }
            } else { ContentUnavailableView("Request not found", systemImage: "doc.questionmark") }
        }.navigationTitle("Leave details").errorAlert($error)
            .alert("Decision recorded", isPresented: $decisionRecorded) { Button("OK", role: .cancel) {} }
    }
    private func decide(approve: Bool) {
        guard !isSubmitting else { return }; isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do { try await model.decideLeave(id: requestID, approve: approve, reason: rejectionReason); decisionRecorded = true }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct LeaveApprovalsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            if model.approvalRequests.filter({ $0.status == .pending }).isEmpty { Text("No pending requests.") }
            ForEach(model.approvalRequests.filter { $0.status == .pending }) { request in
                NavigationLink(destination: LeaveDetailView(requestID: request.id)) { VStack(alignment: .leading) { Text("\(request.employeeName ?? model.employeeName) - \(request.type.rawValue)"); Text(request.dates).font(.caption) } }
            }
        }.navigationTitle("Leave approvals").refreshable { await model.refreshRemote() }.task { await model.refreshRemote() }
    }
}

struct TicketsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var filter = "All"
    private var filtered: [Ticket] {
        model.tickets.filter { ticket in
            (filter == "All" || ticket.status.rawValue == filter) && (search.isEmpty || "\(ticket.number) \(ticket.title) \(ticket.room) \(ticket.assetID)".localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(destination: CreateTicketView()) { Label("Create ticket", systemImage: "plus.circle.fill") }
                    NavigationLink(destination: ScanToTicketView()) { Label("Scan room / asset QR", systemImage: "qrcode.viewfinder") }
                    Picker("Status", selection: $filter) { Text("All").tag("All"); ForEach(TicketStatus.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                }
                Section("My tickets") {
                    if filtered.isEmpty { Text("No matching tickets.").foregroundStyle(.secondary) }
                    ForEach(filtered) { ticket in
                        NavigationLink(destination: TicketDetailView(ticketID: ticket.id)) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(ticket.number).font(.caption.bold()); Spacer(); StatusPill(text: ticket.status.rawValue, color: ticket.status == .resolved || ticket.status == .closed ? .green : .blue) }
                                Text(ticket.title).font(.headline)
                                Text("\(ticket.room) - \(ticket.updated)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.searchable(text: $search, prompt: "Number, title, room or asset").navigationTitle("Service requests")
                .refreshable { await model.refreshRemote() }.task { await model.refreshRemote() }
                .toolbar { NavigationLink(destination: TicketMapView()) { Label("Ticket map", systemImage: "map") } }
        }
    }
}

struct CreateTicketView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var category = "IT"
    @State private var priority = "Normal"
    @State private var room = ""
    @State private var assetID = ""
    @State private var coordinate: Coordinate?
    @State private var photo: Attachment?
    @State private var photoItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var showScanner = false
    @State private var showLocation = false
    @State private var error: String?
    @State private var submitted: Ticket?
    @State private var showConfirmation = false
    @State private var showDetails = false
    @State private var isSubmitting = false
    init(asset: Asset? = nil) {
        _room = State(initialValue: asset?.room ?? "")
        _assetID = State(initialValue: asset?.id ?? "")
        // The asset's indoor room and a user-confirmed ticket location are separate fields.
    }
    var body: some View {
        Form {
            Section("Problem") {
                TextField("Title", text: $title)
                TextField("Description", text: $description, axis: .vertical)
                Picker("Category", selection: $category) {
                    ForEach(["IT", "Network", "Air conditioning", "Electrical", "Projector", "Furniture", "Maintenance", "Other"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Priority", selection: $priority) { Text("Normal").tag("Normal"); Text("High").tag("High") }
            }
            Section("Room and asset") {
                Button("Scan room / asset QR") { showScanner = true }
                Picker("Registered demo asset", selection: $assetID) {
                    Text("Manual room").tag("")
                    ForEach(Asset.samples) { Text("\($0.name) - \($0.room)").tag($0.id) }
                }
                TextField("Room (required)", text: $room)
                if !assetID.isEmpty { LabeledContent("Asset", value: assetID) }
                Button(coordinate == nil ? "Attach ticket location" : "Review ticket location") { showLocation = true }
                if let coordinate {
                    Text("\(coordinate.latitude.formatted()), \(coordinate.longitude.formatted())").font(.caption)
                    Button("Remove location", role: .destructive) { self.coordinate = nil }
                }
            }
            Section("Photo (optional)") {
                PhotosPicker(selection: $photoItem, matching: .images) { Label("Choose photo", systemImage: "photo") }
                if isLoadingPhoto { ProgressView("Loading photo") }
                if let photo { AttachmentPreview(attachment: photo); Button("Remove photo", role: .destructive) { self.photo = nil; photoItem = nil } }
            }
            Button("Submit ticket") {
                guard !isSubmitting else { return }; isSubmitting = true
                Task {
                    defer { isSubmitting = false }
                    do {
                        submitted = try await model.submitTicket(title: title, description: description, category: category, priority: priority,
                                                                 room: room, assetID: assetID, coordinate: coordinate, photo: photo)
                        showConfirmation = true
                    } catch { self.error = error.localizedDescription }
                }
            }.disabled(isLoadingPhoto || isSubmitting || submitted != nil)
            if isSubmitting { ProgressView("Saving ticket") }
        }.navigationTitle("Create ticket").errorAlert($error)
            .onChange(of: assetID) { _, code in if let asset = Asset.identify(code) { room = asset.room } }
            .task(id: photoItem) {
                guard let photoItem else { return }
                isLoadingPhoto = true
                defer { isLoadingPhoto = false }
                do {
                    guard let data = try await photoItem.loadTransferable(type: Data.self) else { throw FormError.invalid("The photo could not be loaded.") }
                    try Task.checkCancellation()
                    guard data.count <= 8_000_000 else { throw FormError.invalid("Choose a photo smaller than 8 MB.") }
                    guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) else {
                        throw FormError.invalid("The selected photo could not be decoded. Choose a different image.")
                    }
                    guard jpeg.count <= 8_000_000 else { throw FormError.invalid("Choose a photo smaller than 8 MB.") }
                    photo = Attachment(name: "ticket-photo.jpg", data: jpeg)
                } catch is CancellationError { } catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $showScanner) {
                NavigationStack { QRScannerView { asset in assetID = asset.id; room = asset.room; showScanner = false } }
            }
            .sheet(isPresented: $showLocation) { NavigationStack { TicketLocationView(coordinate: $coordinate) } }
            .alert("Ticket submitted", isPresented: $showConfirmation) {
                Button("View details") { showDetails = true }; Button("Done") { dismiss() }
            } message: { Text("\(submitted?.number ?? "Ticket") is saved \(model.isRemoteSession ? "in MySQL" : "on this device").") }
            .navigationDestination(isPresented: $showDetails) { if let submitted { TicketDetailView(ticketID: submitted.id) } }
    }
}

struct TicketDetailView: View {
    @EnvironmentObject private var model: AppModel
    let ticketID: UUID
    @State private var comment = ""
    @State private var error: String?
    @State private var isSubmitting = false
    var body: some View {
        List {
            if let ticket = model.tickets.first(where: { $0.id == ticketID }) {
                Section("Request") {
                    Text(ticket.title).font(.headline)
                    LabeledContent("Number", value: ticket.number); LabeledContent("Category", value: ticket.category)
                    LabeledContent("Room", value: ticket.room); LabeledContent("Asset", value: ticket.assetID.isEmpty ? "Not selected" : ticket.assetID)
                    LabeledContent("Priority", value: ticket.priority); LabeledContent("Status", value: ticket.status.rawValue)
                    LabeledContent("Assigned to", value: ticket.assignedTo ?? "Awaiting assignment")
                    LabeledContent("Updated", value: ticket.updated)
                }
                Section("Description") { Text(ticket.description) }
                if let photo = ticket.photo { Section("Photo") { AttachmentPreview(attachment: photo) } }
                if let coordinate = ticket.coordinate {
                    Section("Location") { Map { Marker(ticket.room, coordinate: coordinate.clLocation) }.frame(height: 220) }
                }
                Section("Timeline") {
                    ForEach(ticket.events) { event in VStack(alignment: .leading) { Label(event.status.rawValue, systemImage: "checkmark.circle.fill"); Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) } }
                    if model.role == .support && ticket.status != .closed {
                        Button("Advance to next status") {
                            guard !isSubmitting else { return }; isSubmitting = true
                            Task {
                                defer { isSubmitting = false }
                                do { try await model.advanceTicket(id: ticketID) } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(isSubmitting)
                    }
                }
                Section("Comments") {
                    if ticket.comments.isEmpty { Text("No comments yet.").foregroundStyle(.secondary) }
                    ForEach(ticket.comments) { entry in
                        VStack(alignment: .leading, spacing: 6) { Text(entry.author).font(.caption.bold()); Text(entry.text); Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    }
                    TextField("Write a comment", text: $comment, axis: .vertical)
                    Button("Send comment") {
                        guard !isSubmitting else { return }; isSubmitting = true
                        Task {
                            defer { isSubmitting = false }
                            do { try await model.addComment(ticketID: ticketID, text: comment); comment = "" } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(isSubmitting)
                }
            } else { ContentUnavailableView("Ticket not found", systemImage: "ticket") }
        }.navigationTitle("Ticket details").errorAlert($error)
    }
}

struct TicketMapView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: UUID?
    var body: some View {
        VStack(spacing: 0) {
            Map(selection: $selected) {
                ForEach(model.tickets.filter { $0.status != .closed }) { ticket in
                    if let coordinate = ticket.coordinate { Marker(ticket.title, coordinate: coordinate.clLocation).tag(ticket.id) }
                }
            }
            if let ticket = model.tickets.first(where: { $0.id == selected }) {
                NavigationLink(destination: TicketDetailView(ticketID: ticket.id)) {
                    VStack(alignment: .leading) { Text(ticket.title).font(.headline); Text("\(ticket.room) - \(ticket.priority) - \(ticket.status.rawValue)"); Text("Open ticket details").font(.caption) }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            } else { Text("Select a pin to preview a ticket. Only tickets with an attached location appear.").font(.caption).padding() }
        }.navigationTitle("Ticket map")
    }
}

struct MoreView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmSignOut = false
    var body: some View {
        NavigationStack {
            List {
                NavigationLink(destination: NotificationsView()) { Label("Notifications", systemImage: "bell") }
                NavigationLink(destination: ProfileView()) { Label("Employee profile", systemImage: "person") }
                NavigationLink(destination: SettingsView()) { Label("Settings", systemImage: "gearshape") }
                if model.role == .approver { NavigationLink(destination: LeaveApprovalsView()) { Label("Leave approvals", systemImage: "checkmark.seal") } }
                if model.isRemoteSession && (model.role == .approver || model.role == .support) {
                    NavigationLink(destination: FingerprintMachineView()) { Label("Fingerprint machine", systemImage: "touchid") }
                }
                Section { Button("Sign out", role: .destructive) { confirmSignOut = true } }
                Text(model.isRemoteSession ? "MySQL backend - \(model.role.rawValue)" : "Local demo - \(model.role.rawValue). Sign out to choose another demo role.").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("More")
                .confirmationDialog("Sign out of NIBM ONE?", isPresented: $confirmSignOut, titleVisibility: .visible) { Button("Sign out", role: .destructive) { model.signOut() } }
        }
    }
}

struct NotificationsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            Section { Text("Activity history. Remote push delivery is not connected.").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.notices) { notice in
                NavigationLink {
                    NoticeDetailView(destination: notice.destination).task { await model.markRead(notice.id) }
                } label: {
                    HStack { if !notice.isRead { Circle().fill(Color.nibmBlue).frame(width: 8, height: 8).accessibilityLabel("Unread") }; VStack(alignment: .leading) { Text(notice.title); Text(notice.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) } }
                }
            }
        }.navigationTitle("Notifications").refreshable { await model.refreshRemote() }.task { await model.refreshRemote() }
    }
}

struct NoticeDetailView: View {
    let destination: NoticeDestination
    var body: some View {
        switch destination {
        case .attendance: PunchRecordsView()
        case .leave(let id): LeaveDetailView(requestID: id)
        case .ticket(let id): TicketDetailView(ticketID: id)
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form { Section { LabeledContent("Name", value: model.employeeName); LabeledContent("EPF No.", value: model.epfNo); LabeledContent("Branch", value: model.branch); LabeledContent("Role", value: model.role.rawValue) } }.navigationTitle("Employee profile")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var error: String?
    var body: some View {
        Form {
            Section("Security") {
                Toggle("Face ID / device passcode app lock", isOn: Binding(get: { model.appLockEnabled }, set: { enabled in
                    Task { do { try await model.configureAppLock(enabled: enabled) } catch { self.error = error.localizedDescription } }
                })).disabled(model.isAuthenticating)
                Text("When enabled, returning after the app enters the background requires device authentication. Sign out disables app lock for this demo session.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Preferences") {
                NavigationLink("Notifications", destination: NotificationSettingsView())
                NavigationLink("Accessibility", destination: AccessibilitySettingsView())
                NavigationLink("Home Screen widget", destination: IntegrationStatusView())
            }
        }.navigationTitle("Settings").errorAlert($error)
    }
}

struct AccessibilitySettingsView: View {
    var body: some View {
        List {
            Text("Text follows your iPhone's Text Size and Larger Text settings. VoiceOver reads control names and attendance status labels.")
            if let url = URL(string: UIApplication.openSettingsURLString) { Link("Open iPhone Settings", destination: url) }
        }.navigationTitle("Accessibility")
    }
}

struct IntegrationStatusView: View {
    var body: some View {
        List {
            Section("NIBM ONE summary") {
                Label("Attendance, leave and tickets", systemImage: "square.grid.2x2")
                Text("Touch and hold the Home Screen, choose Edit > Add Widget, then search for NIBM ONE. Small shows today’s IN/OUT; Medium also shows pending leave and open tickets.")
                Text("Sign in and refresh the app to update the widget. Tap a summary to open its tab. Times use the first and last punches of the day in Sri Lanka time.")
                Text("This is a cached summary. iOS schedules widget refreshes. The summary is cleared on sign out and app relaunch, and expires after eight hours or at midnight.")
            }
            Section("Sharing configuration") {
                Label(WidgetSummaryStore.isAvailable ? "Shared widget storage is available" : "App Group needs configuration in Xcode",
                      systemImage: WidgetSummaryStore.isAvailable ? "checkmark.circle" : "exclamationmark.triangle")
                Text("App and widget must use the same App Group and signing team. No password, session token or MySQL connection is shared with the widget.")
            }
        }.navigationTitle("Home Screen widget")
    }
}

struct DocumentAttachmentPicker: View {
    @Binding var attachment: Attachment?
    @State private var showImporter = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading) {
            Button("Choose supporting document") { showImporter = true }
            if let attachment { Text(attachment.name).font(.caption); Button("Remove document", role: .destructive) { self.attachment = nil } }
        }.fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 8_000_000 else { throw FormError.invalid("Choose a document smaller than 8 MB.") }
                let data = try Data(contentsOf: url)
                guard data.count <= 8_000_000 else { throw FormError.invalid("Choose a document smaller than 8 MB.") }
                attachment = Attachment(name: url.lastPathComponent, data: data)
            } catch { self.error = error.localizedDescription }
        }.errorAlert($error)
    }
}

struct AttachmentPreview: View {
    let attachment: Attachment
    @State private var fileURL: URL?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading) {
            if let image = UIImage(data: attachment.data) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220).accessibilityLabel(attachment.name) }
            Text(attachment.name)
            if let fileURL { ShareLink("Open or share attachment", item: fileURL) }
        }.task(id: attachment.id) {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(attachment.id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(URL(fileURLWithPath: attachment.name).lastPathComponent)
                try attachment.data.write(to: url, options: [.atomic, .completeFileProtection]); fileURL = url
            } catch { self.error = error.localizedDescription }
        }.errorAlert($error)
    }
}

struct AttendanceRow: View {
    let day: AttendanceDay
    var body: some View { HStack { Text(AttendanceCalendarRules.shortDate(day.date)).font(.caption).frame(width: 75, alignment: .leading); VStack(alignment: .leading) { Text("IN \(day.firstIn)"); Text("OUT \(day.lastOut)").font(.caption).foregroundStyle(.secondary) }.monospacedDigit(); Spacer(); StatusPill(text: day.status.rawValue, color: day.status.color) } }
}
struct AttendanceDayCard: View {
    let day: AttendanceDay
    private var today: Bool { AttendanceCalendarRules.calendar.isDateInToday(day.date) }
    private var tint: Color { day.status == .noRecord ? Color.white.opacity(0.25) : day.status.color }
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 1) {
                Text("\(AttendanceCalendarRules.calendar.component(.day, from: day.date))")
                    .font(.system(size: 12, weight: .bold)).frame(width: 22, height: 22)
                    .background(today ? Color.blue : Color.clear).clipShape(Circle())
                Spacer(minLength: 0)
                Circle().fill(tint).frame(width: 5, height: 5)
            }
            Spacer(minLength: 2)
            VStack(spacing: 2) {
                Text(day.firstIn).fontWeight(.bold)
                Text(day.lastOut).foregroundStyle(.white.opacity(day.summary.lastOut == nil ? 0.38 : 0.9))
            }.font(.system(size: 10.5, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(day.status == .noRecord ? "No record" : day.punches.isEmpty ? day.status.rawValue : "\(day.punches.count) punches")
                .font(.system(size: 7)).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(.white.opacity(0.6))
        }.foregroundStyle(.white).padding(5).frame(maxWidth: .infinity, minHeight: 90)
            .background(tint.opacity(day.status == .noRecord ? 0.05 : 0.11))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(today ? Color.blue : tint.opacity(0.65), lineWidth: today ? 1.7 : 1))
            .accessibilityElement(children: .ignore).accessibilityLabel("\(AttendanceCalendarRules.dayTitle(day.date)), \(day.status.rawValue), IN \(day.firstIn), OUT \(day.lastOut), \(day.punches.count) punches")
    }
}
struct Metric: View { let title: String; let value: String; var body: some View { VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline) }.frame(maxWidth: .infinity, alignment: .leading) } }
struct QuickAction: View { let title: String; let icon: String; var body: some View { VStack(spacing: 8) { Image(systemName: icon).font(.title2); Text(title).font(.caption).multilineTextAlignment(.center) }.frame(maxWidth: .infinity, minHeight: 64).padding(.vertical, 12).background(.white).clipShape(RoundedRectangle(cornerRadius: 14)) } }
struct StatusPill: View { let text: String; let color: Color; var body: some View { Text(text).font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.14)).foregroundStyle(color).clipShape(Capsule()) } }
struct PrimaryButtonStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.frame(maxWidth: .infinity).padding().background(Color.nibmBlue).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 12)).opacity(configuration.isPressed ? 0.8 : 1) } }
struct ErrorAlert: ViewModifier {
    @Binding var message: String?
    func body(content: Content) -> some View {
        content.alert("Unable to complete", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }
}
extension View {
    func cardStyle() -> some View { padding().background(.white).clipShape(RoundedRectangle(cornerRadius: 18)) }
    func errorAlert(_ message: Binding<String?>) -> some View { modifier(ErrorAlert(message: message)) }
}
extension AttendanceStatus {
    var color: Color {
        switch self {
        case .present: return .green
        case .late, .halfDay, .missingPunch: return .orange
        case .absent, .noPay: return .red
        case .leave: return .blue
        case .offDay, .holiday: return .purple
        case .noRecord: return .gray
        }
    }
}
extension RequestStatus { var color: Color { switch self { case .approved: return .green; case .pending: return .orange; case .rejected: return .red } } }
extension Coordinate { var clLocation: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) } }
extension Color { static let nibmBlue = Color(red: 0.06, green: 0.31, blue: 0.62); static let nibmNavy = Color(red: 0.03, green: 0.10, blue: 0.22); static let nibmBackground = Color(red: 0.95, green: 0.97, blue: 0.99) }
