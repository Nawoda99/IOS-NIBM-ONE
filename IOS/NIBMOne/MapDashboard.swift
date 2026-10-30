import SwiftUI
import MapKit
import CoreLocation

private struct CampusPin: Identifiable {
    let id: String
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    let isSaved: Bool
}

struct BranchTicketMapView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var location = LocationProvider()
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 7.1, longitude: 80.3), span: MKCoordinateSpan(latitudeDelta: 2.5, longitudeDelta: 2.5)))
    @State private var selected: String?
    @State private var pins: [CampusPin] = []
    @State private var query = "NIBM"
    @State private var loading = false
    @State private var searching = false
    @State private var error: String?
    @State private var lookupNote: String?
    @State private var showBranches = true
    @State private var showTickets = true
    private var selectedPin: CampusPin? { pins.first { "branch:\($0.id)" == selected } }
    private var selectedTicket: Ticket? { model.tickets.first { "ticket:\($0.id.uuidString)" == selected } }
    var body: some View {
        Map(position: $position, selection: $selected) {
            UserAnnotation()
            if showBranches {
                ForEach(pins) { pin in
                    Marker(pin.name, systemImage: "building.2.fill", coordinate: pin.coordinate)
                        .tint(.blue).tag("branch:\(pin.id)")
                }
            }
            if showTickets {
                ForEach(model.tickets.filter { $0.status != .closed }) { ticket in
                    if let coordinate = ticket.coordinate {
                        Marker(ticket.title, systemImage: "wrench.and.screwdriver.fill", coordinate: coordinate.clLocation)
                            .tint(.orange).tag("ticket:\(ticket.id.uuidString)")
                    }
                }
            }
        }
        .mapControls { MapCompass(); MapScaleView() }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search NIBM or a place", text: $query).submitLabel(.search).onSubmit { Task { await search() } }
                    Button { Task { await search() } } label: {
                        if searching { ProgressView() } else { Image(systemName: "arrow.right.circle.fill").font(.title2) }
                    }.frame(minWidth: 44, minHeight: 44).disabled(searching || loading).accessibilityLabel("Search places")
                }.padding(.horizontal, 12).background(.background, in: RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 10) {
                    Toggle("Branches", isOn: $showBranches).toggleStyle(.button)
                    Toggle("Tickets", isOn: $showTickets).toggleStyle(.button)
                    Spacer(minLength: 0)
                    Button { location.request() } label: {
                        Label(location.isRequesting ? "Locating…" : "My location", systemImage: "location.fill")
                    }.disabled(location.isRequesting)
                }.font(.caption.weight(.semibold)).buttonStyle(.bordered).frame(minHeight: 44)
            }.padding(12).background(.regularMaterial)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if let pin = selectedPin {
                    Text(pin.name).font(.headline)
                    Text(pin.address).font(.caption).foregroundStyle(.secondary)
                    Text(pin.isSaved ? "Saved branch pin" : pin.id == "search-result" ? "Map search result" : "Location resolved from the published campus address").font(.caption2).foregroundStyle(.secondary)
                    Button { openDirections(pin) } label: { Label("Directions in Maps", systemImage: "arrow.triangle.turn.up.right.diamond") }.buttonStyle(.borderedProminent)
                } else if let ticket = selectedTicket {
                    NavigationLink(destination: TicketDetailView(ticketID: ticket.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) { Text(ticket.title).font(.headline); Text("\(ticket.room) · \(ticket.status.rawValue)").font(.caption); Text("Open ticket details").font(.caption.weight(.semibold)) }
                            Spacer(); Image(systemName: "chevron.right")
                        }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    }
                } else {
                    HStack {
                        Label(loading ? "Loading NIBM campuses…" : "\(pins.count) NIBM locations", systemImage: "building.2")
                        Spacer()
                        Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.disabled(loading || searching).accessibilityLabel("Reload campus pins")
                    }.font(.subheadline.weight(.semibold))
                    Text("Tap a blue branch pin or orange ticket pin. Use My location to show your position.").font(.caption).foregroundStyle(.secondary)
                    if let lookupNote { Text(lookupNote).font(.caption2).foregroundStyle(.secondary) }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
        }
        .navigationTitle("Branches and tickets").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .task { await load() }
        .onChange(of: location.coordinate) { _, coordinate in
            guard let coordinate else { return }
            position = .region(MKCoordinateRegion(center: coordinate.clLocation, span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)))
        }
        .onChange(of: location.error) { _, value in if let value { error = value; location.error = nil } }
        .errorAlert($error)
    }
    private func load() async {
        guard !loading, !searching else { return }; loading = true
        defer { loading = false }
        guard model.isRemoteSession else { lookupNote = "Connect to the server to load the NIBM campus directory."; return }
        do {
            let directory = try await model.branchDirectory()
            var resolved: [CampusPin] = []
            var unresolved = 0
            for branch in directory.branches {
                if let coordinate = branch.coordinate {
                    resolved.append(CampusPin(id: "saved-\(branch.id)", name: branch.name, address: branch.address, coordinate: coordinate.clLocation, isSaved: true))
                }
            }
            pins = resolved
            for campus in directory.campuses {
                try Task.checkCancellation()
                if resolved.contains(where: { $0.isSaved && campus.name.localizedCaseInsensitiveContains($0.name) }) { continue }
                do {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = "NIBM \(campus.name), \(campus.address)"
                    request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 7.1, longitude: 80.3), span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5))
                    let response = try await MKLocalSearch(request: request).start()
                    guard let item = response.mapItems.first(where: {
                        let point = $0.placemark.coordinate
                        return (5...10).contains(point.latitude) && (79...83).contains(point.longitude) && ($0.name?.localizedCaseInsensitiveContains("NIBM") ?? false)
                    }) else { unresolved += 1; continue }
                    resolved.append(CampusPin(id: campus.id, name: campus.name, address: campus.address, coordinate: item.placemark.coordinate, isSaved: false))
                    pins = resolved
                } catch is CancellationError { return }
                catch { unresolved += 1 }
            }
            lookupNote = unresolved == 0 ? "Campus addresses: nibm.ac.lk/contact" : "\(unresolved) address lookups unavailable. Retry with an internet connection, or ask an Administrator to save the branch pin."
            if !resolved.isEmpty && location.coordinate == nil { position = .automatic }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    private func search() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !searching, !loading else { return }
        searching = true
        defer { searching = false }
        do {
            let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
            if let coordinate = location.coordinate { request.region = MKCoordinateRegion(center: coordinate.clLocation, span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)) }
            let result = try await MKLocalSearch(request: request).start()
            guard let first = result.mapItems.first else { throw FormError.invalid("No matching places were found.") }
            let id = "search-result"
            pins.removeAll { $0.id == id }
            pins.append(CampusPin(id: id, name: first.name ?? query, address: first.placemark.title ?? "", coordinate: first.placemark.coordinate, isSaved: false))
            showBranches = true; selected = "branch:\(id)"
            position = .region(MKCoordinateRegion(center: first.placemark.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
        } catch { self.error = error.localizedDescription }
    }
    private func openDirections(_ pin: CampusPin) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: pin.coordinate)); item.name = pin.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}
