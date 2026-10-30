import Foundation
import Combine
import CoreLocation

@MainActor
final class DriverLocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var requestID: UUID?
    @Published private(set) var isSharing = false
    @Published private(set) var isStarting = false
    @Published private(set) var lastSentAt: Date?
    @Published private(set) var message: String?
    private let manager = CLLocationManager()
    private weak var model: AppModel?
    private var sharingKey: String?
    private var generation = UUID()
    private var lastAttempt = Date.distantPast
    private var upload: Task<Void, Never>?
    private var authorization: CheckedContinuation<Bool, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start(requestID: UUID, model: AppModel) async throws {
        guard !isStarting else { return }
        if self.requestID == requestID && isSharing { return }
        guard self.requestID == nil || self.requestID == requestID else { throw FormError.invalid("Stop sharing the current trip before starting another.") }
        isStarting = true
        let current = generation
        defer { isStarting = false }
        if manager.authorizationStatus == .notDetermined {
            let allowed = await withCheckedContinuation { continuation in
                authorization = continuation
                manager.requestWhenInUseAuthorization()
            }
            guard allowed else { throw FormError.invalid("Allow Location access in iPhone Settings to share this vehicle's location.") }
        }
        guard [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) else {
            throw FormError.invalid("Allow Location access in iPhone Settings to share this vehicle's location.")
        }
        guard manager.accuracyAuthorization == .fullAccuracy else {
            throw FormError.invalid("Enable Precise Location for NIBM ONE in iPhone Settings before sharing this vehicle's location.")
        }
        guard generation == current, model.isAuthenticated, model.isRemoteSession else { throw APIError.sessionChanged }
        let trip = try await model.vehicleAction(id: requestID, action: "start")
        guard generation == current, let key = trip.sharingKey else { throw APIError.sessionChanged }
        self.requestID = requestID; self.model = model; sharingKey = key
        lastSentAt = nil; lastAttempt = .distantPast; message = "Waiting for a GPS position…"
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        isSharing = true
        manager.startUpdatingLocation()
    }

    func stop(notifyServer: Bool = true) {
        let previousID = requestID, previousModel = model, previousKey = sharingKey
        generation = UUID()
        upload?.cancel(); upload = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        authorization?.resume(returning: false); authorization = nil
        requestID = nil; sharingKey = nil; isSharing = false; model = nil
        message = nil; lastSentAt = nil
        if notifyServer, let previousID, let previousModel, let previousKey {
            Task { try? await previousModel.pauseVehicleSharing(id: previousID, sharingKey: previousKey) }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let allowed = [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus)
        authorization?.resume(returning: allowed); authorization = nil
        if !allowed && isSharing { stop(); message = "Location permission was removed. Sharing stopped." }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isSharing, let requestID, let model, let key = sharingKey, upload == nil,
              Date().timeIntervalSince(lastAttempt) >= 10, let location = locations.last else { return }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 200,
              abs(location.timestamp.timeIntervalSinceNow) < 30 else {
            message = "Waiting for a current, accurate GPS position…"; return
        }
        lastAttempt = Date()
        let current = generation
        upload = Task {
            defer { if generation == current { upload = nil } }
            do {
                try await model.sendVehicleLocation(id: requestID, body: VehicleLocationBody(latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy, capturedAt: location.timestamp, sharingKey: key))
                guard generation == current else { return }
                lastSentAt = Date(); message = nil
            } catch {
                guard generation == current else { return }
                if case APIError.server(let status, _) = error, [401, 403, 409].contains(status) {
                    stop(notifyServer: false)
                }
                message = error.localizedDescription
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = error.localizedDescription
    }
}
