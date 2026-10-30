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
                    Text("This build uses local demo records. Institutional services are not connected.").foregroundStyle(.secondary)
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
    @State private var employeeID = ""
    @State private var password = ""
    @State private var role: EmployeeRole = .employee
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "building.2.crop.circle.fill").font(.system(size: 66)).foregroundStyle(Color.nibmBlue)
                    Text("Welcome to\nNIBM ONE").font(.system(size: 36, weight: .bold)).foregroundStyle(Color.nibmNavy)
                    Text("One place for attendance, leave and service requests.").foregroundStyle(.secondary)
                    TextField("Employee ID", text: $employeeID).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password).textContentType(.password).textFieldStyle(.roundedBorder)
                    Picker("Demo role", selection: $role) { ForEach(EmployeeRole.allCases) { Text($0.rawValue).tag($0) } }
                    Button("Sign in") {
                        do { try model.signIn(employeeID: employeeID, password: password, role: role) }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(PrimaryButtonStyle())
                    Text("Demo ID: NIBM-00321\nDemo password: Demo@123\nRoles are for local testing only.").font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
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
            } message: { Text("No email was sent. Use NIBM-00321 and Demo@123 to access this build, or contact your administrator for an institutional password reset.") }
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
                        VStack(alignment: .leading) { Text("Welcome back,").foregroundStyle(.secondary); Text("Alex Perera").font(.title2.bold()) }
                        Spacer()
                        NavigationLink(destination: NotificationsView()) { Label("Notifications", systemImage: "bell.badge").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) }
                    }
                    Label("Local demo data", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    if let error = model.storageError { Text(error).foregroundStyle(.red) }
                    if let today = model.attendance.first(where: { Calendar.current.isDateInToday($0.date) }) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Today's attendance").font(.headline)
                            HStack { Metric(title: "First IN", value: today.firstIn); Metric(title: "Last OUT", value: today.lastOut); Metric(title: "Worked", value: today.worked) }
                            StatusPill(text: today.status.rawValue, color: today.status.color)
                            NavigationLink("View punches", destination: DayDetailsView(day: today))
                        }.cardStyle()
                    } else { Text("No attendance record for today.").cardStyle() }
                    HStack(alignment: .top) {
                        NavigationLink(destination: ApplyLeaveView()) { QuickAction(title: "Apply leave", icon: "doc.badge.plus") }
                        NavigationLink(destination: CreateTicketView()) { QuickAction(title: "Create ticket", icon: "plus.circle") }
                        NavigationLink(destination: ScanToTicketView()) { QuickAction(title: "Scan QR", icon: "qrcode.viewfinder") }
                    }
                    HStack { Text("Attendance calendar").font(.headline); Spacer(); Button("View all") { model.selectedTab = 1 } }
                    AttendanceCalendar(days: model.attendance)
                    HStack {
                        Metric(title: "Available leave", value: "\(LeaveType.allCases.reduce(0) { $0 + model.balance(for: $1) }.formatted()) days")
                        Metric(title: "Pending leave", value: "\(model.leaveRequests.filter { $0.status == .pending }.count)")
                        Metric(title: "Open tickets", value: "\(model.tickets.filter { $0.status != .closed && $0.status != .resolved }.count)")
                    }.cardStyle()
                    NavigationLink("Recent notifications", destination: NotificationsView())
                }.padding()
            }.background(Color.nibmBackground.ignoresSafeArea()).navigationTitle("NIBM ONE")
                .toolbar { NavigationLink(destination: ProfileView()) { Label("Profile", systemImage: "person.crop.circle") } }
        }
    }
}

struct AttendanceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var mode = 0
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Attendance view", selection: $mode) { Text("Records").tag(0); Text("Calendar").tag(1); Text("Summary").tag(2) }.pickerStyle(.segmented)
                    Text("Sample records loaded \(model.sampleLoadedAt.formatted(date: .omitted, time: .shortened)). Live machine sync is not connected.").font(.caption).foregroundStyle(.secondary)
                }
                if mode == 0 {
                    Section(Date().formatted(.dateTime.month(.wide).year())) {
                        ForEach(model.attendance.reversed()) { day in NavigationLink(destination: DayDetailsView(day: day)) { AttendanceRow(day: day) } }
                    }
                } else if mode == 1 {
                    Section("Calendar") { AttendanceCalendar(days: model.attendance) }
                } else {
                    Section("Monthly summary") {
                        ForEach(AttendanceStatus.allCases) { status in
                            LabeledContent(status.rawValue, value: "\(model.attendance.filter { $0.status == status }.count)")
                        }
                        LabeledContent("Paired worked hours", value: "\(model.attendance.reduce(0) { $0 + $1.summary.workedMinutes } / 60)h")
                        Text("Unmatched punches need review. Late arrival, early departure and overtime require institutional rules from the API.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("Attendance").toolbar { NavigationLink(destination: PunchRecordsView()) { Label("Punch records", systemImage: "list.bullet.rectangle") } }
        }
    }
}

struct AttendanceCalendar: View {
    let days: [AttendanceDay]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private var leadingDays: Int {
        guard let first = days.first else { return 0 }
        let calendar = Calendar.current
        return (calendar.component(.weekday, from: first.date) - calendar.firstWeekday + 7) % 7
    }
    private var weekdayLabels: [String] {
        let calendar = Calendar.current
        let labels = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { labels[(calendar.firstWeekday - 1 + $0) % 7] }
    }
    var body: some View {
        VStack(alignment: .leading) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<7, id: \.self) { Text(weekdayLabels[$0]).font(.caption).foregroundStyle(.secondary) }
                ForEach(0..<leadingDays, id: \.self) { _ in Color.clear.frame(height: 44) }
                ForEach(days) { day in NavigationLink(destination: DayDetailsView(day: day)) { AttendanceDayCard(day: day) }.buttonStyle(.plain) }
            }
            Text("Tap a date for IN/OUT times and punch history.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PunchRecordsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            ForEach(model.attendance.reversed().filter { !$0.punches.isEmpty }) { day in
                Section(day.date.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach(day.punches) { punch in
                        HStack {
                            Image(systemName: punch.direction == .inbound ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill").foregroundStyle(punch.direction == .inbound ? Color.green : Color.red)
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
                LabeledContent("Paired worked hours", value: day.worked)
                LabeledContent("First IN", value: day.firstIn); LabeledContent("Last OUT", value: day.lastOut)
                if day.summary.missingPunch { Label("Unmatched punch - review required", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Section("Punch history") {
                if day.punches.isEmpty { Text("No punches recorded for this day.").foregroundStyle(.secondary) }
                ForEach(day.punches) { punch in Text("\(punch.time) - \(punch.direction.rawValue) - \(punch.machine) - \(punch.branch)") }
            }
        }.navigationTitle(day.date.formatted(date: .abbreviated, time: .omitted))
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
            }.navigationTitle("Leave")
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
                do {
                    submitted = try model.submitLeave(type: type, start: start, end: end, halfDay: halfDay, reason: reason, attachment: attachment)
                    showConfirmation = true
                } catch { self.error = error.localizedDescription }
            }.disabled(submitted != nil)
        }.navigationTitle("Apply for leave").errorAlert($error)
            .onChange(of: start) { _, date in if halfDay || end < date { end = date } }
            .onChange(of: halfDay) { _, enabled in if enabled { end = start } }
            .alert("Request submitted", isPresented: $showConfirmation) {
                Button("View details") { showDetails = true }
                Button("Done") { dismiss() }
            } message: { Text("Your demo request is saved with Pending status.") }
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
    var body: some View {
        List {
            if let request = model.leaveRequests.first(where: { $0.id == requestID }) {
                Section("Request") {
                    LabeledContent("Employee", value: "Alex Perera")
                    LabeledContent("Type", value: request.type.rawValue); LabeledContent("Dates", value: request.dates)
                    LabeledContent("Duration", value: "\(request.days.formatted()) days")
                    LabeledContent("Status", value: request.status.rawValue)
                    LabeledContent("Available balance", value: "\(model.balance(for: request.type, date: request.startDate).formatted()) days")
                }
                Section("Reason") { Text(request.reason) }
                if let reason = request.rejectionReason { Section("Rejection reason") { Text(reason) } }
                if let attachment = request.attachment { Section("Supporting document") { AttachmentPreview(attachment: attachment) } }
                if model.role == .approver && request.status == .pending {
                    Section("Demo manager decision") {
                        TextField("Reason required for rejection", text: $rejectionReason, axis: .vertical)
                        Button("Approve") { decide(approve: true) }
                        Button("Reject", role: .destructive) { decide(approve: false) }
                    }
                }
            } else { ContentUnavailableView("Request not found", systemImage: "doc.questionmark") }
        }.navigationTitle("Leave details").errorAlert($error)
            .alert("Decision recorded", isPresented: $decisionRecorded) { Button("OK", role: .cancel) {} }
    }
    private func decide(approve: Bool) {
        do { try model.decideLeave(id: requestID, approve: approve, reason: rejectionReason); decisionRecorded = true }
        catch { self.error = error.localizedDescription }
    }
}

struct LeaveApprovalsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            if model.leaveRequests.filter({ $0.status == .pending }).isEmpty { Text("No pending requests.") }
            ForEach(model.leaveRequests.filter { $0.status == .pending }) { request in
                NavigationLink(destination: LeaveDetailView(requestID: request.id)) { VStack(alignment: .leading) { Text("Alex Perera - \(request.type.rawValue)"); Text(request.dates).font(.caption) } }
            }
        }.navigationTitle("Leave approvals")
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
                do {
                    submitted = try model.submitTicket(title: title, description: description, category: category, priority: priority,
                                                       room: room, assetID: assetID, coordinate: coordinate, photo: photo)
                    showConfirmation = true
                } catch { self.error = error.localizedDescription }
            }.disabled(isLoadingPhoto || submitted != nil)
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
            } message: { Text("\(submitted?.number ?? "Ticket") is saved on this device.") }
            .navigationDestination(isPresented: $showDetails) { if let submitted { TicketDetailView(ticketID: submitted.id) } }
    }
}

struct TicketDetailView: View {
    @EnvironmentObject private var model: AppModel
    let ticketID: UUID
    @State private var comment = ""
    @State private var error: String?
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
                        Button("Advance to next status (demo)") { do { try model.advanceTicket(id: ticketID) } catch { self.error = error.localizedDescription } }
                    }
                }
                Section("Comments") {
                    if ticket.comments.isEmpty { Text("No comments yet.").foregroundStyle(.secondary) }
                    ForEach(ticket.comments) { entry in
                        VStack(alignment: .leading, spacing: 6) { Text(entry.author).font(.caption.bold()); Text(entry.text); Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    }
                    TextField("Write a comment", text: $comment, axis: .vertical)
                    Button("Send comment") { do { try model.addComment(ticketID: ticketID, text: comment); comment = "" } catch { self.error = error.localizedDescription } }
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
                Section { Button("Sign out", role: .destructive) { confirmSignOut = true } }
                Text("Local demo - \(model.role.rawValue). Sign out to choose another demo role.").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("More")
                .confirmationDialog("Sign out of NIBM ONE?", isPresented: $confirmSignOut, titleVisibility: .visible) { Button("Sign out", role: .destructive) { model.signOut() } }
        }
    }
}

struct NotificationsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            Section { Text("Local activity only. Remote push notifications are not connected.").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.notices) { notice in
                NavigationLink {
                    NoticeDetailView(destination: notice.destination).onAppear { model.markRead(notice.id) }
                } label: {
                    HStack { if !notice.isRead { Circle().fill(Color.nibmBlue).frame(width: 8, height: 8).accessibilityLabel("Unread") }; VStack(alignment: .leading) { Text(notice.title); Text(notice.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) } }
                }
            }
        }.navigationTitle("Notifications")
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
        Form { Section { LabeledContent("Name", value: "Alex Perera"); LabeledContent("Employee ID", value: "NIBM-00321"); LabeledContent("Branch", value: "Colombo"); LabeledContent("Demo role", value: model.role.rawValue) } }.navigationTitle("Employee profile")
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
                NavigationLink("Widgets & Siri", destination: IntegrationStatusView())
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
            Section("Not connected in this build") {
                Text("Home Screen widgets need a WidgetKit extension and a shared authenticated summary cache.")
                Text("Siri shortcuts need App Intents and authenticated navigation routes.")
                Text("Institutional login, password emails, fingerprint sync and remote push need the backend services.")
            }
        }.navigationTitle("Widgets & Siri")
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
    var body: some View { HStack { Text(day.date.formatted(.dateTime.weekday(.abbreviated).day())).frame(width: 70, alignment: .leading); VStack(alignment: .leading) { Text(day.firstIn); Text(day.lastOut).font(.caption).foregroundStyle(.secondary) }; Spacer(); StatusPill(text: day.status.rawValue, color: day.status.color) } }
}
struct AttendanceDayCard: View {
    let day: AttendanceDay
    var body: some View {
        VStack(spacing: 4) { Text(day.date.formatted(.dateTime.day())).font(.headline); Circle().fill(day.status.color).frame(width: 8, height: 8); Text(day.status.rawValue).font(.caption2).multilineTextAlignment(.center) }
            .frame(maxWidth: .infinity, minHeight: 60).padding(.vertical, 4).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore).accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted)), \(day.status.rawValue), first in \(day.firstIn), last out \(day.lastOut)")
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
        }
    }
}
extension RequestStatus { var color: Color { switch self { case .approved: return .green; case .pending: return .orange; case .rejected: return .red } } }
extension Coordinate { var clLocation: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) } }
extension Color { static let nibmBlue = Color(red: 0.06, green: 0.31, blue: 0.62); static let nibmNavy = Color(red: 0.03, green: 0.10, blue: 0.22); static let nibmBackground = Color(red: 0.95, green: 0.97, blue: 0.99) }
