import SwiftUI
import MapKit

private extension VehicleRequestStatus {
    var color: Color {
        switch self {
        case .pendingRecommendation, .pendingApproval: return .orange
        case .approved, .assigned: return .blue
        case .inProgress: return .green
        case .completed: return .teal
        case .rejected: return .red
        case .cancelled: return .secondary
        }
    }
}

struct VehicleRequestsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var requests: [VehicleRequest] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showCreate = false
    @State private var filter = "My requests"
    private var filtered: [VehicleRequest] {
        requests.filter { request in
            if filter == "My requests" { return request.requesterID == model.employeeID }
            if filter == "To review" {
                return request.requesterID != model.employeeID &&
                    ((request.status == .pendingRecommendation && request.supervisorID == model.employeeID && model.can("vehicles.recommend")) ||
                     (request.status == .pendingApproval && model.can("vehicles.manage")))
            }
            return true
        }
    }
    var body: some View {
        List {
            if model.can("vehicles.request") {
                Section {
                    Button { showCreate = true } label: { Label("New vehicle request", systemImage: "car.side.fill").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if !model.isRemoteSession {
                Section { Text("Sign in with your employee account to submit vehicle requests and track assigned trips.").foregroundStyle(.secondary) }
            }
            if model.can("vehicles.recommend") || model.can("vehicles.manage") {
                Picker("Requests", selection: $filter) {
                    Text("My requests").tag("My requests")
                    Text("To review").tag("To review")
                    if model.can("vehicles.manage") { Text("All").tag("All") }
                }.pickerStyle(.segmented)
            }
            Section("Request history") {
                if loading { ProgressView("Loading requests") }
                if filtered.isEmpty && !loading { Text(filter == "To review" ? "No requests are waiting for your decision." : "No vehicle requests yet.").foregroundStyle(.secondary) }
                ForEach(filtered) { request in
                    NavigationLink(destination: VehicleRequestDetailView(request: request)) { VehicleRequestRow(request: request) }
                }
            }
        }.navigationTitle("Vehicle requests").navigationBarTitleDisplayMode(.inline)
            .task { await load() }.refreshable { await load() }.errorAlert($error)
            .sheet(isPresented: $showCreate, onDismiss: { Task { await load() } }) {
                NavigationStack { VehicleRequestForm() }
            }
    }
    private func load() async {
        guard model.isRemoteSession else { return }
        loading = true; defer { loading = false }
        do { requests = try await model.vehicleRequests() }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct VehicleRequestRow: View {
    let request: VehicleRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(request.number).font(.headline); Spacer(); Text(request.status.rawValue).font(.caption.weight(.semibold)).foregroundStyle(request.status.color) }
            Text(request.placeToVisit).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Text(request.schedule).font(.caption).foregroundStyle(.secondary)
            Text(request.requesterName).font(.caption).foregroundStyle(.secondary)
            if let plate = request.vehiclePlate { Label("\(plate) · \(request.driverName ?? "Driver pending")", systemImage: "car.side").font(.caption) }
        }.padding(.vertical, 6)
    }
}

struct VehicleRequestForm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var costCode = ""
    @State private var supervisorID: UUID?
    @State private var place = ""
    @State private var duty = ""
    @State private var requiredDate = Date()
    @State private var outward = VehicleRules.timeDate(hour: 8, minute: 30)
    @State private var inward = VehicleRules.timeDate(hour: 17, minute: 0)
    @State private var supervisors: [VehiclePerson] = []
    @State private var loading = false
    @State private var submitting = false
    @State private var error: String?
    @State private var sent: VehicleRequest?
    @State private var showSent = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: "car.side.fill").font(.title2).foregroundStyle(Color.nibmBlue)
                        .frame(width: 48, height: 48).background(Color.nibmBlue.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Vehicle request details").font(.headline)
                        Text("Applicant: \(model.employeeName) · EPF \(model.epfNo)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 16) { costField; supervisorField }
                } else { costField; supervisorField }
                if loading { ProgressView("Loading recommendation people") }
                if !loading && supervisors.isEmpty {
                    HStack(alignment: .top) {
                        Text(model.isRemoteSession ? "No recommendation people are available. Contact transport administration." : "Connect to your employee account to select your supervisor.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.isRemoteSession { Button("Retry") { Task { await loadSupervisors() } }.font(.caption) }
                    }
                }
                VehicleField("Place to be visited") {
                    HStack {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                        TextField("Enter destination", text: $place, axis: .vertical).lineLimit(1...3)
                    }
                }
                VehicleField("Duty status") {
                    TextField("Describe the purpose of your visit", text: $duty, axis: .vertical).lineLimit(3...6)
                }
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 16) { dateField; outwardField; inwardField }
                } else {
                    dateField
                    HStack(alignment: .top, spacing: 16) { outwardField; inwardField }
                }
                Text("Times are in Sri Lanka time. Outward and inward times must be on the required date.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if sizeClass == .regular { Spacer() }
                    Button { Task { await submit() } } label: {
                        HStack { if submitting { ProgressView().tint(.white) } else { Image(systemName: "paperplane") }; Text("Send for recommendation").fontWeight(.semibold) }
                            .frame(maxWidth: sizeClass == .regular ? nil : .infinity, minHeight: 28)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(submitting || loading || supervisorID == nil || !model.isRemoteSession || sent != nil)
                }
            }.padding(22).background(.white, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.nibmBlue.opacity(0.12), lineWidth: 1))
                .padding(16).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }.background(Color.nibmBackground).navigationTitle("Request a vehicle").navigationBarTitleDisplayMode(.inline)
            .environment(\.timeZone, VehicleRules.timeZone)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(submitting) } }
            .task { await loadSupervisors() }.errorAlert($error)
            .alert("Request sent", isPresented: $showSent) {
                Button("Done") { dismiss() }
            } message: { Text("\(sent?.number ?? "Your request") is waiting for supervisor recommendation. You can follow its progress in Vehicle requests.") }
    }
    private var costField: some View {
        VehicleField("Cost code") { TextField("Enter cost code", text: $costCode).textInputAutocapitalization(.characters).autocorrectionDisabled() }
    }
    private var supervisorField: some View {
        VehicleField("Recommendation person") {
            Picker("Recommendation person", selection: $supervisorID) {
                Text("Select your supervisor").tag(nil as UUID?)
                ForEach(supervisors) { person in Text("\(person.name) · EPF \(person.epfNo)").tag(Optional(person.id)) }
            }.labelsHidden().tint(.nibmNavy).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var dateField: some View {
        VehicleField("Required date") { DatePicker("Required date", selection: $requiredDate, in: Date()..., displayedComponents: .date).labelsHidden().frame(maxWidth: .infinity, alignment: .leading) }
    }
    private var outwardField: some View {
        VehicleField("Outward time") { DatePicker("Outward time", selection: $outward, displayedComponents: .hourAndMinute).labelsHidden().frame(maxWidth: .infinity, alignment: .leading) }
    }
    private var inwardField: some View {
        VehicleField("Inward time") { DatePicker("Inward time", selection: $inward, displayedComponents: .hourAndMinute).labelsHidden().frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func loadSupervisors() async {
        guard model.isRemoteSession else { return }
        loading = true; defer { loading = false }
        do { supervisors = try await model.vehicleDirectory().supervisors }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func submit() async {
        guard !submitting else { return }
        do {
            try VehicleRules.validate(costCode: costCode, supervisorID: supervisorID, place: place, duty: duty, date: requiredDate, outward: outward, inward: inward)
            guard let supervisorID else { return }
            submitting = true; defer { submitting = false }
            sent = try await model.submitVehicleRequest(VehicleRequestBody(costCode: costCode.trimmingCharacters(in: .whitespacesAndNewlines), supervisorID: supervisorID,
                placeToVisit: place.trimmingCharacters(in: .whitespacesAndNewlines), dutyStatus: duty.trimmingCharacters(in: .whitespacesAndNewlines),
                requiredDate: VehicleRules.dateKey(requiredDate), outwardTime: VehicleRules.timeKey(outward), inwardTime: VehicleRules.timeKey(inward)))
            showSent = true
        } catch { self.error = error.localizedDescription }
    }
}

private struct VehicleField<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content.frame(maxWidth: .infinity, minHeight: 26, alignment: .leading).padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.nibmBlue.opacity(0.15), lineWidth: 1))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VehicleRequestDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: DriverLocationTracker
    @State var request: VehicleRequest
    @State private var remarks = ""
    @State private var error: String?
    @State private var busy = false
    @State private var showAssignment = false
    private var own: Bool { request.requesterID == model.employeeID }
    private var driver: Bool { request.driverID == model.employeeID }
    private var recommending: Bool { !own && request.status == .pendingRecommendation && request.supervisorID == model.employeeID && model.can("vehicles.recommend") }
    private var approving: Bool { !own && request.status == .pendingApproval && model.can("vehicles.manage") }

    var body: some View {
        Form {
            Section {
                Text(request.number).font(.title2.bold())
                Label(request.status.rawValue, systemImage: request.status == .inProgress ? "location.fill" : "car.side.fill").foregroundStyle(request.status.color)
                Text(request.schedule).font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Vehicle request details") {
                LabeledContent("Applicant", value: request.requesterName)
                LabeledContent("EPF number", value: request.epfNo)
                LabeledContent("Cost code", value: request.costCode)
                LabeledContent("Recommendation person", value: request.supervisorName)
                VStack(alignment: .leading, spacing: 6) { Text("Place to be visited").font(.caption).foregroundStyle(.secondary); Text(request.placeToVisit) }
                VStack(alignment: .leading, spacing: 6) { Text("Duty status").font(.caption).foregroundStyle(.secondary); Text(request.dutyStatus) }
                if let remarks = request.remarks { LabeledContent("Remarks", value: remarks) }
            }.textSelection(.enabled)
            if let plate = request.vehiclePlate {
                Section("Assigned vehicle") {
                    LabeledContent("Vehicle", value: "\(plate) · \(request.vehicleName ?? "Company vehicle")")
                    LabeledContent("Driver", value: request.driverName ?? "Not assigned")
                    if request.status == .inProgress && (own || driver || model.can("vehicles.manage")) {
                        NavigationLink(destination: VehicleTripMapView(request: request)) { Label("Track vehicle", systemImage: "map.fill") }
                    }
                }
            }
            if recommending || approving {
                Section(recommending ? "Supervisor recommendation" : "Final approval") {
                    TextField("Remarks (required when rejecting)", text: $remarks, axis: .vertical).lineLimit(2...5)
                    Button(recommending ? "Recommend request" : "Approve request") { Task { await decide(true) } }.disabled(busy)
                    Button("Reject request", role: .destructive) { Task { await decide(false) } }.disabled(busy)
                }
            }
            if model.can("vehicles.manage") && [.approved, .assigned].contains(request.status) {
                Section { Button(request.status == .assigned ? "Change vehicle / driver" : "Assign vehicle and driver") { showAssignment = true } }
            }
            if driver && [.assigned, .inProgress].contains(request.status) { driverControls }
            if !driver && model.can("vehicles.manage") && request.status == .inProgress {
                Section("Transport management") {
                    Button("Complete trip and end sharing") { Task { await act("complete") } }.disabled(busy)
                }
            }
            if (own || model.can("vehicles.manage")) && request.status.canCancel {
                Section { Button("Cancel request", role: .destructive) { Task { await act("cancel") } }.disabled(busy) }
            }
            if busy { ProgressView("Updating request") }
        }.navigationTitle("Vehicle request").navigationBarTitleDisplayMode(.inline)
            .task { await reload() }.refreshable { await reload() }.errorAlert($error)
            .sheet(isPresented: $showAssignment) {
                NavigationStack { VehicleAssignmentView(request: request) { request = $0 } }
            }
    }
    private var driverControls: some View {
        Section("Driver location sharing") {
            if tracker.requestID == request.id && tracker.isSharing {
                Label("Sharing this vehicle's location", systemImage: "location.fill").foregroundStyle(.green)
                if let date = tracker.lastSentAt { HStack { Text("Last sent"); Spacer(); Text(date, style: .relative).foregroundStyle(.secondary) } }
                Button("Stop sharing", role: .destructive) { tracker.stop() }
            } else {
                Button(request.status == .assigned ? "Start trip and share location" : "Resume location sharing") {
                    Task {
                        do { try await tracker.start(requestID: request.id, model: model); await reload() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy || tracker.isStarting)
            }
            if let message = tracker.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("Share only while driving this assigned vehicle. The requester and transport manager can see its position. Sharing continues in the background; force-closing the app stops updates.")
                .font(.caption).foregroundStyle(.secondary)
            if request.status == .inProgress {
                Button("Complete trip") { Task { await act("complete") } }.disabled(busy)
            }
        }
    }
    private func reload() async {
        do { request = try await model.vehicleRequest(id: request.id) }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func decide(_ approve: Bool) async {
        do { await act("decision", body: try APIClient.encode(VehicleDecisionBody(approve: approve, remarks: remarks))) }
        catch { self.error = error.localizedDescription }
    }
    private func act(_ action: String, body: Data? = nil) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            request = try await model.vehicleAction(id: request.id, action: action, body: body)
            if action == "complete", tracker.requestID == request.id { tracker.stop(notifyServer: false) }
        } catch { self.error = error.localizedDescription }
    }
}

private struct VehicleAssignmentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: VehicleRequest
    let onAssigned: (VehicleRequest) -> Void
    @State private var directory: VehicleDirectory?
    @State private var vehicleID: UUID?
    @State private var driverID: UUID?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            Section(request.number) { Text(request.placeToVisit); Text(request.schedule).font(.caption).foregroundStyle(.secondary) }
            Section("Assignment") {
                Picker("Company vehicle", selection: $vehicleID) {
                    Text("Select a vehicle").tag(nil as UUID?)
                    ForEach(directory?.vehicles ?? []) { vehicle in Text("\(vehicle.plate) · \(vehicle.name)").tag(Optional(vehicle.id)) }
                }
                Picker("Driver", selection: $driverID) {
                    Text("Select a driver").tag(nil as UUID?)
                    ForEach(directory?.drivers ?? []) { driver in Text("\(driver.name) · EPF \(driver.epfNo)").tag(Optional(driver.id)) }
                }
                Text("The driver uses their employee login and opens More > Driver mode. Conflicting vehicle and driver bookings are blocked.").font(.caption).foregroundStyle(.secondary)
                if directory?.vehicles.isEmpty == true { Text("Add a company vehicle in Company vehicles before assigning this trip.").foregroundStyle(.orange) }
                Button("Save assignment") { Task { await save() } }.disabled(busy || vehicleID == nil || driverID == nil)
                if busy { ProgressView() }
            }
        }.navigationTitle("Assign vehicle").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .task {
                do { directory = try await model.vehicleDirectory(); vehicleID = request.vehicleID; driverID = request.driverID }
                catch { self.error = error.localizedDescription }
            }.errorAlert($error)
    }
    private func save() async {
        guard let vehicleID, let driverID, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await model.vehicleAction(id: request.id, action: "assign", body: APIClient.encode(VehicleAssignmentBody(vehicleID: vehicleID, driverID: driverID)))
            onAssigned(result); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct DriverModeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: DriverLocationTracker
    @State private var trips: [VehicleRequest] = []
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        List {
            Section {
                Label("Company vehicle driver", systemImage: "steeringwheel").font(.headline)
                Text("Open an assigned trip, then choose Start trip and share location. You control when sharing starts and stops.").font(.caption).foregroundStyle(.secondary)
                if tracker.isSharing {
                    Label("Location sharing is active", systemImage: "location.fill").foregroundStyle(.green)
                    Button("Stop sharing", role: .destructive) { tracker.stop() }
                }
                if let message = tracker.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Assigned trips") {
                if loading { ProgressView("Loading trips") }
                if trips.isEmpty && !loading { Text("No trips are assigned to your employee account.").foregroundStyle(.secondary) }
                ForEach(trips) { trip in NavigationLink(destination: VehicleRequestDetailView(request: trip)) { VehicleRequestRow(request: trip) } }
            }
        }.navigationTitle("Driver mode").navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }.errorAlert($error)
            .task {
                while !Task.isCancelled {
                    await load()
                    do { try await Task.sleep(for: .seconds(15)) } catch { break }
                }
            }
    }
    private func load() async {
        guard model.isRemoteSession else { return }
        loading = trips.isEmpty; defer { loading = false }
        do { trips = try await model.vehicleDriverTrips() }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct VehicleTripMapView: View {
    @EnvironmentObject private var model: AppModel
    let request: VehicleRequest
    @State private var tracking: VehicleTracking?
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 7.1, longitude: 80.3), span: MKCoordinateSpan(latitudeDelta: 2.5, longitudeDelta: 2.5)))
    @State private var fitted = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Map(position: $position) {
                    if let location = tracking?.location {
                        Marker(request.vehiclePlate ?? "Company vehicle", systemImage: "car.side.fill", coordinate: location.coordinate.clLocation)
                            .tint(location.isFresh(at: context.date) ? .green : .gray)
                    }
                }.mapControls { MapCompass(); MapScaleView() }
                VStack(alignment: .leading, spacing: 10) {
                    Text(request.placeToVisit).font(.headline)
                    Text("\(request.vehiclePlate ?? "Vehicle") · \(request.driverName ?? "Driver")").font(.subheadline)
                    VehicleTrackingStatus(tracking: tracking, now: context.date)
                    if let error { Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange) }
                    Button("Refresh location") { Task { await load() } }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.background)
            }
        }.navigationTitle("Track vehicle").navigationBarTitleDisplayMode(.inline)
            .task {
                while !Task.isCancelled {
                    await load()
                    do { try await Task.sleep(for: .seconds(10)) } catch { break }
                }
            }
    }
    private func load() async {
        do {
            tracking = try await model.vehicleTracking(id: request.id); error = nil
            if let location = tracking?.location, !fitted {
                position = .region(MKCoordinateRegion(center: location.coordinate.clLocation, span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)))
                fitted = true
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct VehicleTrackingStatus: View {
    let tracking: VehicleTracking?
    let now: Date
    var body: some View {
        if let tracking, tracking.status != .inProgress {
            Label(tracking.status == .completed ? "Trip completed. Location sharing has ended." : "The driver has not started sharing this trip.", systemImage: "location.slash")
                .font(.caption).foregroundStyle(.secondary)
        } else if let location = tracking?.location {
            Label(location.isFresh(at: now) ? "Live location" : location.isSharing ? "Location is out of date" : "Location sharing is paused",
                  systemImage: location.isFresh(at: now) ? "location.fill" : "location.slash")
                .font(.subheadline.weight(.medium)).foregroundStyle(location.isFresh(at: now) ? Color.green : Color.secondary)
            Text("Updated \(location.capturedAt.formatted(.relative(presentation: .named))) · Accuracy \(Int(location.accuracy)) m")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Waiting for the driver's GPS position", systemImage: "location.magnifyingglass").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CompanyVehiclesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var vehicles: [CompanyVehicle] = []
    @State private var error: String?
    @State private var showAdd = false
    @State private var position: MapCameraPosition = .automatic
    var body: some View {
        List {
            Section("Company vehicle tracking") {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Map(position: $position) {
                        ForEach(vehicles) { vehicle in
                            if let location = vehicle.tracking?.location {
                                Marker(vehicle.plate, systemImage: "car.side.fill", coordinate: location.coordinate.clLocation)
                                    .tint(location.isFresh(at: context.date) ? .green : .gray)
                            }
                        }
                    }.mapControls { MapCompass(); MapScaleView() }.frame(height: 270)
                        .overlay {
                            if vehicles.allSatisfy({ $0.tracking?.location == nil }) {
                                ContentUnavailableView("No shared positions", systemImage: "location.slash", description: Text("Vehicles appear when their assigned driver starts sharing a trip."))
                                    .background(.regularMaterial)
                            }
                        }
                }.listRowInsets(EdgeInsets())
                Text("Green pins have a recent GPS update. Grey pins show an older or paused position. Only active trips share locations.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Vehicles") {
                if vehicles.isEmpty { Text("Add your company vehicles to begin assigning trips.").foregroundStyle(.secondary) }
                ForEach(vehicles) { vehicle in
                    if let trip = vehicle.trip {
                        NavigationLink(destination: VehicleRequestDetailView(request: trip)) { vehicleRow(vehicle) }
                    } else { vehicleRow(vehicle) }
                }
            }
        }.navigationTitle("Company vehicles").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { showAdd = true } label: { Label("Add vehicle", systemImage: "plus") } } }
            .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) { NavigationStack { AddCompanyVehicleView() } }
            .errorAlert($error).refreshable { await load() }
            .task {
                while !Task.isCancelled {
                    await load()
                    do { try await Task.sleep(for: .seconds(10)) } catch { break }
                }
            }
    }
    private func vehicleRow(_ vehicle: CompanyVehicle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(vehicle.plate, systemImage: "car.side.fill").font(.headline)
            Text(vehicle.name).font(.subheadline)
            if let trip = vehicle.trip {
                Text("\(trip.driverName ?? "Driver") · \(trip.placeToVisit)").font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 5)) { context in VehicleTrackingStatus(tracking: vehicle.tracking, now: context.date) }
            } else { Text("No active trip").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
    }
    private func load() async {
        do { vehicles = try await model.companyVehicles() }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct AddCompanyVehicleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var plate = ""
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            Section("Company vehicle") {
                TextField("Registration number", text: $plate).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Vehicle name / model", text: $name)
                Button("Add vehicle") {
                    Task {
                        busy = true; defer { busy = false }
                        do { _ = try await model.addCompanyVehicle(CompanyVehicleBody(plate: plate, name: name)); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy || plate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if busy { ProgressView("Saving vehicle") }
            }
        }.navigationTitle("Add company vehicle").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }.errorAlert($error)
    }
}
