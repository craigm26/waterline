import Foundation
import CoreLocation
import CoreMotion
import SwiftUI

/// Compass heading (true north when available), for the arrows to higher ground and drains.
@MainActor
final class Compass: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var heading: Double?
    private let manager = CLLocationManager()

    func start() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.delegate = self
        manager.headingFilter = 2
        manager.startUpdatingHeading()
    }
    func stop() { manager.stopUpdatingHeading() }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        let v = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        Task { @MainActor in heading = v }
    }
}

/// Barometer: height change since `start()`, in feet. Good to about a foot over a few minutes,
/// which is enough to tell how far a floor, porch or garage sits above the street.
@MainActor
final class FloorMeter: ObservableObject {
    @Published var deltaFt: Double?
    @Published var running = false
    private let altimeter = CMAltimeter()

    static var available: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    func start() {
        guard Self.available else { return }
        deltaFt = 0
        running = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let d = data else { return }
            Task { @MainActor in self?.deltaFt = d.relativeAltitude.doubleValue * Geo.ftPerM }
        }
    }

    func stop() { altimeter.stopRelativeAltitudeUpdates(); running = false }
}

/// An arrow that points at a target as you turn the phone.
struct PointerChip: View {
    let label: String
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D
    let heading: Double?

    var body: some View {
        let bearing = Geo.bearing(from: from, to: to)
        HStack(spacing: 6) {
            Image(systemName: "location.north.fill")
                .rotationEffect(.degrees(bearing - (heading ?? 0)))
                .animation(.easeOut(duration: 0.2), value: heading)
            Text("\(label) · \(Geo.walk(Geo.distance(from, to)))\(heading == nil ? " " + Geo.compass(from: from, to: to) : "")")
                .font(.caption.bold())
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
