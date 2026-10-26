import SwiftUI
import MapKit
import VisionKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { Group { if model.isAuthenticated { MainTabView() } else { LoginView() } } }
}

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var employeeID = ""
    @State private var password = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer(minLength: 30)
                    Image(systemName: "building.2.crop.circle.fill").font(.system(size: 66)).foregroundStyle(Color.nibmBlue)
                    Text("Welcome to\nNIBM ONE").font(.system(size: 36, weight: .bold)).foregroundStyle(Color.nibmNavy)
                    Text("One place for attendance, leave and service requests.").foregroundStyle(.secondary)
                    VStack(spacing: 14) {
                        TextField("Employee ID", text: $employeeID).textContentType(.username).textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                        Button("Sign in") { model.signIn() }.buttonStyle(PrimaryButtonStyle())
                    }
                    NavigationLink("Forgot password?", destination: ResetPasswordView()).frame(maxWidth: .infinity, alignment: .center)
                }.padding(24)
            }.background(Color.nibmBackground.ignoresSafeArea())
        }
    }
}

struct ResetPasswordView: View {
    @State private var email = ""
    var body: some View { Form { Section("Recover access") { TextField("Institutional email", text: $email); Button("Send reset link") {} } } .navigationTitle("Reset password") }
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
    var today: AttendanceDay { model.attendance.last! }
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                HStack { VStack(alignment: .leading) { Text("Good morning,").foregroundStyle(.secondary); Text("Alex Perera").font(.title2.bold()).foregroundStyle(Color.nibmNavy) }; Spacer(); Image(systemName: "bell").font(.title3) }
                VStack(alignment: .leading, spacing: 10) { Text("Today's attendance").font(.headline); HStack { Metric(title: "First IN", value: today.firstIn); Metric(title: "Last OUT", value: today.lastOut); Metric(title: "Worked", value: today.worked) }; StatusPill(text: "Late arrival", color: .orange) }.cardStyle()
                HStack { QuickAction(title: "Apply leave", icon: "doc.badge.plus", tab: 2); QuickAction(title: "Create ticket", icon: "plus.circle", tab: 3); QuickAction(title: "Scan QR", icon: "qrcode.viewfinder", tab: 3) }
                HStack { Text("Attendance calendar").font(.headline); Spacer(); Button("View all") { model.selectedTab = 1 } }.padding(.top, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) { ForEach(model.attendance) { day in AttendanceDayCard(day: day) } }
                HStack { Text("Leave balance").font(.headline); Spacer(); Text("18 days").font(.title3.bold()).foregroundStyle(Color.nibmBlue) }.cardStyle()
            }.padding() }.background(Color.nibmBackground.ignoresSafeArea()).navigationTitle("NIBM ONE").toolbar { ToolbarItem(placement: .topBarTrailing) { Image(systemName: "person.crop.circle") } }
        }
    }
}

struct AttendanceView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { NavigationStack { List { Section { ForEach(model.attendance) { day in NavigationLink(destination: DayDetailsView(day: day)) { AttendanceRow(day: day) } } } header: { HStack { Text("October 2026"); Spacer(); Text("Last sync 10:04 AM").font(.caption).foregroundStyle(.secondary) } }; Section("Monthly summary") { HStack { SummaryValue(title: "Present", value: "18"); SummaryValue(title: "Late", value: "2"); SummaryValue(title: "Hours", value: "142h") } } }.navigationTitle("Attendance").toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink(destination: PunchRecordsView()) { Image(systemName: "list.bullet.rectangle") } } } } }
}

struct PunchRecordsView: View { @EnvironmentObject private var model: AppModel; var body: some View { List(model.attendance.flatMap(\.punches)) { punch in HStack { Image(systemName: punch.direction == "IN" ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill").foregroundStyle(punch.direction == "IN" ? .green : .red); VStack(alignment: .leading) { Text(punch.time).font(.headline); Text("\(punch.machine) · \(punch.branch)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(punch.direction).font(.caption.bold()) } }.navigationTitle("Fingerprint punches") } }

struct DayDetailsView: View { let day: AttendanceDay; var body: some View { List { Section("Summary") { LabeledContent("Status", value: day.status.rawValue); LabeledContent("Worked hours", value: day.worked); LabeledContent("First IN", value: day.firstIn); LabeledContent("Last OUT", value: day.lastOut) }; Section("Punch history") { ForEach(day.punches) { punch in Text("\(punch.time) · \(punch.direction) · \(punch.machine)") } } }.navigationTitle(day.date.formatted(date: .abbreviated, time: .omitted)) } }

struct LeaveView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { NavigationStack { List { Section { NavigationLink("Apply for leave", destination: ApplyLeaveView()) } header: { Text("Balances") }; ForEach(LeaveType.allCases) { type in HStack { Text(type.rawValue); Spacer(); Text(type == .annual ? "12 days" : type == .casual ? "4 days" : "2 days").foregroundStyle(.secondary) } }; Section("Request history") { ForEach(model.leaveRequests) { request in NavigationLink(destination: LeaveDetailView(request: request)) { VStack(alignment: .leading) { Text(request.type.rawValue).font(.headline); Text(request.dates).font(.subheadline).foregroundStyle(.secondary) }; Spacer(); StatusPill(text: request.status.rawValue, color: request.status == .approved ? .green : .orange) } } } }.navigationTitle("Leave") } }
}

struct ApplyLeaveView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var type: LeaveType = .annual; @State private var reason = ""; @State private var halfDay = false
    var body: some View { Form { Section("Leave details") { Picker("Leave type", selection: $type) { ForEach(LeaveType.allCases) { Text($0.rawValue).tag($0) } }; DatePicker("From", selection: .constant(Date()), displayedComponents: .date); DatePicker("To", selection: .constant(Date()), displayedComponents: .date); Toggle("Half-day", isOn: $halfDay); TextField("Reason", text: $reason, axis: .vertical) }; Section { Button("Submit request") { model.leaveRequests.insert(LeaveRequest(type: type, dates: "30 Oct 2026", days: halfDay ? 0.5 : 1, reason: reason.isEmpty ? "Personal work" : reason, status: .pending), at: 0); dismiss() }.buttonStyle(PrimaryButtonStyle()) } }.navigationTitle("Apply for leave") }
}
struct LeaveDetailView: View { let request: LeaveRequest; var body: some View { List { LabeledContent("Type", value: request.type.rawValue); LabeledContent("Dates", value: request.dates); LabeledContent("Duration", value: "\(request.days, specifier: "%g") day(s)"); LabeledContent("Status", value: request.status.rawValue); Section("Reason") { Text(request.reason) } }.navigationTitle("Leave details") } }

struct TicketsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showScanner = false
    var body: some View { NavigationStack { List { Section { NavigationLink(destination: CreateTicketView()) { Label("Create ticket", systemImage: "plus.circle.fill") }; Button { showScanner = true } label: { Label("Scan room / asset QR", systemImage: "qrcode.viewfinder") } }.listRowBackground(Color.clear); Section("My tickets") { ForEach(model.tickets) { ticket in NavigationLink(destination: TicketDetailView(ticket: ticket)) { VStack(alignment: .leading, spacing: 5) { HStack { Text(ticket.number).font(.caption.bold()).foregroundStyle(.secondary); Spacer(); StatusPill(text: ticket.status.rawValue, color: ticket.status == .resolved ? .green : .blue) }; Text(ticket.title).font(.headline); Text("\(ticket.room) · \(ticket.updated)").font(.caption).foregroundStyle(.secondary) } } } } }.navigationTitle("Service requests").toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink(destination: TicketMapView()) { Image(systemName: "map") } } }.sheet(isPresented: $showScanner) { QRScannerView() } } }
}

struct CreateTicketView: View { @EnvironmentObject private var model: AppModel; @Environment(\.dismiss) private var dismiss; @State private var title = ""; @State private var description = ""; @State private var category = "IT"; @State private var priority = "Normal"; var body: some View { Form { Section("Problem") { TextField("Title", text: $title); TextField("Description", text: $description, axis: .vertical); Picker("Category", selection: $category) { ForEach(["IT", "Network", "Air conditioning", "Electrical", "Projector", "Furniture", "Maintenance", "Other"], id: \.self) { Text($0) } }; Picker("Priority", selection: $priority) { Text("Normal"); Text("High") }; LabeledContent("Room / asset", value: "Not selected") }; Section { Button("Submit ticket") { model.tickets.insert(Ticket(number: "NIBM-1043", title: title.isEmpty ? "New service request" : title, category: category, room: "Not assigned", priority: priority, status: .open, updated: "Just now", coordinate: CLLocationCoordinate2D(latitude: 6.9271, longitude: 79.8612),), at: 0); dismiss() }.buttonStyle(PrimaryButtonStyle()) } }.navigationTitle("Create ticket") } }
struct TicketDetailView: View { let ticket: Ticket; var body: some View { List { Section("Request") { LabeledContent("Number", value: ticket.number); LabeledContent("Category", value: ticket.category); LabeledContent("Room", value: ticket.room); LabeledContent("Priority", value: ticket.priority); LabeledContent("Status", value: ticket.status.rawValue) }; Section("Timeline") { Label("Created", systemImage: "checkmark.circle.fill"); Label("Assigned", systemImage: "checkmark.circle.fill"); Label(ticket.status.rawValue, systemImage: "clock.fill") }; Section("Comments") { Text("Support updates will appear here.").foregroundStyle(.secondary) } }.navigationTitle("Ticket details") } }
struct TicketMapView: View { @EnvironmentObject private var model: AppModel; @State private var position = MapCameraPosition.region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 6.9271, longitude: 79.8612), span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))); var body: some View { Map(position: $position) { ForEach(model.tickets) { ticket in Marker(ticket.title, coordinate: ticket.coordinate) } }.navigationTitle("Ticket map") } }
struct QRScannerView: View { @Environment(\.dismiss) private var dismiss; var body: some View { NavigationStack { VStack(spacing: 18) { Image(systemName: "qrcode.viewfinder").font(.system(size: 90)).foregroundStyle(Color.nibmBlue); Text("Point your camera at a room or asset QR code").multilineTextAlignment(.center); Text("Camera scanning is ready to connect to VisionKit in the device build.").font(.caption).foregroundStyle(.secondary) }.padding().navigationTitle("Scan QR").toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } } } } }

struct MoreView: View { @EnvironmentObject private var model: AppModel; var body: some View { NavigationStack { List { NavigationLink(destination: NotificationsView()) { Label("Notifications", systemImage: "bell") }; NavigationLink(destination: ProfileView()) { Label("Employee profile", systemImage: "person") }; NavigationLink(destination: SettingsView()) { Label("Settings", systemImage: "gearshape") }; Section { Button(role: .destructive) { model.signOut() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") } } }.navigationTitle("More") } } }
struct NotificationsView: View { var body: some View { List { Label("Leave request approved", systemImage: "checkmark.circle.fill"); Label("Ticket NIBM-1042 updated", systemImage: "wrench.and.screwdriver.fill"); Label("Attendance sync completed", systemImage: "arrow.triangle.2.circlepath") }.navigationTitle("Notifications") } }
struct ProfileView: View { var body: some View { Form { Section { LabeledContent("Name", value: "Alex Perera"); LabeledContent("Employee ID", value: "NIBM-00321"); LabeledContent("Branch", value: "Colombo") } }.navigationTitle("Employee profile") } }
struct SettingsView: View { @EnvironmentObject private var model: AppModel; var body: some View { Form { Section("Security") { Toggle("Face ID app lock", isOn: $model.appLockEnabled) }; Section("Preferences") { NavigationLink("Notifications", destination: NotificationsView()); NavigationLink("Accessibility", destination: Text("Dynamic Type and VoiceOver are supported by native SwiftUI controls.")); NavigationLink("Widgets & Siri", destination: Text("WidgetKit and App Intents integration point.")) } }.navigationTitle("Settings") } }

struct AttendanceRow: View { let day: AttendanceDay; var body: some View { HStack { Text(day.date.formatted(.dateTime.weekday(.abbreviated).day())).frame(width: 70, alignment: .leading); VStack(alignment: .leading) { Text(day.firstIn); Text(day.lastOut).font(.caption).foregroundStyle(.secondary) }; Spacer(); StatusPill(text: day.status.rawValue, color: day.status == .late ? .orange : .green) } } }
struct AttendanceDayCard: View { let day: AttendanceDay; var body: some View { VStack { Text(day.date.formatted(.dateTime.day())).font(.headline); Circle().fill(day.status == .late ? .orange : .green).frame(width: 8, height: 8) }.frame(maxWidth: .infinity).padding(.vertical, 8).background(.white).clipShape(RoundedRectangle(cornerRadius: 12)) } }
struct Metric: View { let title: String; let value: String; var body: some View { VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline) }.frame(maxWidth: .infinity, alignment: .leading) } }
struct SummaryValue: View { let title: String; let value: String; var body: some View { VStack { Text(value).font(.title3.bold()).foregroundStyle(Color.nibmBlue); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity) } }
struct QuickAction: View { @EnvironmentObject private var model: AppModel; let title: String; let icon: String; let tab: Int; var body: some View { Button { model.selectedTab = tab } label: { VStack(spacing: 8) { Image(systemName: icon).font(.title2); Text(title).font(.caption).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 12).background(.white).clipShape(RoundedRectangle(cornerRadius: 14)) } } }
struct StatusPill: View { let text: String; let color: Color; var body: some View { Text(text).font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.14)).foregroundStyle(color).clipShape(Capsule()) } }
struct PrimaryButtonStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.frame(maxWidth: .infinity).padding().background(Color.nibmBlue).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 12)).opacity(configuration.isPressed ? 0.8 : 1) } }
extension View { func cardStyle() -> some View { self.padding().background(.white).clipShape(RoundedRectangle(cornerRadius: 18)) } }
extension Color { static let nibmBlue = Color(red: 0.06, green: 0.31, blue: 0.62); static let nibmNavy = Color(red: 0.03, green: 0.10, blue: 0.22); static let nibmBackground = Color(red: 0.95, green: 0.97, blue: 0.99) }
