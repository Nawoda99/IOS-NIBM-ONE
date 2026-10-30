import SwiftUI

struct FingerprintMachineView: View {
    @EnvironmentObject private var model: AppModel
    @State private var machines: [MachineAdminStatus] = []
    @State private var unmappedUsers: [UnmappedMachineUser] = []
    @State private var epfNo = ""
    @State private var isBusy = false
    @State private var message: String?
    @State private var error: String?
    var body: some View {
        Form {
            Section("Machine status") {
                ForEach(machines) { machine in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(machine.name).font(.headline)
                        if let ip = machine.ipAddress { Text("\(machine.model ?? "Machine") - \(ip):\(machine.port ?? 4370)").font(.caption) }
                        Text(machine.lastSyncedAt.map { "Last sync: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No completed sync yet").font(.caption)
                        Text("\(machine.total) stored punches, \(machine.unmapped) unmapped").font(.caption)
                        if let lastError = machine.lastError { Text(lastError).foregroundStyle(.red).font(.caption) }
                    }
                }
                if machines.isEmpty { Text("No machines have been registered on the server.").foregroundStyle(.secondary) }
                Button("Pull punches now") {
                    guard !isBusy else { return }; isBusy = true
                    Task {
                        defer { isBusy = false }
                        do {
                            let result = try await model.pullFingerprintPunches()
                            message = "Read \(result.received): \(result.inserted) new, \(result.duplicates) duplicates, \(result.unmapped) unmapped."
                            try await reload()
                        } catch { self.error = error.localizedDescription; try? await reload() }
                    }
                }.disabled(isBusy)
                if isBusy { ProgressView("Contacting machine / saving records") }
                if let message { Text(message).font(.caption) }
            }
            Section("Link EPF records") {
                TextField("EPF No.", text: $epfNo).keyboardType(.numberPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Punches use EPF numbers and link automatically to the registered account with the same EPF No. Register missing employee accounts on the server first.").font(.caption).foregroundStyle(.secondary)
                Button("Link stored EPF punches") {
                    guard !isBusy else { return }; isBusy = true
                    Task {
                        defer { isBusy = false }
                        do {
                            try await model.linkFingerprintEPF(epfNo: epfNo)
                            message = "EPF punches linked."
                            try await reload()
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(isBusy)
            }
            if !unmappedUsers.isEmpty {
                Section("Unregistered EPF numbers - tap to select") {
                    ForEach(unmappedUsers) { user in
                        Button("EPF \(user.epfNo) - \(user.count) punches") {
                            epfNo = user.epfNo
                        }
                    }
                }
            }
            Section {
                Text("Only successful machine reads update the sync time. Unknown IN/OUT codes remain flagged for review until the terminal's code meanings are configured on the server.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Fingerprint machine").errorAlert($error)
            .task { do { try await reload() } catch { self.error = error.localizedDescription } }
            .refreshable { do { try await reload() } catch { self.error = error.localizedDescription } }
    }
    private func reload() async throws {
        machines = try await model.fingerprintMachines()
        unmappedUsers = try await model.unmappedMachineUsers()
    }
}
