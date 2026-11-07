import Foundation
import CoreLocation
import SwiftUI

/// Live water estimates: rain the NWS measured or forecast, run through DrainageModel on the ground
/// grid. The rain is official; the drain and runoff figures are assumptions and the UI says so.
enum DrainageAssumptions {
    /// Share of rain that runs off. City streets run high, open ground far lower.
    static let runoff = 0.8
    /// What working inlets are assumed to swallow, in/hour. No pipe capacities are public.
    static let drainInPerHour = 0.5
    static let windowM = 1_500.0
}

enum StormCase: String, CaseIterable, Identifiable {
    case last6 = "Last 6 h", next24 = "Next 24 h", next72 = "Next 3 days", year10 = "10-yr hour", year100 = "100-yr hour"
    case day100 = "100-yr day", day1000 = "1000-yr day", stress = "Stress test"
    var id: String { rawValue }
    /// Where the rain comes from, for the labels under the map.
    var rainSource: (String, Provenance) {
        switch self {
        case .stress: return ("stress test, not a forecast", .assumed)
        case .last6: return ("measured, last 6 h", .official)
        case .next24: return ("NWS forecast, next 24 h", .official)
        case .next72: return ("NWS forecast, next 3 days", .official)
        case .day100: return ("NOAA Atlas 14, the 100-year 24-hour storm", .official)
        case .day1000: return ("NOAA Atlas 14, the 1000-year 24-hour storm", .official)
        case .year10: return ("NOAA Atlas 14, the 10-year storm's heaviest hour", .official)
        case .year100: return ("NOAA Atlas 14, the 100-year storm's heaviest hour", .official)
        }
    }
}

/// Rain measured at the nearest NWS station, plus the forecast, by the hour.
struct RainSeries {
    var observedIn: [Double]?      // nil when the station didn't report rain
    var station: String?
    var forecastIn: [Double]
    var forecast72In: [Double] = []
    var frequency: RainFrequency?
    static let stress = [2.0]

    func hours(_ s: StormCase) -> [Double] {
        switch s {
        case .last6: return observedIn ?? []
        case .next24: return forecastIn
        case .next72: return forecast72In
        case .day100: return frequency?.dayStorm(years: 100) ?? []
        case .day1000: return frequency?.dayStorm(years: 1000) ?? []
        case .year10: return frequency?.hour10.map { [$0] } ?? []
        case .year100: return frequency?.hour100.map { [$0] } ?? []
        case .stress: return Self.stress
        }
    }

    private struct Stations: Decodable { let features: [F]; struct F: Decodable { let properties: P; struct P: Decodable { let stationIdentifier: String; let name: String } } }
    private struct Obs: Decodable {
        let features: [F]
        struct F: Decodable { let properties: P }
        struct P: Decodable { let timestamp: String; let precipitationLastHour: V?; struct V: Decodable { let value: Double? } }
    }

    static func load(_ c: CLLocationCoordinate2D) async -> RainSeries {
        async let freq = RainFrequency.load(c)
        let rain = try? await RainOutlook.load(c)
        var out = RainSeries(observedIn: nil, station: nil, forecastIn: rain?.hourlyNext24In ?? [], forecast72In: rain?.hourlyNext72In ?? [], frequency: await freq)
        guard let u = rain?.observationStations.flatMap(URL.init(string:)),
              let list: Stations = try? await Net.json(u, accept: "application/geo+json") else { return out }
        for s in list.features.prefix(3) {
            guard let url = URL(string: "https://api.weather.gov/stations/\(s.properties.stationIdentifier)/observations?limit=40"),
                  let o: Obs = try? await Net.json(url, accept: "application/geo+json") else { continue }
            let f = ISO8601DateFormatter()
            var byHour: [Int: Double] = [:]
            let now = Date()
            for row in o.features {
                guard let t = f.date(from: row.properties.timestamp), now.timeIntervalSince(t) < 6 * 3600,
                      let mm = row.properties.precipitationLastHour?.value else { continue }
                byHour[Int(now.timeIntervalSince(t) / 3600), default: 0] = max(byHour[Int(now.timeIntervalSince(t) / 3600)] ?? 0, mm / 25.4)
            }
            if !byHour.isEmpty {
                out.observedIn = byHour.keys.sorted().map { byHour[$0]! }
                out.station = s.properties.name
                break
            }
        }
        return out
    }
}

/// A grid window, ready to model.
final class DrainageField {
    let window: ElevationGrid.Window
    let model: DrainageModel
    init(_ w: ElevationGrid.Window) {
        window = w
        model = DrainageModel(rows: w.rows, cols: w.cols, resM: w.resM, ground: w.groundM, bowl: w.bowlM)
    }

    private static var cached: (key: String, field: DrainageField)?
    private static let lock = NSLock()

    /// The modeled area around a spot, or nil where no ground grid is on the phone.
    static func near(_ c: CLLocationCoordinate2D) -> DrainageField? {
        guard let g = ElevationGrid.covering(c) else { return nil }
        let key = "\(g.name)-\(Int(c.latitude * 200))-\(Int(c.longitude * 200))"   // about 500 m
        lock.lock()
        if let h = cached, h.key == key { lock.unlock(); return h.field }
        lock.unlock()
        guard let w = g.window(near: c, radiusM: DrainageAssumptions.windowM) else { return nil }
        let f = DrainageField(w)
        lock.lock(); cached = (key, f); lock.unlock()
        return f
    }

    static func runoffM(_ hours: [Double], drainsWorking: Bool) -> Double {
        let drain = drainsWorking ? DrainageAssumptions.drainInPerHour : 0
        return hours.reduce(0) { $0 + max(0, $1 * DrainageAssumptions.runoff - drain) } * 0.0254
    }
}

/// What the Map draws.
struct DrainageMap {
    struct Patch: Identifiable { let id: Int; let corners: [CLLocationCoordinate2D]; let band: Int; let area: Int }
    struct Pond: Identifiable { let id: Int; let coordinate: CLLocationCoordinate2D; let maxFt: Double }
    var patches: [Patch]
    var paths: [[CLLocationCoordinate2D]]
    var ponds: [Pond]
    var rainIn: Double
    var result: DrainageModel.Result
    var field: DrainageField

    /// How deep the water stands at this spot: the highest computed water surface within `radiusM`,
    /// above the ground here. One grid cell is finer than a GPS fix, so a pond beside you counts if
    /// its surface is above your ground.
    func depthFt(_ c: CLLocationCoordinate2D, radiusM: Double = 15) -> Double {
        let w = field.window
        guard let i0 = w.index(c) else { return 0 }
        let here = w.groundM[i0]
        var best = Double(result.depthM[i0])
        if !here.isNaN {
            let k = Int((radiusM / w.resM).rounded(.up)), r0 = i0 / w.cols, c0 = i0 % w.cols
            for dr in -k...k {
                for dc in -k...k where Double(dr * dr + dc * dc) * w.resM * w.resM <= radiusM * radiusM {
                    let r = r0 + dr, cc = c0 + dc
                    guard r >= 0, cc >= 0, r < w.rows, cc < w.cols else { continue }
                    let j = r * w.cols + cc, d = result.depthM[j], g = w.groundM[j]
                    guard d >= 0.01, !g.isNaN else { continue }
                    best = max(best, Double(g + d - here))
                }
            }
        }
        return max(0, best) * Geo.ftPerM
    }

    static func build(_ f: DrainageField, hours: [Double], drainsWorking: Bool) -> DrainageMap {
        let w = f.window, m = f.model
        let r = m.run(runoffM: DrainageField.runoffM(hours, drainsWorking: drainsWorking))
        // Same-depth runs of cells, joined across rows, so a block of water is one polygon.
        func band(_ ft: Double) -> Int { ft < 0.1 ? -1 : ft < 0.5 ? 0 : ft < 1.5 ? 1 : 2 }
        var open: [String: (r0: Int, r1: Int, c0: Int, c1: Int, b: Int)] = [:]
        var done: [(r0: Int, r1: Int, c0: Int, c1: Int, b: Int)] = []
        for row in 0..<w.rows {
            var next: [String: (r0: Int, r1: Int, c0: Int, c1: Int, b: Int)] = [:]
            var col = 0
            while col < w.cols {
                let b = band(Double(r.depthM[row * w.cols + col]) * Geo.ftPerM)
                guard b >= 0 else { col += 1; continue }
                var end = col
                while end + 1 < w.cols, band(Double(r.depthM[row * w.cols + end + 1]) * Geo.ftPerM) == b { end += 1 }
                let k = "\(col)-\(end)-\(b)"
                if var o = open.removeValue(forKey: k) { o.r1 = row; next[k] = o } else { next[k] = (row, row, col, end, b) }
                col = end + 1
            }
            done += open.values
            open = next
        }
        done += open.values
        let rects = done.sorted { ($0.r1 - $0.r0 + 1) * ($0.c1 - $0.c0 + 1) > ($1.r1 - $1.r0 + 1) * ($1.c1 - $1.c0 + 1) }.prefix(450)
        let patches = rects.enumerated().map { i, x in
            Patch(id: i, corners: [w.coordinate(row: Double(x.r0), col: Double(x.c0)), w.coordinate(row: Double(x.r0), col: Double(x.c1 + 1)),
                                   w.coordinate(row: Double(x.r1 + 1), col: Double(x.c1 + 1)), w.coordinate(row: Double(x.r1 + 1), col: Double(x.c0))],
                  band: x.b, area: (x.r1 - x.r0 + 1) * (x.c1 - x.c0 + 1))
        }
        let minCells = Int32(40_000 / (w.resM * w.resM))   // 4 hectares of ground feeding it
        let paths = m.flowPaths(minCells: minCells, limit: 80).map { p in
            p.map { w.coordinate(row: Double($0 / w.cols) + 0.5, col: Double($0 % w.cols) + 0.5) }
        }
        let ponds = r.ponds.filter { $0.maxDepthM * Geo.ftPerM >= 0.3 }.prefix(25).enumerated().map { i, p in
            Pond(id: i, coordinate: w.coordinate(row: Double(p.row) + 0.5, col: Double(p.col) + 0.5), maxFt: p.maxDepthM * Geo.ftPerM)
        }
        return DrainageMap(patches: patches, paths: paths, ponds: Array(ponds), rainIn: hours.reduce(0, +), result: r, field: f)
    }
}

/// The estimate for one report: forecast rain, drains working and blocked, at this spot.
struct RainEstimate {
    let forecastIn: Double
    let workingFt: Double, blockedFt: Double, stressFt: Double
    /// NOAA Atlas 14's heaviest hour of the 10- and 100-year storms, drains working.
    var year10: (inches: Double, ft: Double)?
    var year100: (inches: Double, ft: Double)?
    /// NOAA Atlas 14's 24-hour 100- and 1000-year storms, drains working.
    var day100: (inches: Double, ft: Double)?
    var day1000: (inches: Double, ft: Double)?
    /// The next 3 days of forecast rain, adding up: water standing here after each 12 hours, drains working.
    var timeline: [(hours: Int, rainIn: Double, ft: Double)] = []
    let ponds: [DrainageMap.Pond]

    static func make(_ c: CLLocationCoordinate2D, forecast: [Double], forecast72: [Double] = [], frequency: RainFrequency?) -> RainEstimate? {
        guard let f = DrainageField.near(c) else { return nil }
        let work = DrainageMap.build(f, hours: forecast, drainsWorking: true)
        let block = DrainageMap.build(f, hours: forecast, drainsWorking: false)
        let stress = DrainageMap.build(f, hours: RainSeries.stress, drainsWorking: false)
        var e = RainEstimate(forecastIn: forecast.reduce(0, +), workingFt: work.depthFt(c), blockedFt: block.depthFt(c), stressFt: stress.depthFt(c), ponds: block.ponds)
        if let i = frequency?.hour10 { e.year10 = (i, DrainageMap.build(f, hours: [i], drainsWorking: true).depthFt(c)) }
        if let i = frequency?.hour100 { e.year100 = (i, DrainageMap.build(f, hours: [i], drainsWorking: true).depthFt(c)) }
        for (y, key) in [(100, \RainEstimate.day100), (1000, \RainEstimate.day1000)] {
            if let h = frequency?.dayStorm(years: y) { e[keyPath: key] = (h.reduce(0, +), DrainageMap.build(f, hours: h, drainsWorking: true).depthFt(c)) }
        }
        if forecast72.reduce(0, +) >= 0.05 {
            e.timeline = stride(from: 12, through: min(72, forecast72.count), by: 12).map { n in
                let h = Array(forecast72.prefix(n))
                return (n, h.reduce(0, +), DrainageMap.build(f, hours: h, drainsWorking: true).depthFt(c))
            }
        }
        return e
    }
}

@MainActor
final class DrainageStore: ObservableObject {
    static let shared = DrainageStore()
    @Published var map: DrainageMap?
    @Published var rain: RainSeries?
    @Published var noGrid = false
    @Published var working = false
    private var rainAt: (c: CLLocationCoordinate2D, t: Date)?

    func update(center c: CLLocationCoordinate2D, storm: StormCase, drainsWorking: Bool) async {
        working = true
        defer { working = false }
        if rainAt == nil || Geo.distance(rainAt!.c, c) > 5_000 || Date().timeIntervalSince(rainAt!.t) > 600 {
            rain = await RainSeries.load(c)
            rainAt = (c, Date())
        }
        let hours = rain?.hours(storm) ?? []
        let built: DrainageMap? = await Task.detached(priority: .userInitiated) {
            DrainageField.near(c).map { DrainageMap.build($0, hours: hours, drainsWorking: drainsWorking) }
        }.value
        noGrid = built == nil
        map = built
    }
}
