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
                arScenarioID = r.scenarios.first(where: { $0.depthFt != nil })?.id ?? r.scenarios.first?.id
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        Task { @MainActor in
            locationDenied = (s == .denied || s == .restricted)
            if s == .authorizedWhenInUse || s == .authorizedAlways { manager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 100 else { return }
        let c = l.coordinate, acc = l.horizontalAccuracy
        Task { @MainActor in
            gps = c
            gpsAccuracyM = acc
            if pinned == nil { refresh() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
