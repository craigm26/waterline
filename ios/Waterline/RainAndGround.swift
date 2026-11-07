import Foundation
import CoreLocation

/// NWS gridpoint rain forecast for any US spot (api.weather.gov), summed over the next 24 and 72 hours.
struct RainOutlook {
    let next24In: Double
    let next72In: Double
    let chance24Pct: Int
    let updated: String
    let source: URL
    /// Forecast by the hour for the next 24 hours, in.
    var hourlyNext24In: [Double] = []
    var observationStations: String?

    private struct Points: Decodable { struct P: Decodable { let forecastGridData: String; let observationStations: String? }; let properties: P }
    private struct Grid: Decodable {
        struct Series: Decodable { struct V: Decodable { let validTime: String; let value: Double? }; let values: [V] }
        struct P: Decodable { let updateTime: String?; let quantitativePrecipitation: Series; let probabilityOfPrecipitation: Series }
        let properties: P
    }

    static func load(_ c: CLLocationCoordinate2D) async throws -> RainOutlook {
        let pts: Points = try await Net.json(URL(string: String(format: "https://api.weather.gov/points/%.4f,%.4f", c.latitude, c.longitude))!,
                                             accept: "application/geo+json")
        let url = URL(string: pts.properties.forecastGridData)!
        let g: Grid = try await Net.json(url, accept: "application/geo+json")
        let now = Date()
        func sum(_ hours: Double) -> Double {
            g.properties.quantitativePrecipitation.values.reduce(0) { acc, v in
                guard let sp = span(v.validTime), let mm = v.value, sp.1 > 0 else { return acc }
                let t0 = sp.0, h = sp.1
                let start = max(t0, now), end = min(t0.addingTimeInterval(h * 3600), now.addingTimeInterval(hours * 3600))
                guard end > start else { return acc }
                return acc + mm * end.timeIntervalSince(start) / (h * 3600)
            } / 25.4
        }
        let pop = g.properties.probabilityOfPrecipitation.values.compactMap { v -> Double? in
            guard let sp = span(v.validTime), sp.0.addingTimeInterval(sp.1 * 3600) > now, sp.0 < now.addingTimeInterval(86400) else { return nil }
            return v.value
        }.max() ?? 0
        func hour(_ i: Int) -> Double {
            let a = now.addingTimeInterval(Double(i) * 3600), b = a.addingTimeInterval(3600)
            return g.properties.quantitativePrecipitation.values.reduce(0) { acc, v in
                guard let sp = span(v.validTime), let mm = v.value, sp.1 > 0 else { return acc }
                let start = max(sp.0, a), end = min(sp.0.addingTimeInterval(sp.1 * 3600), b)
                return end > start ? acc + mm * end.timeIntervalSince(start) / (sp.1 * 3600) / 25.4 : acc
            }
        }
        return RainOutlook(next24In: sum(24), next72In: sum(72), chance24Pct: Int(pop), updated: g.properties.updateTime ?? "", source: url,
                           hourlyNext24In: (0..<24).map(hour), observationStations: pts.properties.observationStations)
    }

    /// "2026-11-06T18:00:00+00:00/P1DT6H" -> (start, hours)
    static func span(_ s: String) -> (Date, Double)? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let t0 = ISO8601DateFormatter().date(from: String(parts[0])) else { return nil }
        var d = String(parts[1]).dropFirst()   // drop "P"
        var hours = 0.0
        if let i = d.firstIndex(of: "D") { hours += 24 * (Double(d[d.startIndex..<i]) ?? 0); d = d[d.index(after: i)...] }
        if d.first == "T" { d = d.dropFirst() }
        if let i = d.firstIndex(of: "H") { hours += Double(d[d.startIndex..<i]) ?? 0 }
        return (t0, hours)
    }
}

/// Ground elevation where you stand. Online: USGS Elevation Point Query Service, which reads the
/// best 3DEP DEM there (1 m lidar in SF). Offline in SF: the bundled 5 m grid.
enum GroundElevation {
    struct Result { let navd88Ft: Double; let source: String }

    private struct EPQS: Decodable {
        let value: Double?
        enum K: String, CodingKey { case value }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            if let v = try? c.decode(Double.self, forKey: .value) { value = v }
            else if let s = try? c.decode(String.self, forKey: .value) { value = Double(s) }
            else { value = nil }
        }
    }

    /// 1 m pack (offline, exact) first, then USGS EPQS (online), then the bundled 5 m grid.
    static func load(_ c: CLLocationCoordinate2D) async -> Result? {
        if let v = await Task.detached(priority: .userInitiated, operation: { Ground1m.ground(c) }).value {
            return Result(navd88Ft: v, source: "USGS 3DEP 1 m lidar, downloaded pack (offline)")
        }
        let url = URL(string: String(format: "https://epqs.nationalmap.gov/v1/json?x=%.6f&y=%.6f&wkid=4326&units=Feet&includeDate=false",
                                     c.longitude, c.latitude))!
        if let r: EPQS = try? await Net.json(url), let v = r.value, v > -1000 {
            return Result(navd88Ft: v, source: "USGS 3DEP (EPQS), ft NAVD88")
        }
        if let g = ElevationGrid.covering(c), let s = g.sample(c) {
            return Result(navd88Ft: s.groundNAVD88Ft, source: "USGS 3DEP, \(Int(g.resolutionM)) m \(g.name) grid (offline)")
        }
        return nil
    }
}
