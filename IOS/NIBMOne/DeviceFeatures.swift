import SwiftUI
import UIKit
import Combine
import VisionKit
import Vision
import PhotosUI
import AVFoundation
import MapKit
import CoreLocation
import UserNotifications

struct ScanToTicketView: View {
    @State private var asset: Asset?
    var body: some View {
        if let asset { CreateTicketView(asset: asset) }
        else { QRScannerView { asset = $0 } }
    }
}

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Asset) -> Void
    @State private var code = ""
    @State private var confirmedAsset: Asset?
    @State private var cameraReady = false
    @State private var status = "Checking camera availability..."
    @State private var qrPhoto: PhotosPickerItem?
    @State private var isReadingPhoto = false
    var body: some View {
        Form {
            if let asset = confirmedAsset {
                Section("Asset identified") {
                    Label(asset.name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    LabeledContent("Identifier", value: asset.id)
                    LabeledContent("Building", value: asset.building)
                    LabeledContent("Room", value: asset.room)
                    Button("Use this asset") { onSelect(asset) }
                    Button("Scan another QR") { confirmedAsset = nil; code = ""; Task { await prepareCamera() } }
                }
            } else {
                if cameraReady {
                    Section("Camera") {
                        CameraScanner(onCode: identify, onFailure: { message in status = message; cameraReady = false }).frame(height: 280)
                    }
                }
                Section("Scanner status") { Text(status).font(.caption); if !cameraReady { Button("Try camera again") { Task { await prepareCamera() } } } }
                Section("Photo and manual identification") {
                    PhotosPicker(selection: $qrPhoto, matching: .images) { Label("Read QR from photo", systemImage: "photo") }
                        .disabled(isReadingPhoto)
                    if isReadingPhoto { ProgressView("Reading QR with Vision") }
                    TextField("Room or asset code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Look up code") { identify(code) }
                    Text("This demo recognises the registered codes below. Live QR lookup requires the asset API.").font(.caption).foregroundStyle(.secondary)
                    ForEach(Asset.samples) { asset in Button("\(asset.id) - \(asset.room)") { identify(asset.id) } }
                }
            }
        }.navigationTitle("Scan room / asset QR")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await prepareCamera() }
            .onChange(of: qrPhoto) { _, item in
                guard let item else { return }
                Task {
                    isReadingPhoto = true
                    defer { isReadingPhoto = false; qrPhoto = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw FormError.invalid("The selected image could not be opened.")
                        }
                        identify(try await QRImageReader.code(from: data))
                    } catch { status = error.localizedDescription }
                }
            }
    }
    private func identify(_ value: String) {
        cameraReady = false
        if let asset = Asset.identify(value) { confirmedAsset = asset; code = asset.id }
        else { status = "QR code not recognised. Enter or choose a registered room or asset below." }
    }
    private func prepareCamera() async {
        guard DataScannerViewController.isSupported else {
            status = "Camera scanning is unavailable on this device or simulator. Use manual identification."; return
        }
        let permission = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed: Bool
        if permission == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
        else { allowed = permission == .authorized }
        guard !Task.isCancelled else { return }
        guard allowed, DataScannerViewController.isAvailable else {
            status = "Camera access is unavailable. Enable Camera in iPhone Settings or use manual identification."; return
        }
        status = "Point the camera at a registered room or asset QR code."
        cameraReady = true
    }
}

enum QRImageReader {
    static func code(from data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(data: data, options: [:]).perform([request])
            let codes = Set((request.results ?? []).compactMap(\.payloadStringValue).filter { !$0.isEmpty })
            guard codes.count == 1, let code = codes.first else {
                throw FormError.invalid(codes.isEmpty ? "No QR code was found in this photo." : "Choose an image containing one QR code.")
            }
            return code
        }.value
    }
}

struct CameraScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onFailure: onFailure) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.finished else { return }
        do { try scanner.startScanning() }
        catch { context.coordinator.fail("The scanner could not start. Use manual identification. \(error.localizedDescription)") }
    }
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) { scanner.stopScanning() }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        let onFailure: (String) -> Void
        var finished = false
        init(onCode: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) { self.onCode = onCode; self.onFailure = onFailure }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let code = barcode.payloadStringValue, !finished {
                    finished = true; dataScanner.stopScanning()
                    DispatchQueue.main.async { self.onCode(code) }
                    return
                }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            dataScanner.stopScanning(); fail("The camera became unavailable. Use manual identification.")
        }
        func fail(_ message: String) {
            guard !finished else { return }; finished = true
            DispatchQueue.main.async { self.onFailure(message) }
        }
    }
}

@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: Coordinate?
    @Published var error: String?
    @Published private(set) var isRequesting = false
    private let manager = CLLocationManager()
    override init() {
        super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    func request() {
        guard !isRequesting else { return }
        error = nil
        isRequesting = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: fail("Location access is disabled. Choose a point on the map or enable Location in Settings.")
        @unknown default: fail("Location is unavailable. Choose a point on the map.")
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isRequesting else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: fail("Location permission was denied. You can still choose a point on the map.")
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { fail("No location was returned. Choose a point on the map."); return }
        coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        isRequesting = false
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { fail(error.localizedDescription) }
    private func fail(_ message: String) { isRequesting = false; error = message }
}

struct TicketLocationView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var coordinate: Coordinate?
    @StateObject private var provider = LocationProvider()
    @State private var candidate: Coordinate
    @State private var position: MapCameraPosition
    init(coordinate: Binding<Coordinate?>) {
        _coordinate = coordinate
        let initial = coordinate.wrappedValue ?? .campus
        _candidate = State(initialValue: initial)
        _position = State(initialValue: .region(MKCoordinateRegion(center: initial.clLocation, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))))
    }
    var body: some View {
        VStack(spacing: 16) {
            MapReader { reader in
                Map(position: $position) { Marker("Selected location", coordinate: candidate.clLocation) }
                    .onTapGesture { point in
                        if let value = reader.convert(point, from: .local) { candidate = Coordinate(latitude: value.latitude, longitude: value.longitude) }
                    }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Tap the map or use your current location, then confirm. Room and asset identify the indoor location.").font(.caption).foregroundStyle(.secondary)
                Text("\(candidate.latitude.formatted()), \(candidate.longitude.formatted())")
                Button("Use my current location") { provider.request() }.disabled(provider.isRequesting)
                if provider.isRequesting { ProgressView("Finding location") }
                Button("Attach this location") { coordinate = candidate; dismiss() }.buttonStyle(PrimaryButtonStyle())
            }.padding()
        }.navigationTitle("Ticket location")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: provider.coordinate) { _, value in
                guard let value else { return }; candidate = value
                position = .region(MKCoordinateRegion(center: value.clLocation, span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)))
            }.errorAlert($provider.error)
    }
}

struct NotificationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: PushNotifications
    @State private var authorization = UNAuthorizationStatus.notDetermined
    @State private var error: String?
    var body: some View {
        Form {
            Section("Device permission") {
                LabeledContent("Notifications", value: status)
                Button("Request notification permission") {
                    Task {
                        do { try await push.register(requestPermission: true); await refresh() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(authorization != .notDetermined)
                if let url = URL(string: UIApplication.openSettingsURLString) { Link("Open iPhone Settings", destination: url) }
            }
            Section("Punch notifications") {
                Text(model.isRemoteSession ? model.pushStatus : "Sign in with your employee account to receive punch notifications.")
                if let message = push.registrationError { Text(message).foregroundStyle(.red) }
                Button("Retry registration") {
                    Task {
                        do {
                            try await push.register(requestPermission: true)
                            if let token = push.deviceToken { await model.registerPushDevice(token: token, environment: PushNotifications.environment) }
                            await refresh()
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(!model.isRemoteSession || authorization == .denied)
                Text("New punches notify this iPhone after the fingerprint machine syncs. Tap the notification to open Attendance.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Notification settings").task { await refresh() }.errorAlert($error)
    }
    private var status: String {
        switch authorization { case .authorized: return "Allowed"; case .denied: return "Denied"; case .notDetermined: return "Not requested"; case .provisional: return "Quiet delivery"; case .ephemeral: return "Temporary"; @unknown default: return "Unknown" }
    }
    private func refresh() async { authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
}
