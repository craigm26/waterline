import Foundation
import CoreLocation

/// Bundled city layers (scripts/build_ios_data.py -> places.json): the top-500 drains from the
/// citywide ranking, the 50 worst street low spots, 26k past 311 flooding reports and the SFPUC
/// 100-year storm flood zone.
struct Places: Decodable {
    struct Drain: Decodable, Identifiable {
        let rank: Int, id: String, lon: Double, lat: Double, sump_m: Double, flood311: Int, hood: String, deep_pit: Bool
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }
    struct LowSpot: Decodable, Identifiable {
        let rank: Int, name: String, lon: Double, lat: Double, max_depth_m: Double, area_m2: Int, flood311: Int, in_zone: Bool
        var id: Int { rank }
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }
    let drains: [Drain]
    let hotspots: [LowSpot]
    let flood311: [[Double]]
    let zone_rings: [[[Double]]]
    let flood311_total: Int

    static let shared: Places? = {
        guard let url = Bundle.main.url(forResource: "places", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Places.self, from: data)
    }()

    /// Rough SF land box; outside it the city layers say nothing.
    static func inSF(_ c: CLLocationCoordinate2D) -> Bool {
        (37.703...37.835).contains(c.latitude) && (-122.53...(-122.355)).contains(c.longitude)
    }

    func drains(near c: CLLocationCoordinate2D, within m: Double, limit: Int) -> [(Drain, Double)] {
        drains.lazy.map { ($0, Geo.distance(c, $0.coordinate)) }.filter { $0.1 <= m }
            .sorted { $0.1 < $1.1 }.prefix(limit).map { $0 }
    }

    func flood311Count(near c: CLLocationCoordinate2D, within m: Double) -> Int {
        // cheap box test first, then the real distance
        let dLat = m / 111_132, dLon = m / (111_320 * cos(c.latitude * .pi / 180))
        return flood311.reduce(0) { n, p in
            guard abs(p[1] - c.latitude) <= dLat, abs(p[0] - c.longitude) <= dLon else { return n }
            return Geo.distance(c, .init(latitude: p[1], longitude: p[0])) <= m ? n + 1 : n
        }
    }

    func flood311Points(near c: CLLocationCoordinate2D, within m: Double) -> [CLLocationCoordinate2D] {
        let dLat = m / 111_132, dLon = m / (111_320 * cos(c.latitude * .pi / 180))
        return flood311.compactMap { p in
            guard abs(p[1] - c.latitude) <= dLat, abs(p[0] - c.longitude) <= dLon else { return nil }
            return .init(latitude: p[1], longitude: p[0])
        }
    }

    func nearestLowSpot(to c: CLLocationCoordinate2D, within m: Double) -> (LowSpot, Double)? {
        hotspots.map { ($0, Geo.distance(c, $0.coordinate)) }.filter { $0.1 <= m }.min { $0.1 < $1.1 }
    }

    func inFloodZone(_ c: CLLocationCoordinate2D) -> Bool { Geo.contains(zone_rings, lon: c.longitude, lat: c.latitude) }
}

/// A drain and how far it is, for lists.
struct NearDrain: Identifiable {
    let drain: Places.Drain
    let metres: Double
    var id: String { drain.id }
}
