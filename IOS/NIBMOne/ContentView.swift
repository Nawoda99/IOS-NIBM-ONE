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
                    Image("NIBMOneMark").resizable().scaledToFit().frame(width: 100, height: 100).accessibilityHidden(true)
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
    @State private var showPassword = false
    @State private var showConnectionSettings = false
    @FocusState private var focusedField: Field?
    @AppStorage("useMySQLBackend") private var useServer = AppConfiguration.current.useMySQLBackend
    @AppStorage("backendURL") private var serverURL = AppConfiguration.current.apiBaseURL
    private enum Field: Hashable { case epf, password }
    private let accent = Color(red: 0.02, green: 0.39, blue: 0.94)
    private var canSignIn: Bool {
        !epfNo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty && !model.isLoading
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: geometry.size.height < 700 ? 20 : 28) {
                        brandHeader(compact: geometry.size.height < 700)
                        signInCard
                        VStack(spacing: 4) {
                            if !useServer {
                                Label("Demo mode", systemImage: "person.crop.circle.badge.questionmark")
                                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
                            }
                            Button { focusedField = nil; showConnectionSettings = true } label: {
                                Label("Connection settings", systemImage: "gearshape")
                                    .font(.footnote).frame(minHeight: 44)
                            }.foregroundStyle(.secondary).disabled(model.isLoading)
                        }
                    }
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: max(0, geometry.size.height - 56))
                    .padding(.horizontal, 24).padding(.vertical, 28)
                }
                .scrollDismissesKeyboard(.interactively)
                .background {
                    ZStack(alignment: .topTrailing) {
                        LinearGradient(colors: [Color(red: 0.94, green: 0.97, blue: 1), .white], startPoint: .top, endPoint: .bottom)
                        Circle().fill(Color.cyan.opacity(0.08)).frame(width: 270, height: 270)
                            .blur(radius: 42).offset(x: 105, y: -90)
                    }.ignoresSafeArea()
                }
                .toolbar(.hidden, for: .navigationBar)
            }
            .sheet(isPresented: $showConnectionSettings) { connectionSettings }
        }.errorAlert($error)
    }

    private func brandHeader(compact: Bool) -> some View {
        VStack(spacing: 10) {
            Image("NIBMOneMark")
                .resizable().scaledToFit().frame(width: compact ? 76 : 100, height: compact ? 76 : 100)
                .shadow(color: accent.opacity(0.12), radius: 18, y: 8)
                .accessibilityHidden(true)
            Text("NIBM ONE").font(.title.weight(.heavy)).tracking(1.2).foregroundStyle(Color.nibmNavy)
            Text("Your workday, all in one place.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome back").font(.title2.bold()).foregroundStyle(Color.nibmNavy)
                Text("Sign in with your employee account.").font(.subheadline).foregroundStyle(.secondary)
            }
            fieldShell(title: "EPF number", icon: "person.crop.square", field: .epf) {
                TextField("Enter EPF number", text: $epfNo)
                    .keyboardType(.numberPad).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focusedField, equals: .epf).accessibilityLabel("EPF number")
            }
            VStack(alignment: .trailing, spacing: 4) {
                fieldShell(title: "Password", icon: "lock", field: .password) {
                    Group {
                        if showPassword { TextField("Enter password", text: $password) }
                        else { SecureField("Enter password", text: $password) }
                    }
                    .textContentType(.password).keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go).onSubmit(signIn).accessibilityLabel("Password")
                    Button {
                        showPassword.toggle(); focusedField = .password
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }
                NavigationLink(destination: ResetPasswordView()) {
                    Text("Forgot password?").font(.footnote.weight(.medium)).frame(minHeight: 44)
                }.foregroundStyle(accent)
            }
            Button(action: signIn) {
                HStack(spacing: 10) {
                    if model.isLoading { ProgressView().tint(.white) }
                    Text(model.isLoading ? "Signing in…" : "Sign in").font(.headline)
                    if !model.isLoading { Image(systemName: "arrow.right").font(.subheadline.weight(.semibold)) }
                }
                .frame(maxWidth: .infinity).frame(minHeight: 54)
                .foregroundStyle(.white)
                .background(LinearGradient(colors: [accent, Color(red: 0.02, green: 0.25, blue: 0.78)], startPoint: .leading, endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .opacity(canSignIn ? 1 : 0.55)
            }.buttonStyle(.plain).disabled(!canSignIn)
        }
        .padding(20)
        .background(.white, in: RoundedRectangle(cornerRadius: 26))
        .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(Color(red: 0.89, green: 0.93, blue: 0.98), lineWidth: 1) }
        .shadow(color: Color.nibmNavy.opacity(0.06), radius: 24, y: 12)
        .disabled(model.isLoading)
    }

    private func fieldShell<Content: View>(title: String, icon: String, field: Field, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Color.nibmNavy)
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(accent).frame(width: 20).accessibilityHidden(true)
                content()
            }
            .font(.body).foregroundStyle(Color.nibmNavy)
            .padding(.leading, 15).padding(.trailing, field == .password ? 4 : 15)
            .frame(minHeight: 54)
            .background(Color(red: 0.97, green: 0.98, blue: 1), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(focusedField == field ? accent : Color(red: 0.87, green: 0.91, blue: 0.96), lineWidth: focusedField == field ? 1.5 : 1)
            }
        }
    }

    private var connectionSettings: some View {
        NavigationStack {
            Form {
                Section("Data source") {
                    Toggle("Connect to server", isOn: $useServer)
                    if useServer {
                        TextField("Server URL", text: $serverURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let issue = AppConfiguration.loadIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                        Text("Use your server’s LAN address on an iPhone. Use localhost only when the server runs on the simulator’s Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Demo role", selection: $role) {
                            ForEach(EmployeeRole.allCases.filter { $0 != .administrator }) { Text($0.rawValue).tag($0) }
                        }
                        Button("Use demo account") {
                            epfNo = "900001"; password = "Demo@123"; error = nil; showPassword = false
                            showConnectionSettings = false
                        }
                        Text("Demo data stays on this device. Use the server and your registered EPF for employee records.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Connection settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showConnectionSettings = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func signIn() {
        guard canSignIn else { return }
        focusedField = nil; error = nil
        Task {
            do {
                try await model.signIn(epfNo: epfNo.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
                                       role: role, useServer: useServer, serverURL: serverURL)
            } catch { self.error = error.localizedDescription }
        }
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
        }.navigationTitle("Reset password").toolbar(.visible, for: .navigationBar).errorAlert($error)
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
            if model.can("attendance.view") { AttendanceView().tabItem { Label("Attendance", systemImage: "calendar") }.tag(1) }
            if model.can("leave.view") { LeaveView().tabItem { Label("Leave", systemImage: "doc.text.fill") }.tag(2) }
            if model.can("tickets.view") { TicketsView().tabItem { Label("Tickets", systemImage: "wrench.and.screwdriver.fill") }.tag(3) }
            MoreView().tabItem { Label("More", systemImage: "ellipsis.circle.fill") }.tag(4)
        }.tint(.nibmBlue)
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    private let accent = Color(red: 0.02, green: 0.39, blue: 0.94)
    private var today: AttendanceDay? {
        model.attendance.first { AttendanceCalendarRules.calendar.isDate($0.date, inSameDayAs: Date()) }
    }
    private var unreadCount: Int { model.notices.filter { !$0.isRead }.count }
    private var pendingLeave: Int { model.leaveRequests.filter { $0.status == .pending }.count }
    private var openTickets: Int { model.tickets.filter { $0.status != .closed && $0.status != .resolved }.count }
    private var attendanceDescription: String {
        guard let today, !today.punches.isEmpty else {
            return model.isLoading ? "Checking today’s records…" : "No punches recorded for today."
        }
        return today.summary.lastOut == nil ? "One punch recorded · OUT pending" : "Recorded span \(today.worked) · includes breaks"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    dashboardHeader
                    attendanceHero
                    if let error = model.storageError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.red).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    }
                    HStack(alignment: .top, spacing: 10) {
                        if model.can("leave.apply") { NavigationLink(destination: ApplyLeaveView().toolbar(.visible, for: .navigationBar)) {
                            QuickAction(title: "Apply leave", icon: "doc.badge.plus", tint: accent)
                        } }
                        if model.can("tickets.create") { NavigationLink(destination: CreateTicketView().toolbar(.visible, for: .navigationBar)) {
                            QuickAction(title: "Create ticket", icon: "plus.circle", tint: .teal)
                        }
                        NavigationLink(destination: ScanToTicketView().toolbar(.visible, for: .navigationBar)) {
                            QuickAction(title: "Scan QR", icon: "qrcode.viewfinder", tint: .indigo)
                        } }
                    }
                    .buttonStyle(.plain)
                    if model.can("vehicles.request") || model.can("vehicles.recommend") || model.can("vehicles.manage") {
                        NavigationLink(destination: VehicleRequestsView().toolbar(.visible, for: .navigationBar)) {
                            HStack {
                                Label("Vehicle requests", systemImage: "car.side.fill").font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.bold))
                            }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain)
                    }
                    if model.can("attendance.view") { AttendanceCalendar() }
                    if model.can("leave.view") || model.can("tickets.view") { overview }
                    NavigationLink(destination: NotificationsView().toolbar(.visible, for: .navigationBar)) {
                        HStack(spacing: 14) {
                            Image(systemName: "bell").foregroundStyle(accent).frame(width: 42, height: 42)
                                .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Your updates").font(.subheadline.weight(.semibold)).foregroundStyle(Color.nibmNavy)
                                Text(unreadCount == 0 ? "You’re all caught up" : "\(unreadCount) unread notifications")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .background(LinearGradient(colors: [Color(red: 0.94, green: 0.97, blue: 1), Color(red: 0.97, green: 0.98, blue: 1)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.refreshRemote() }
            .task { await model.refreshRemote() }
        }
    }

    private var dashboardHeader: some View {
        HStack(spacing: 10) {
            Image("NIBMOneMark").resizable().scaledToFit().frame(width: 40, height: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("NIBM ONE").font(.headline.weight(.heavy)).tracking(0.6).foregroundStyle(Color.nibmNavy)
                Text(model.isRemoteSession ? "Employee dashboard" : "Demo dashboard").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            NavigationLink(destination: NotificationsView().toolbar(.visible, for: .navigationBar)) {
                Image(systemName: "bell").font(.body.weight(.medium)).frame(width: 44, height: 44)
                    .background(.white, in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if unreadCount > 0 {
                            Circle().fill(Color.red).frame(width: 8, height: 8).overlay(Circle().stroke(.white, lineWidth: 2)).padding(8)
                        }
                    }
            }.accessibilityLabel("Notifications, \(unreadCount) unread")
            NavigationLink(destination: ProfileView().toolbar(.visible, for: .navigationBar)) {
                Image(systemName: "person.crop.circle.fill").font(.title2).frame(width: 44, height: 44)
                    .background(.white, in: Circle())
            }.accessibilityLabel("Employee profile")
        }.foregroundStyle(accent).buttonStyle(.plain)
    }

    private var attendanceHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Welcome back").font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 8)
                    Text(today?.status.rawValue ?? "No record").font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 5).background(.white.opacity(0.13), in: Capsule())
                }
                Text(model.employeeName).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("EPF \(model.epfNo)")
                    Circle().fill(.white.opacity(0.45)).frame(width: 3, height: 3)
                    Text(model.role.rawValue)
                }.font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            if model.can("attendance.view") {
            Divider().overlay(.white.opacity(0.18))
            HStack {
                Text("Today’s attendance").font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text(AttendanceCalendarRules.shortDate(Date())).font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            HStack(spacing: 18) {
                attendanceTime("First IN", value: today?.firstIn ?? "--:--", icon: "arrow.down.left", tint: Color(red: 0.38, green: 0.95, blue: 0.81))
                Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 44)
                attendanceTime("Last OUT", value: today?.lastOut ?? "--:--", icon: "arrow.up.right", tint: Color(red: 0.61, green: 0.82, blue: 1))
            }
            if let today {
                NavigationLink(destination: DayDetailsView(day: today).toolbar(.visible, for: .navigationBar)) {
                    HStack(spacing: 8) {
                        Text(attendanceDescription).font(.caption)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }.foregroundStyle(.white.opacity(0.8)).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                Label(attendanceDescription, systemImage: "clock")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            }
        }
        .foregroundStyle(.white).padding(20)
        .background(LinearGradient(colors: [Color(red: 0.03, green: 0.18, blue: 0.43), Color(red: 0.02, green: 0.36, blue: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: accent.opacity(0.15), radius: 18, y: 9)
    }

    private func attendanceTime(_ title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(tint)
            Text(value).font(.title.weight(.bold)).monospacedDigit().foregroundStyle(.white.opacity(value == "--:--" ? 0.6 : 1))
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("At a glance").font(.title3.bold()).foregroundStyle(Color.nibmNavy)
            HStack(spacing: 12) {
                if model.can("leave.view") { Button { model.selectedTab = 2 } label: {
                    overviewTile("Pending leave", value: pendingLeave, icon: "doc.text", tint: accent)
                } }
                if model.can("tickets.view") { Button { model.selectedTab = 3 } label: {
                    overviewTile("Open tickets", value: openTickets, icon: "wrench.and.screwdriver", tint: .teal)
                } }
            }.buttonStyle(.plain)
            if model.can("leave.view") { Button { model.selectedTab = 2 } label: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.checkmark").foregroundStyle(accent)
                    Text("Available leave").font(.subheadline).foregroundStyle(Color.nibmNavy)
                    Spacer(minLength: 4)
                    Text("\(LeaveType.allCases.reduce(0) { $0 + model.balance(for: $1) }.formatted()) days")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                }.padding(18).frame(minHeight: 54).background(.white, in: RoundedRectangle(cornerRadius: 18))
            }.buttonStyle(.plain) }
        }
    }

    private func overviewTile(_ title: String, value: Int, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.headline).foregroundStyle(tint)
            Text(value.formatted()).font(.title.bold()).foregroundStyle(Color.nibmNavy)
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(.white, in: RoundedRectangle(cornerRadius: 20))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate: Date?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private var selectedDay: AttendanceDay? {
        guard let selectedDate, AttendanceCalendarRules.sameMonth(selectedDate, model.attendanceMonth) else { return nil }
        return day(for: selectedDate)
    }
    private var syncLabel: String {
        if !model.isRemoteSession { return "Demo" }
        if model.attendanceError != nil { return model.attendanceUpdatedAt == nil ? "Unavailable" : "Cached" }
        return model.attendanceUpdatedAt == nil ? "Waiting" : "Synced"
    }
    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "calendar").font(.headline).foregroundStyle(Color.nibmBlue)
                        .frame(width: 36, height: 36).background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
                    Text("Attendance").font(.title3.bold()).foregroundStyle(Color.nibmNavy)
                    Spacer(minLength: 0)
                    Text(syncLabel).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color.nibmBlue.opacity(0.05), in: Capsule())
                }
                AttendanceMonthControls(dark: false)
                HStack {
                    Text("First IN above · Last OUT below").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await model.refreshAttendanceMonth() } } label: {
                        Group {
                            if model.isAttendanceLoading { ProgressView() }
                            else { Image(systemName: "arrow.clockwise").font(.subheadline.weight(.semibold)) }
                        }.frame(width: 44, height: 44)
                    }.foregroundStyle(Color.nibmBlue).accessibilityLabel("Refresh attendance").disabled(model.isAttendanceLoading)
                }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(weekdays, id: \.self) { value in
                        Text(value).font(.caption2.weight(.semibold))
                            .foregroundStyle(value == "Sat" || value == "Sun" ? Color.nibmBlue : Color.secondary).padding(.bottom, 5)
                    }
                    ForEach(0..<AttendanceCalendarRules.leadingDays(in: model.attendanceMonth), id: \.self) { _ in Color.clear.frame(height: 80) }
                    ForEach(AttendanceCalendarRules.dates(in: model.attendanceMonth), id: \.self) { date in
                        let record = day(for: date)
                        let selected = selectedDate.map { AttendanceCalendarRules.calendar.isDate($0, inSameDayAs: date) } ?? false
                        Button {
                            if reduceMotion { selectedDate = date }
                            else { withAnimation(.easeInOut(duration: 0.18)) { selectedDate = date } }
                        } label: { AttendanceDayCard(day: record, selected: selected) }
                            .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityHint("Select to see the day summary and open punch details")
                    }
                }
                HStack(spacing: 12) {
                    legend("Complete", color: .green)
                    legend("OUT pending", color: .orange)
                    legend("Leave", color: .blue)
                }.padding(.top, 2)
                if let selectedDay { selectedDayPreview(selectedDay) }
                else { Text("Tap a date to explore your punches.").font(.caption).foregroundStyle(.secondary) }
                if let error = model.attendanceError {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                }
                if model.calendarAttendance.isEmpty && !model.isAttendanceLoading {
                    Text(model.isRemoteSession ? "No attendance records this month." : "No demo records this month.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider().overlay(Color.nibmBlue.opacity(0.04))
                HStack {
                    Text("EPF \(model.epfNo)")
                    Spacer()
                    Text(model.attendanceUpdatedAt.map { "Updated \(AttendanceCalendarRules.time($0))" } ?? "Waiting for records")
                }.font(.caption2).foregroundStyle(.secondary)
            }.padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 24))
                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.nibmBlue.opacity(0.07), lineWidth: 1) }
                .shadow(color: Color.nibmNavy.opacity(0.035), radius: 16, y: 6)
            AttendanceMonthlySummary(days: model.calendarAttendance, month: model.attendanceMonth).cardStyle()
        }
        .onChange(of: model.attendanceMonth) { _, _ in selectedDate = nil }
        .task(id: AttendanceCalendarRules.monthKey(model.attendanceMonth) + (scenePhase == .active ? "-active" : "-inactive")) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if !model.isLocked { await model.refreshAttendanceMonth() }
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }

    private func day(for date: Date) -> AttendanceDay {
        model.calendarAttendance.first { AttendanceCalendarRules.calendar.isDate($0.date, inSameDayAs: date) }
            ?? AttendanceDay(date: date, status: .noRecord, punches: [])
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 5, height: 5); Text(title).font(.caption2) }.foregroundStyle(.secondary)
    }
    private func selectedDayPreview(_ day: AttendanceDay) -> some View {
        NavigationLink(destination: DayDetailsView(day: day)) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(AttendanceCalendarRules.shortDate(day.date)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.nibmNavy)
                        Circle().fill(day.status.color).frame(width: 5, height: 5)
                        Text(day.status.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("IN  \(day.firstIn)     OUT  \(day.lastOut)").font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(Color.nibmBlue)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold)).foregroundStyle(Color.nibmBlue)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.nibmBlue.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityHint("Open full punch history")
    }
}

struct AttendanceMonthControls: View {
    @EnvironmentObject private var model: AppModel
    let dark: Bool
    var body: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AttendanceCalendarRules.monthTitle(model.attendanceMonth)).font(.title3.bold())
                if !AttendanceCalendarRules.sameMonth(model.attendanceMonth, Date()) {
                    Button("This month") { model.showCurrentAttendanceMonth() }.font(.caption)
                }
            }
            Spacer(minLength: 0)
            Button { model.moveAttendanceMonth(by: -1) } label: { Image(systemName: "chevron.left").font(.subheadline.weight(.bold)).frame(width: 44, height: 44).background(Color.blue.opacity(dark ? 0.18 : 0.06)).clipShape(RoundedRectangle(cornerRadius: 14)) }
                .accessibilityLabel("Previous month")
            Button { model.moveAttendanceMonth(by: 1) } label: { Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).frame(width: 44, height: 44).background(Color.blue.opacity(dark ? 0.18 : 0.06)).clipShape(RoundedRectangle(cornerRadius: 14)) }
                .accessibilityLabel("Next month")
        }.buttonStyle(.plain).foregroundStyle(dark ? Color.white : Color.nibmBlue)
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
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                summaryTile("Complete days", value: present, color: .green, icon: "checkmark.circle")
                summaryTile("OUT pending", value: partial, color: .orange, icon: "clock")
                summaryTile("Approved leave", value: leave, color: .blue, icon: "calendar")
                summaryTile("No record", value: missing, color: .gray, icon: "minus.circle")
            }
            Divider()
            let minutes = days.reduce(0) { $0 + $1.summary.workedMinutes }
            HStack {
                Label("Recorded span", systemImage: "clock").foregroundStyle(.secondary)
                Spacer()
                Text("\(minutes / 60)h \(minutes % 60)m").fontWeight(.bold).monospacedDigit().foregroundStyle(Color.nibmNavy)
            }.font(.subheadline)
            Text("First punch is IN; last distinct punch is OUT. Time span includes breaks. No record does not mean absent.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func summaryTile(_ title: String, value: Int, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Spacer(minLength: 0)
                Text(value.formatted()).font(.title2.bold()).monospacedDigit().foregroundStyle(Color.nibmNavy)
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
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
        }.navigationTitle(AttendanceCalendarRules.dayTitle(day.date)).toolbar(.visible, for: .navigationBar)
    }
}

struct LeaveView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = "All"
    var body: some View {
        NavigationStack {
            List {
                if model.can("leave.apply") {
                    Section {
                        NavigationLink(destination: ApplyLeaveView()) {
                            Label("Apply for leave", systemImage: "plus.circle.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                        }.buttonStyle(.borderedProminent).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                }
                Section("Available balance (pending days reserved)") {
                    ForEach(LeaveType.allCases) { type in LabeledContent(type.rawValue, value: "\(model.balance(for: type).formatted()) days") }
                }
                Section("Request history") {
                    Picker("Status", selection: $filter) { Text("All").tag("All"); ForEach(RequestStatus.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) } }
                    if model.leaveRequests.filter({ filter == "All" || $0.status.rawValue == filter }).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("No leave requests", systemImage: "doc.text.magnifyingglass").font(.headline)
                            Text(model.can("leave.apply") ? "Use Apply for leave above to create a request, or choose a different status." : "No requests match the selected status.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 10)
                    }
                    ForEach(model.leaveRequests.filter { filter == "All" || $0.status.rawValue == filter }) { request in
                        NavigationLink(destination: LeaveDetailView(requestID: request.id)) {
                            HStack { VStack(alignment: .leading) { Text(request.type.rawValue).font(.headline); Text(request.dates).font(.caption) }; Spacer(); StatusPill(text: request.status.rawValue, color: request.status.color) }
                        }
                    }
                }
            }.navigationTitle("Leave").navigationBarTitleDisplayMode(.inline).tint(.nibmBlue).refreshable { await model.refreshRemote() }.task { await model.refreshRemote() }
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
                DatePicker("From", selection: $start, displayedComponents: .date)
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
            }.buttonStyle(.borderedProminent).frame(minHeight: 48).disabled(submitted != nil || isSubmitting)
            if isSubmitting { ProgressView("Saving request") }
        }.navigationTitle("Apply for leave").navigationBarTitleDisplayMode(.inline).tint(.nibmBlue).errorAlert($error)
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
                if model.can("leave.approve") && request.status == .pending {
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
                    if model.can("tickets.create") {
                        NavigationLink(destination: CreateTicketView()) { Label("Create ticket", systemImage: "plus.circle.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 48) }.buttonStyle(.borderedProminent)
                        NavigationLink(destination: ScanToTicketView()) { Label("Scan room / asset QR", systemImage: "qrcode.viewfinder").frame(minHeight: 44) }.foregroundStyle(Color.nibmBlue)
                    }
                    if model.can("map.view") { NavigationLink(destination: TicketMapView()) { Label("Branches and ticket map", systemImage: "map").frame(minHeight: 44) }.foregroundStyle(Color.nibmBlue) }
                    Picker("Status", selection: $filter) { Text("All").tag("All"); ForEach(TicketStatus.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                }
                Section("My tickets") {
                    if filtered.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("No service requests", systemImage: "tray").font(.headline)
                            Text(model.can("tickets.create") ? "Create a ticket using the blue button above, or change your filters." : "No requests match the selected filters.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }
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
            }.searchable(text: $search, prompt: "Number, title, room or asset").navigationTitle("Service requests").navigationBarTitleDisplayMode(.inline).tint(.nibmBlue)
                .refreshable { await model.refreshRemote() }.task { await model.refreshRemote() }
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
            }.buttonStyle(.borderedProminent).frame(minHeight: 48).disabled(isLoadingPhoto || isSubmitting || submitted != nil)
            if isSubmitting { ProgressView("Saving ticket") }
        }.navigationTitle("Create ticket").navigationBarTitleDisplayMode(.inline).tint(.nibmBlue).errorAlert($error)
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
                    if model.can("tickets.manage") && ticket.status != .closed {
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
    var body: some View { BranchTicketMapView() }
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
                if model.can("vehicles.request") || model.can("vehicles.recommend") || model.can("vehicles.manage") {
                    NavigationLink(destination: VehicleRequestsView()) { Label("Vehicle requests", systemImage: "car.side.fill") }
                }
                if model.isRemoteSession {
                    NavigationLink(destination: DriverModeView()) { Label("Driver mode", systemImage: "steeringwheel") }
                }
                if model.isRemoteSession && model.can("vehicles.manage") {
                    NavigationLink(destination: CompanyVehiclesView()) { Label("Company vehicles", systemImage: "car.2.fill") }
                }
                if model.can("map.view") { NavigationLink(destination: TicketMapView()) { Label("Branches and my location", systemImage: "map") } }
                if model.can("leave.approve") { NavigationLink(destination: LeaveApprovalsView()) { Label("Leave approvals", systemImage: "checkmark.seal") } }
                if model.isRemoteSession && model.can("machines.manage") {
                    NavigationLink(destination: FingerprintMachineView()) { Label("Fingerprint machine", systemImage: "touchid") }
                }
                if model.isRemoteSession && model.role == .administrator {
                    Section("Administration") {
                        NavigationLink(destination: EmployeeAccountsView()) { Label("Employee accounts", systemImage: "person.badge.plus") }
                        NavigationLink(destination: RolePermissionsView()) { Label("Roles and permissions", systemImage: "lock.shield") }
                        NavigationLink(destination: BranchLocationsView()) { Label("Manage branch pins", systemImage: "mappin.and.ellipse") }
                    }
                }
                Section { Button(role: .destructive) { confirmSignOut = true } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right").frame(minHeight: 44) } }
                Text("\(model.role.rawValue) · \(model.isRemoteSession ? "Employee account" : "Local demo")").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("More").navigationBarTitleDisplayMode(.inline).tint(.nibmBlue).task { await model.refreshRemote() }
                .alert("Sign out of NIBM ONE?", isPresented: $confirmSignOut) {
                    Button("Cancel", role: .cancel) { }
                    Button("Sign out", role: .destructive) { model.signOut() }
                }
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
    private var details: EmployeeProfileDetails { model.employeeDetails }
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image("NIBMOneMark").resizable().scaledToFit().frame(width: 54, height: 54)
                    Text(model.employeeName).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("EPF \(model.epfNo)").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            Section("Personal information") {
                ProfileDetailRow("Full name", value: model.employeeName)
                ProfileDetailRow("Title", value: details.title)
                ProfileDetailRow("First name", value: details.firstName)
                ProfileDetailRow("Last name", value: details.lastName)
                ProfileDetailRow("Initials", value: details.initials)
                ProfileDetailRow("Gender", value: details.gender)
                ProfileDetailRow("Identity number", value: details.identityNumber)
                ProfileDetailRow("Passport number", value: details.passportNumber)
            }
            Section("Employment information") {
                ProfileDetailRow("EPF number", value: model.epfNo)
                ProfileDetailRow("Previous EPF number", value: details.previousEPFNumber)
                ProfileDetailRow("ERP employee ID", value: details.erpEmployeeID)
                ProfileDetailRow("Branch", value: model.branch)
                ProfileDetailRow("Department", value: details.department)
                ProfileDetailRow("Employment type", value: details.employmentType)
                ProfileDetailRow("Grade", value: details.grade)
                ProfileDetailRow("Employment status", value: details.employmentStatus)
                ProfileDetailRow("Joined date", value: EmployeeProfileDetails.displayDate(details.joinedDate))
                ProfileDetailRow("Appointment date", value: EmployeeProfileDetails.displayDate(details.appointmentDate))
                ProfileDetailRow("Probation end date", value: EmployeeProfileDetails.displayDate(details.probationEndDate))
                ProfileDetailRow("Assignment start date", value: EmployeeProfileDetails.displayDate(details.assignmentStartDate))
                ProfileDetailRow("App role", value: model.role.rawValue)
            }
            Section("Contact information") {
                ProfileDetailRow("Official email", value: details.officialEmail)
                ProfileDetailRow("Personal email", value: details.personalEmail)
                ProfileDetailRow("Mobile number", value: details.primaryMobile)
                ProfileDetailRow("Alternate mobile", value: details.secondaryMobile)
                ProfileDetailRow("Telephone number", value: details.primaryTelephone)
                ProfileDetailRow("Alternate telephone", value: details.secondaryTelephone)
                ProfileDetailRow("Primary address", value: details.primaryAddress)
                ProfileDetailRow("Secondary address", value: details.secondaryAddress)
            }
            Section("Emergency contact") {
                ProfileDetailRow("Contact name", value: details.emergencyContactName)
                ProfileDetailRow("Relationship", value: details.emergencyContactRelationship)
                ProfileDetailRow("Phone number", value: details.emergencyContactPhone)
                ProfileDetailRow("Address", value: details.emergencyContactAddress)
            }
            if !model.isRemoteSession {
                Section { Text("Demo profile. Sign in with your employee account to see your HR information.").font(.caption).foregroundStyle(.secondary) }
            }
            if model.isRemoteSession && model.role == .administrator {
                Section("Administration") { NavigationLink("Manage employee accounts", destination: EmployeeAccountsView()); NavigationLink("Roles and permissions", destination: RolePermissionsView()) }
            }
        }.navigationTitle("Employee profile").navigationBarTitleDisplayMode(.inline).tint(.nibmBlue)
            .refreshable { await model.refreshRemote() }
            .task { await model.refreshRemote() }
    }
}

private struct ProfileDetailRow: View {
    let title: String
    let value: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, value: String?) { self.title = title; self.value = value }

    private var text: String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedContent
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        Text(title).fixedSize()
                        Spacer(minLength: 0)
                        Text(text ?? "Not provided").foregroundStyle(.secondary).fixedSize()
                    }
                    stackedContent
                }
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var stackedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Text(text ?? "Not provided").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Require Face ID, Touch ID or device passcode when returning to the app. Signing out turns off app lock for this session.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Preferences") {
                NavigationLink(destination: NotificationSettingsView()) { Label("Notifications", systemImage: "bell.badge") }
                NavigationLink(destination: AccessibilitySettingsView()) { Label("Accessibility", systemImage: "accessibility") }
                NavigationLink(destination: IntegrationStatusView()) { Label("Home Screen widget", systemImage: "square.grid.2x2") }
            }
        }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline).tint(.nibmBlue).errorAlert($error)
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
    var selected = false
    private var today: Bool { AttendanceCalendarRules.calendar.isDateInToday(day.date) }
    private var tint: Color { day.status == .noRecord ? Color.gray.opacity(0.4) : day.status.color }
    var body: some View {
        VStack(spacing: 5) {
            Text("\(AttendanceCalendarRules.calendar.component(.day, from: day.date))")
                .font(.caption.weight(.semibold)).frame(width: 26, height: 26)
                .foregroundStyle(today ? Color.white : Color.nibmNavy)
                .background(today ? Color.nibmBlue : Color.clear, in: Circle())
            Spacer(minLength: 2)
            if !day.punches.isEmpty {
                VStack(spacing: 3) {
                    Text(day.firstIn).fontWeight(.bold).foregroundStyle(Color.nibmNavy)
                    Text(day.lastOut).foregroundStyle(day.summary.lastOut == nil ? Color.secondary : Color.nibmBlue)
                }.font(.system(size: 11, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            } else {
                Text("—").font(.subheadline).foregroundStyle(Color.secondary.opacity(0.5)).frame(minHeight: 28)
            }
            Circle().fill(day.status == .noRecord ? Color.clear : tint).frame(width: 4, height: 4)
        }.padding(.horizontal, 2).padding(.vertical, 7).frame(maxWidth: .infinity, minHeight: 86)
            .background(selected ? Color.nibmBlue.opacity(0.08) : day.status == .noRecord ? Color(red: 0.97, green: 0.98, blue: 0.99) : tint.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.nibmBlue : today ? Color.nibmBlue.opacity(0.3) : Color.nibmBlue.opacity(0.045), lineWidth: selected ? 1.7 : 1))
            .accessibilityElement(children: .ignore).accessibilityLabel("\(AttendanceCalendarRules.dayTitle(day.date)), \(day.status.rawValue), IN \(day.firstIn), OUT \(day.lastOut), \(day.punches.count) punches")
    }
}
struct Metric: View { let title: String; let value: String; var body: some View { VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline) }.frame(maxWidth: .infinity, alignment: .leading) } }
struct QuickAction: View {
    let title: String
    let icon: String
    var tint: Color = .nibmBlue
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint).frame(width: 44, height: 44)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 13)).accessibilityHidden(true)
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Color.nibmNavy).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 104)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.nibmBlue.opacity(0.06), lineWidth: 1) }
    }
}
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
