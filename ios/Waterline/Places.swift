import Foundation
import CoreLocation

/// A place's map and AR layers. San Francisco's are bundled (scripts/build_ios_data.py): the top-500
/// drains, the 50 worst street low spots, 26k past 311 flooding reports and the SFPUC flood zone.
/// Other places come from a downloaded layers pack (scripts/build_region_layers.py) or, without
/// one, live from FEMA and USACE (LiveLayers). All three have the same shape.
struct Places: Codable {
    struct Drain: Codable, Identifiable {
        let rank: Int, id: String, lon: Double, lat: Double, sump_m: Double, flood311: Int, hood: String, deep_pit: Bool
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
        /// SF's drains are ranked citywide; other cities' are listed unranked.
        var ranked: Bool { rank < 900_000 }
        var label: String { ranked ? "Drain #\(rank)" : "Storm drain" }
    }
    struct LowSpot: Codable, Identifiable {
        let rank: Int, name: String, lon: Double, lat: Double, max_depth_m: Double, area_m2: Int, flood311: Int, in_zone: Bool
        var id: Int { rank }
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }
    struct Line: Codable { let kind: String; let path: [[Double]] }     // levee or floodwall, [lon, lat]
    struct Pump: Codable { let name: String; let lon: Double; let lat: Double
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }
    var drains: [Drain]
    let hotspots: [LowSpot]
    var flood311: [[Double]]
    let zone_rings: [[[Double]]]
    var flood311_total: Int
    var region: String? = nil      // nil = SF, "live" = fetched by LiveLayers
    var name: String? = nil
    var bbox: [Double]? = nil
    var zone_label: String? = nil
    var levees: [Line]? = nil
    var pumps: [Pump]? = nil
    var reports_label: String? = nil

    var zoneLabel: String { zone_label ?? "SFPUC 100-yr flood zone" }
    var isSF: Bool { region == nil }
    var reportsLabel: String { reports_label ?? "311 flooding reports" }

    static let shared: Places? = {
        guard let url = Bundle.main.url(forResource: "places", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Places.self, from: data)
    }()

    private static var packs: [Places]?
    private static let lock = NSLock()
    static func reload() { lock.lock(); packs = nil; lock.unlock() }

    private static var installed: [Places] {
        lock.lock(); defer { lock.unlock() }
        if let p = packs { return p }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: PackStore.root.path)) ?? []
        let out: [Places] = names.filter { $0.hasSuffix("-layers") }.compactMap { id in
            let region = String(id.dropLast("-layers".count))
            guard let u = PackStore.file(id, "\(region)_layers.json"), let d = try? Data(contentsOf: u) else { return nil }
            return try? JSONDecoder().decode(Places.self, from: d)
        }
        packs = out
        return out
    }

    /// The best layers for this spot: SF's bundled ones, a downloaded pack, or the cached live fetch.
    static func covering(_ c: CLLocationCoordinate2D) -> Places? {
        if inSF(c) { return shared }
        let base = installed.first(where: { ($0.bbox ?? []).count == 4 && ($0.bbox![0]...$0.bbox![2]).contains(c.longitude) && ($0.bbox![1]...$0.bbox![3]).contains(c.latitude) })
            ?? LiveLayers.cached(near: c)
        return base.map { LiveLayers.withCity($0, near: c) }
    }

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

    /// The nearest point of each levee or floodwall within `m`, closest first, skipping points
    /// within 300 m of one already kept so one long levee doesn't fill the view.
    func leveesNear(_ c: CLLocationCoordinate2D, within m: Double, limit: Int) -> [(kind: String, at: CLLocationCoordinate2D, metres: Double)] {
        var best: [(kind: String, at: CLLocationCoordinate2D, metres: Double)] = []
        for l in levees ?? [] {
            var near: (CLLocationCoordinate2D, Double)?
            for p in l.path {
                let q = CLLocationCoordinate2D(latitude: p[1], longitude: p[0]), d = Geo.distance(c, q)
                if d <= m, d < (near?.1 ?? .infinity) { near = (q, d) }
            }
            if let n = near { best.append((l.kind, n.0, n.1)) }
        }
        var kept: [(kind: String, at: CLLocationCoordinate2D, metres: Double)] = []
        for b in best.sorted(by: { $0.metres < $1.metres }) where kept.count < limit {
            if !kept.contains(where: { Geo.distance($0.at, b.at) < 300 }) { kept.append(b) }
        }
        return kept
    }
}

/// A drain and how far it is, for lists.
struct NearDrain: Identifiable {
    let drain: Places.Drain
    let metres: Double
    var id: String { drain.id }
}
