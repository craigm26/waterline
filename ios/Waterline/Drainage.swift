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
        if let o = await observed(rain?.observationStations) {
            out.station = o.station
            let byHour = o.hoursAgo
            out.observedIn = byHour.indices.filter { byHour[$0] != nil }.map { byHour[$0]! }
        }
        return out
    }

    /// Rain measured in each of the last 6 hours at the nearest NWS station that reported it:
    /// index 0 is the hour just past, nil where the station sent no reading for that hour.
    static func observed(_ stations: String?) async -> (station: String, hoursAgo: [Double?])? {
        guard let u = stations.flatMap(URL.init(string:)),
              let list: Stations = try? await Net.json(u, accept: "application/geo+json") else { return nil }
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
            if !byHour.isEmpty { return (s.properties.name, (0..<6).map { byHour[$0] }) }
        }
        return nil
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
    /// Water standing here hour by hour, from the measured rain of the last 6 hours through the
    /// next 3 days of forecast, drains working.
    var water: WaterTimeline?
    /// The same for NOAA Atlas 14's 100- and 1000-year 24-hour storms, starting now.
    var waterDay100: WaterTimeline?
    var waterDay1000: WaterTimeline?
    let ponds: [DrainageMap.Pond]

    static func make(_ c: CLLocationCoordinate2D, forecast: [Double], forecast72: [Double] = [], observed: [Double?] = [], frequency: RainFrequency?, now: Date = Date()) -> RainEstimate? {
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
        if !forecast72.isEmpty { e.water = WaterTimeline.make(f, at: c, observed: observed, forecast: forecast72, now: now) }
        if let h = frequency?.dayStorm(years: 100) { e.waterDay100 = WaterTimeline.whatIf("100-year day", f, at: c, hours: h, now: now) }
        if let h = frequency?.dayStorm(years: 1000) { e.waterDay1000 = WaterTimeline.whatIf("1000-year day", f, at: c, hours: h, now: now) }
        return e
    }
}

/// Water at one spot over time: rain that has fallen and rain forecast to fall, run over the
/// ground hour by hour.
///
/// The bowl model fills dips from a volume of runoff. To follow that volume through time, rain
/// adds runoff each hour (80% of it) and working drains take 0.5 in an hour back out, also in the
/// dry hours after a shower, so the water goes down again once the rain eases. Measured rain
/// and the forecast are official; the depth is Waterline's estimate.
struct WaterTimeline: Hashable {
    struct Point: Identifiable, Hashable {
        let date: Date
        let rainIn: Double
        let ft: Double
        let measured: Bool
        var id: Date { date }
    }
    let points: [Point]
    let now: Date
    /// nil for the forecast; otherwise the what-if storm's name. A what-if starts at hour 0, now.
    var whatIf: String? = nil

    /// "Tue 3 AM" for the forecast, "hour 14" for a what-if storm.
    func when(_ p: Point) -> String {
        guard whatIf != nil else { return SpotReport.day.string(from: p.date) }
        return "hour \(Int((p.date.timeIntervalSince(now) / 3600).rounded()))"
    }

    var current: Point? { points.last { $0.date <= now } }
    var peak: Point? {
        let ahead = points.filter { $0.date >= now }
        guard let top = ahead.max(by: { $0.ft < $1.ft }), top.ft >= 0.05 else { return nil }
        return top
    }
    var measuredIn: Double { points.filter(\.measured).reduce(0) { $0 + $1.rainIn } }
    var forecastIn: Double { points.filter { !$0.measured }.reduce(0) { $0 + $1.rainIn } }
    var isDry: Bool { points.allSatisfy { $0.ft < 0.05 } }

    static func make(_ f: DrainageField, at c: CLLocationCoordinate2D, observed: [Double?], forecast: [Double], now: Date) -> WaterTimeline {
        let hour = 3600.0
        let start = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        var rows: [(Date, Double, Bool)] = []
        for (k, v) in observed.enumerated().reversed() { rows.append((start.addingTimeInterval(-Double(k + 1) * hour), v ?? 0, true)) }
        for (k, v) in forecast.enumerated() { rows.append((start.addingTimeInterval(Double(k) * hour), v, false)) }
        var runoffIn = 0.0
        var memo: [Int: Double] = [:]
        let points = rows.map { (date, rain, measured) -> Point in
            runoffIn = max(0, runoffIn + rain * DrainageAssumptions.runoff - DrainageAssumptions.drainInPerHour)
            let key = Int((runoffIn * 200).rounded())          // 0.005 in steps
            let ft: Double
            if let m = memo[key] { ft = m } else {
                let r = f.model.run(runoffM: Double(key) / 200 * 0.0254)
                ft = key == 0 ? 0 : DrainageMap(patches: [], paths: [], ponds: [], rainIn: 0, result: r, field: f).depthFt(c)
                memo[key] = ft
            }
            return Point(date: date, rainIn: rain, ft: ft, measured: measured)
        }
        return WaterTimeline(points: points, now: now)
    }

    /// A design storm starting now, then a dry day so the drains can be seen catching up. The
    /// hours are arranged by the alternating-block method: the heaviest hour in the middle of the
    /// day, the next heaviest on either side of it, so the storm builds and eases like a real one.
    static func whatIf(_ name: String, _ f: DrainageField, at c: CLLocationCoordinate2D, hours: [Double], now: Date) -> WaterTimeline {
        let start = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        var shaped = [Double](repeating: 0, count: hours.count)
        let mid = hours.count / 2
        for (k, v) in hours.sorted(by: >).enumerated() {
            let i = mid + (k % 2 == 0 ? k / 2 : -(k + 1) / 2)
            if shaped.indices.contains(i) { shaped[i] = v }
        }
        var t = make(f, at: c, observed: [], forecast: shaped + Array(repeating: 0, count: 24), now: start)
        t.whatIf = name
        return t
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
