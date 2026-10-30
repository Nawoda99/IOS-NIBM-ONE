import SwiftUI
import MapKit

struct EmployeeAccountsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var employees: [EmployeeAccount] = []
    @State private var search = ""
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var error: String?
    var body: some View {
        List {
            if model.role == .administrator {
                Section {
                    Button { showCreate = true } label: { Label("Create employee login", systemImage: "person.badge.plus").frame(maxWidth: .infinity, minHeight: 48) }
                        .buttonStyle(.borderedProminent)
                    Text("Create an employee or enable login for an existing EPF. Only Administrators can change roles.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Employees") {
                    if isLoading { ProgressView("Loading employees") }
                    if employees.isEmpty && !isLoading { Text("No matching employees.").foregroundStyle(.secondary) }
                    ForEach(employees) { employee in
                        if employee.hasLogin {
                            NavigationLink(destination: EmployeeAccessView(employee: employee, onSaved: { Task { await load() } })) { accountRow(employee) }
                        } else {
                            NavigationLink(destination: CreateEmployeeLoginView(employee: employee, onCreated: { Task { await load() } })) { accountRow(employee) }
                        }
                    }
                }
            } else { Text("Administrator access is required.") }
        }
        .navigationTitle("Employee accounts").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Name or EPF number")
        .task(id: search) { await load() }.refreshable { await load() }
        .sheet(isPresented: $showCreate) { NavigationStack { CreateEmployeeLoginView(onCreated: { Task { await load() } }) } }
        .errorAlert($error)
    }
    private func accountRow(_ employee: EmployeeAccount) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(employee.name).font(.headline)
            Text("EPF \(employee.epfNo) · \(employee.role.rawValue)").font(.caption).foregroundStyle(.secondary)
            Text(employee.hasLogin ? (employee.isActive ? "Login enabled" : "Inactive employee") : "Tap to enable login")
                .font(.caption).foregroundStyle(employee.hasLogin ? Color.secondary : Color.nibmBlue)
        }.padding(.vertical, 5)
    }
    private func load() async {
        guard model.role == .administrator else { employees = []; return }
        isLoading = true
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let result = try await model.employeeAccounts(search: search)
            guard !Task.isCancelled else { return }
            employees = result
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct CreateEmployeeLoginView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let employee: EmployeeAccount?
    let onCreated: () -> Void
    @State private var epf = ""
    @State private var name = ""
    @State private var identity = ""
    @State private var password = ""
    @State private var role: EmployeeRole = .employee
    @State private var branchID = 0
    @State private var branches: [BranchLocation] = []
    @State private var saving = false
    @State private var error: String?
    init(employee: EmployeeAccount? = nil, onCreated: @escaping () -> Void) {
        self.employee = employee; self.onCreated = onCreated
        _epf = State(initialValue: employee?.epfNo ?? "")
        _name = State(initialValue: employee?.name ?? "")
        _branchID = State(initialValue: employee?.branchID ?? 0)
    }
    private var valid: Bool {
        !epf.isEmpty && password.count >= 8 && (employee != nil || (!name.trimmingCharacters(in: .whitespaces).isEmpty && !identity.trimmingCharacters(in: .whitespaces).isEmpty))
    }
    var body: some View {
        Form {
            Section("Employee") {
                TextField("EPF number", text: $epf).keyboardType(.numberPad).disabled(employee != nil)
                TextField("Full name", text: $name).disabled(employee != nil)
                if employee == nil { TextField("Actual identity number", text: $identity).textInputAutocapitalization(.characters).autocorrectionDisabled() }
                else { Text("Existing employee details will be preserved.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Login access") {
                SecureField("Password (at least 8 characters)", text: $password).textContentType(.newPassword).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Role", selection: $role) { ForEach(EmployeeRole.allCases) { Text($0.rawValue).tag($0) } }
                if employee == nil { Picker("Branch", selection: $branchID) { Text("Not assigned").tag(0); ForEach(branches) { Text($0.name).tag($0.id) } } }
                Text("Administrator can manage accounts and permissions. Approver can decide leave; Support can manage tickets, subject to role permissions.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            _ = try await model.createEmployeeAccount(CreateEmployeeBody(epfNo: epf, name: name, identityNo: identity, password: password, role: role, branchID: branchID == 0 ? nil : branchID))
                            password = ""; onCreated(); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                } label: { Label(saving ? "Creating login…" : "Create login", systemImage: "person.badge.plus").frame(maxWidth: .infinity, minHeight: 48) }
                    .buttonStyle(.borderedProminent).disabled(!valid || saving)
            }
        }
        .disabled(saving).navigationTitle("Create employee login").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
        .task { do { branches = try await model.branchDirectory().branches } catch { self.error = error.localizedDescription } }
        .errorAlert($error)
    }
}

struct EmployeeAccessView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let employee: EmployeeAccount
    let onSaved: () -> Void
    @State private var role: EmployeeRole
    @State private var branchID: Int
    @State private var branches: [BranchLocation] = []
    @State private var saving = false
    @State private var error: String?
    init(employee: EmployeeAccount, onSaved: @escaping () -> Void) {
        self.employee = employee; self.onSaved = onSaved
        _role = State(initialValue: employee.role); _branchID = State(initialValue: employee.branchID ?? 0)
    }
    var body: some View {
        Form {
            Section { Text(employee.name).font(.headline); LabeledContent("EPF", value: employee.epfNo) }
            Section("Access") {
                Picker("Application role", selection: $role) { ForEach(EmployeeRole.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Branch", selection: $branchID) { Text("Not assigned").tag(0); ForEach(branches) { Text($0.name).tag($0.id) } }
                Text("Permissions are enforced by the server. The last active Administrator cannot be removed.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Save access") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await model.updateEmployeeAccount(id: employee.id, role: role, branchID: branchID == 0 ? nil : branchID); onSaved(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).frame(minHeight: 48).disabled(saving)
            }
        }.disabled(saving).navigationTitle("Employee access").navigationBarTitleDisplayMode(.inline)
            .task { do { branches = try await model.branchDirectory().branches } catch { self.error = error.localizedDescription } }.errorAlert($error)
    }
}

struct RolePermissionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var directory: PermissionDirectory?
    @State private var role: EmployeeRole = .employee
    @State private var selected: Set<String> = []
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?
    var body: some View {
        Form {
            Section { Picker("Role", selection: $role) { ForEach(EmployeeRole.allCases) { Text($0.rawValue).tag($0) } } }
            if let directory {
                Section("Menus and actions") {
                    ForEach(directory.permissions) { permission in
                        Toggle(isOn: Binding(get: { selected.contains(permission.id) }, set: { enabled in toggle(permission.id, enabled: enabled) })) {
                            VStack(alignment: .leading, spacing: 3) { Text(permission.title); Text(permission.description).font(.caption).foregroundStyle(.secondary) }
                        }.disabled(role == .administrator || saving)
                    }
                }
                Section("Administration") {
                    Label("Accounts, roles and branch configuration: Administrator only", systemImage: "lock.shield")
                    Text("Administrator permissions are fixed to prevent lockout. Other roles receive menu and API changes on their next refresh.").font(.caption).foregroundStyle(.secondary)
                }
                if role != .administrator {
                    Button("Save permissions") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do { try await model.saveRolePermissions(role: role, permissions: selected); try await reload(); saved = true }
                            catch { self.error = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent).frame(minHeight: 48).disabled(saving)
                }
            } else { ProgressView("Loading role permissions") }
        }
        .disabled(saving).navigationTitle("Roles and permissions").navigationBarTitleDisplayMode(.inline)
        .task { do { try await reload() } catch { self.error = error.localizedDescription } }
        .onChange(of: role) { _, _ in selectRole() }
        .alert("Permissions saved", isPresented: $saved) { Button("OK", role: .cancel) {} }
        .errorAlert($error)
    }
    private func reload() async throws { directory = try await model.permissionDirectory(); selectRole() }
    private func selectRole() { selected = Set(directory?.roles.first { $0.role == role }?.permissions ?? []) }
    private func toggle(_ key: String, enabled: Bool) {
        if enabled { selected.insert(key) } else { selected.remove(key) }
        for (action, view) in [("leave.apply", "leave.view"), ("leave.approve", "leave.view"), ("tickets.create", "tickets.view"), ("tickets.manage", "tickets.view")] {
            if key == action && enabled { selected.insert(view) }
            if key == view && !enabled { selected.remove(action) }
        }
    }
}

struct BranchLocationsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var branches: [BranchLocation] = []
    @State private var error: String?
    var body: some View {
        List {
            Section { Text("Set map pins for branches already registered in the database. The map also resolves NIBM campus addresses from the official contact directory.").font(.caption).foregroundStyle(.secondary) }
            ForEach(branches) { branch in
                NavigationLink(destination: EditBranchLocationView(branch: branch)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(branch.name).font(.headline)
                        Text(branch.coordinate == nil ? "Configure branch pin" : branch.address).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("Branch locations").navigationBarTitleDisplayMode(.inline)
            .task { await load() }.refreshable { await load() }.errorAlert($error)
    }
    private func load() async { do { branches = try await model.branchDirectory().branches } catch { self.error = error.localizedDescription } }
}

struct EditBranchLocationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let branch: BranchLocation
    @State private var address: String
    @State private var coordinate: Coordinate?
    @State private var showMap = false
    @State private var saving = false
    @State private var error: String?
    init(branch: BranchLocation) {
        self.branch = branch; _address = State(initialValue: branch.address); _coordinate = State(initialValue: branch.coordinate)
    }
    var body: some View {
        Form {
            Section(branch.name) {
                TextField("Street address", text: $address, axis: .vertical)
                Button { showMap = true } label: { Label("Choose branch pin on map", systemImage: "mappin.and.ellipse") }.buttonStyle(.bordered).frame(minHeight: 48)
                if let coordinate { Text("\(coordinate.latitude.formatted()), \(coordinate.longitude.formatted())").font(.caption).foregroundStyle(.secondary) }
            }
            Button("Save branch location") {
                guard let coordinate else { return }; saving = true
                Task {
                    defer { saving = false }
                    do { try await model.saveBranchLocation(id: branch.id, address: address, coordinate: coordinate); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent).frame(minHeight: 48).disabled(saving || coordinate == nil || address.trimmingCharacters(in: .whitespaces).isEmpty)
        }.disabled(saving).navigationTitle("Branch map pin").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showMap) { NavigationStack { TicketLocationView(coordinate: $coordinate) } }
            .task {
                guard coordinate == nil, !address.isEmpty else { return }
                do {
                    let request = MKLocalSearch.Request(); request.naturalLanguageQuery = "NIBM \(branch.name), \(address)"
                    let result = try await MKLocalSearch(request: request).start()
                    if let point = result.mapItems.first?.placemark.coordinate { coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude) }
                } catch { self.error = "Address lookup was unavailable. Choose the branch pin manually on the map." }
            }.errorAlert($error)
    }
}
