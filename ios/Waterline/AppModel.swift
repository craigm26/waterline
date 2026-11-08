import Foundation
import CoreLocation
import SwiftUI

/// Shared state: where you are (GPS) or the spot you pinned on the map, and the report for it.
@MainActor
final class AppModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Tab: Hashable { case here, map, ar }

    @Published var tab: Tab = .here
    @Published var gps: CLLocationCoordinate2D?
    @Published var gpsAccuracyM: Double?
    @Published var pinned: CLLocationCoordinate2D?
    @Published var report: SpotReport?
    @Published var loading = false
    @Published var locationDenied = false
    @Published var arScenarioID: String?
    /// Vision Pro: the depth shown in the room, and whether a timeline is playing.
    @Published var roomDepthFt: Double?
    @Published var roomPlaying = false

    private let manager = CLLocationManager()
    private var reportedAt: CLLocationCoordinate2D?
    private var job: Task<Void, Never>?

    var target: CLLocationCoordinate2D? { pinned ?? gps }
    var usingPin: Bool { pinned != nil }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 15
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: locationDenied = true
        default: manager.startUpdatingLocation()
        }
    }

    func pin(_ c: CLLocationCoordinate2D) { pinned = c; refresh(force: true) }
    func unpin() { pinned = nil; refresh(force: true) }

    /// Rebuild the report when the target moved more than 40 m, or when forced.
    func refresh(force: Bool = false) {
        guard let t = target else { return }
        if !force, let last = reportedAt, Geo.distance(last, t) < 40 { return }
        reportedAt = t
        job?.cancel()
        loading = true
        job = Task {
            let r = await SpotReport.build(at: t)
            guard !Task.isCancelled else { return }
            report = r
            loading = false
            if arScenarioID == nil || !r.scenarios.contains(where: { $0.id == arScenarioID }) {
                arScenarioID = r.scenarios.first(where: { $0.depthFt != nil && !$0.isStressTest })?.id ?? r.scenarios.first?.id
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        Task { @MainActor in
            locationDenied = (s == .denied || s == .restricted)
            if s == .authorizedWhenInUse || s.rawValue == 3 { manager.startUpdatingLocation() }   // 3 = always, unavailable by name on visionOS
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Vision Pro locates by Wi-Fi, so its fixes are looser than a phone's GPS.
        #if os(visionOS)
        let worst = 500.0
        #else
        let worst = 100.0
        #endif
        guard let l = locations.last, l.horizontalAccuracy >= 0, l.horizontalAccuracy < worst else { return }
        let c = l.coordinate, acc = l.horizontalAccuracy
        Task { @MainActor in
            gps = c
            gpsAccuracyM = acc
            if pinned == nil { refresh() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
