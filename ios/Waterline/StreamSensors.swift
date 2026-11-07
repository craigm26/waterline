import Foundation
import CoreLocation

/// Water sensors that aren't NOAA forecast points: USGS stream gauges anywhere in the US, and the
/// state and local networks a place's manifest lists (California DWR CDEC and others). Read live from
/// each source near the spot and never copied into a pack. They carry no flood stages, so they're
/// shown with their readings and don't move the risk level.
struct Sensor: Identifiable, Hashable {
    enum Network: String { case usgs = "USGS", cdec = "California DWR", floodnet = "FloodNet", harris = "Harris County", stormsense = "StormSense" }
    struct Reading: Hashable { let label: String; let value: String; let time: Date? }

    let id: String
    let network: Network
    let name: String
    let coordinate: CLLocationCoordinate2D
    let readings: [Reading]
    let page: URL?
    /// Street flood sensors go in their own AR filter; river and reservoir sensors go with Rivers.
    var street = false
    /// What the reading means in plain words, shown on the sheet.
    var note: String?
    /// 0 ok, 1 water present (street sensors only).
    var severity = 0

    static func == (a: Sensor, b: Sensor) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var headline: String {
        guard let r = readings.first else { return "no recent reading" }
        return network == .floodnet ? (r.value == "None" ? "no floods recorded" : "\(r.value) floods recorded") : r.value
    }

    /// Within `km` of a spot, from every network that covers it, nearest first. A sensor within
    /// 150 m of a NOAA gauge or of one already listed is the same site and is dropped.
    static func near(_ c: CLLocationCoordinate2D, km: Double = 30, skipping gauges: [RiverGauge]) async -> [Sensor] {
        var groups = await MainActor.run { PackStore.shared.manifest?.groups }
        if groups == nil { await PackStore.shared.load(); groups = await MainActor.run { PackStore.shared.manifest?.groups } }
        let local = groups?.first(where: { $0.contains(c) })?.sensors
        async let usgs = USGSWater.near(c, km: km)
        async let cdec = CDEC.near(c, km: km, stations: local?.cdec ?? [])
        async let street = StreetSensors.near(c, km: km, feeds: local)
        var taken = gauges.map(\.coordinate)
        var out: [Sensor] = []
        for s in await usgs + cdec + street {
            if !s.street, taken.contains(where: { Geo.distance($0, s.coordinate) < 150 }) { continue }
            taken.append(s.coordinate)
            out.append(s)
        }
        return out.sorted { Geo.distance(c, $0.coordinate) < Geo.distance(c, $1.coordinate) }
    }

    static let stale: TimeInterval = 3 * 86400

    static func ago(_ t: Date?) -> String {
        guard let t else { return "" }
        let m = Int(Date().timeIntervalSince(t) / 60)
        return m < 90 ? "\(max(m, 1)) min ago" : m < 48 * 60 ? "\(m / 60) h ago" : "\(m / 1440) days ago"
    }
}

/// The station lists a place's manifest carries for networks with no search by location
/// (regions/sensors.json, built by scripts/build_sensors.py).
struct SensorFeeds: Decodable {
    struct Station: Decodable { let id: String; let name: String; let lat: Double; let lon: Double; let kind: String? }
    let cdec: [Station]?
    let floodnet: Bool?
    let harris: Bool?
    let stormsense: Bool?
}

// MARK: USGS

/// USGS Water Data OGC API: the latest gage height and discharge at stream sites near a spot.
enum USGSWater {
    private static let base = "https://api.waterdata.usgs.gov/ogcapi/v0/collections"
    private struct Latest: Decodable {
        struct F: Decodable {
            struct P: Decodable { let monitoring_location_id: String; let parameter_code: String; let time: String; let value: String?; let unit_of_measure: String? }
            struct G: Decodable { let coordinates: [Double] }
            let properties: P; let geometry: G?
        }
        let features: [F]
    }
    private struct Sites: Decodable {
        struct F: Decodable { struct P: Decodable { let monitoring_location_name: String?; let site_type_code: String? }; let id: String; let properties: P }
        let features: [F]
    }

    static func near(_ c: CLLocationCoordinate2D, km: Double) async -> [Sensor] {
        let dLat = km / 111, dLon = km / (111 * cos(c.latitude * .pi / 180))
        let bbox = String(format: "%.4f,%.4f,%.4f,%.4f", c.longitude - dLon, c.latitude - dLat, c.longitude + dLon, c.latitude + dLat)
        guard let u = URL(string: "\(base)/latest-continuous/items?f=json&bbox=\(bbox)&parameter_code=00065,00060&limit=500&properties=monitoring_location_id,parameter_code,time,value,unit_of_measure"),
              let l: Latest = try? await Net.json(u, accept: "application/geo+json") else { return [] }
        let iso = ISO8601DateFormatter()
        var by: [String: (at: CLLocationCoordinate2D, stage: (Double, Date)?, flow: (Double, Date)?)] = [:]
        for f in l.features {
            let p = f.properties
            guard let g = f.geometry, g.coordinates.count >= 2, let v = p.value.flatMap(Double.init), let t = iso.date(from: p.time),
                  Date().timeIntervalSince(t) < Sensor.stale else { continue }
            let at = CLLocationCoordinate2D(latitude: g.coordinates[1], longitude: g.coordinates[0])
            guard Geo.distance(c, at) <= km * 1000 else { continue }
            var e = by[p.monitoring_location_id] ?? (at, nil, nil)
            if p.parameter_code == "00065" { e.stage = (v, t) } else { e.flow = (v, t) }
            by[p.monitoring_location_id] = e
        }
        guard !by.isEmpty else { return [] }
        // Names and site types: stream sites only (wells and canals report the same codes).
        let ids = by.keys.sorted().prefix(80).joined(separator: ",")
        var names: [String: String] = [:]
        if let u = URL(string: "\(base)/monitoring-locations/items?f=json&id=\(ids)&properties=monitoring_location_name,site_type_code&skipGeometry=true&limit=100"),
           let s: Sites = try? await Net.json(u, accept: "application/geo+json") {
            for f in s.features where ["ST", "ST-TS", "ST-CA", "ES", "LK"].contains(f.properties.site_type_code ?? "ST") {
                names[f.id] = pretty(f.properties.monitoring_location_name ?? f.id)
            }
        }
        return by.compactMap { id, e -> Sensor? in
            guard let name = names[id] else { return nil }
            var r: [Sensor.Reading] = []
            if let s = e.stage { r.append(.init(label: "Gage height", value: String(format: "%.2f ft", s.0), time: s.1)) }
            if let f = e.flow { r.append(.init(label: "Flow", value: f.0 >= 100 ? String(format: "%.0f cfs", f.0) : String(format: "%.1f cfs", f.0), time: f.1)) }
            let site = id.replacingOccurrences(of: "USGS-", with: "")
            return Sensor(id: id, network: .usgs, name: name, coordinate: e.at, readings: r,
                          page: URL(string: "https://waterdata.usgs.gov/monitoring-location/USGS-\(site)/"),
                          note: "Gage height is the water on this site's own scale, not the river's depth. USGS doesn't set flood stages; NOAA does that only at its forecast points.")
        }
    }

    /// "SACRAMENTO R A FREEPORT CA" -> "Sacramento River at Freeport".
    static func pretty(_ s: String) -> String {
        let words: [String: String] = ["R": "River", "C": "Creek", "CR": "Creek", "CK": "Creek", "A": "at", "AT": "at", "NR": "near", "BL": "below",
                                       "AB": "above", "NF": "North Fork", "SF": "South Fork", "MF": "Middle Fork", "SL": "Slough", "BYP": "Bypass",
                                       "L": "Lake", "RES": "Reservoir", "TRIB": "Tributary", "CYN": "Canyon", "FT": "Fort", "ST": "St", "MT": "Mount"]
        var parts = s.split(separator: " ").map(String.init)
        if let last = parts.last, last.count == 2, last == last.uppercased(), parts.count > 2 { parts.removeLast() }
        return parts.enumerated().map { i, w in
            let key = w.uppercased().trimmingCharacters(in: .punctuationCharacters)
            if let x = words[key] { return i == 0 ? x.prefix(1).uppercased() + x.dropFirst() : x }
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

// MARK: California DWR CDEC

/// CDEC: river stage, flow, and reservoir storage and releases. CDEC has no search by location,
/// so the station list comes from the manifest; the readings are live.
enum CDEC {
    private struct Row: Decodable { let stationId: String; let SENSOR_NUM: Int; let date: String; let value: Double?; let units: String? }
    private static let pacific: DateFormatter = {
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.dateFormat = "yyyy-M-d H:mm"
        d.timeZone = TimeZone(secondsFromGMT: -8 * 3600)   // CDEC reports Pacific Standard Time all year
        return d
    }()

    static func near(_ c: CLLocationCoordinate2D, km: Double, stations: [SensorFeeds.Station]) async -> [Sensor] {
        func d(_ s: SensorFeeds.Station) -> Double { Geo.distance(c, .init(latitude: s.lat, longitude: s.lon)) }
        let near = stations.filter { d($0) <= km * 1000 }.sorted { d($0) < d($1) }.prefix(40)
        guard !near.isEmpty else { return [] }
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = TimeZone(secondsFromGMT: -8 * 3600)
        let start = day.string(from: Date().addingTimeInterval(-2 * 86400)), end = day.string(from: Date().addingTimeInterval(86400))
        let ids = near.map(\.id).joined(separator: ",")
        guard let u = URL(string: "https://cdec.water.ca.gov/dynamicapp/req/JSONDataServlet?Stations=\(ids)&SensorNums=1,6,15,20,23&dur_code=H&Start=\(start)&End=\(end)"),
              let rows: [Row] = try? await Net.json(u) else { return [] }
        var latest: [String: [Int: (Double, Date)]] = [:]
        for r in rows {
            guard let v = r.value, v > -9000, let t = pacific.date(from: r.date) else { continue }
            if let have = latest[r.stationId]?[r.SENSOR_NUM], have.1 >= t { continue }
            latest[r.stationId, default: [:]][r.SENSOR_NUM] = (v, t)
        }
        let labels: [(Int, String, (Double) -> String)] = [
            (1, "River stage", { String(format: "%.2f ft", $0) }),
            (6, "Reservoir level", { String(format: "%.1f ft", $0) }),
            (20, "Flow", { String(format: "%.0f cfs", $0) }),
            (15, "Storage", { String(format: "%.0f acre-ft", $0) }),
            (23, "Release", { String(format: "%.0f cfs", $0) }),
        ]
        return near.compactMap { s -> Sensor? in
            guard let got = latest[s.id] else { return nil }
            let r = labels.compactMap { n, label, f in got[n].map { Sensor.Reading(label: label, value: f($0.0), time: $0.1) } }
            guard !r.isEmpty else { return nil }
            let reservoir = got[15] != nil || s.kind == "reservoir"
            return Sensor(id: "cdec-\(s.id)", network: .cdec, name: USGSWater.pretty(s.name), coordinate: .init(latitude: s.lat, longitude: s.lon),
                          readings: r, page: URL(string: "https://cdec.water.ca.gov/dynamicapp/QueryF?s=\(s.id)"),
                          note: reservoir ? "Releases from upstream dams set much of the river's level downstream. Storage is how much water the reservoir holds now."
                                          : "Stage is the water on this station's own scale, not the river's depth.")
        }
    }
}

/// Street-level flood sensors run by cities and counties.
enum StreetSensors {
    static func near(_ c: CLLocationCoordinate2D, km: Double, feeds: SensorFeeds?) async -> [Sensor] {
        feeds?.floodnet == true ? await floodNet(c, metres: min(km * 1000, 8_000)) : []
    }

    /// FloodNet NYC through NYC Open Data: each sensor and the floods it has recorded. FloodNet's
    /// live depth feed isn't licensed for reuse, so this is history, updated every two weeks.
    private struct FNSensor: Decodable { let sensor_id: String; let sensor_name: String?; let latitude: String?; let longitude: String?; let tidally_influenced: String?; let date_installed: String? }
    private struct FNHist: Decodable { let sensor_id: String; let n: String?; let deepest: String?; let last: String? }

    static func floodNet(_ c: CLLocationCoordinate2D, metres: Double) async -> [Sensor] {
        func url(_ id: String, _ q: [String: String]) -> URL? {
            var u = URLComponents(string: "https://data.cityofnewyork.us/resource/\(id).json")!
            u.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
            return u.url
        }
        guard let su = url("kb2e-tjy3", ["$where": String(format: "within_circle(location, %.6f, %.6f, %.0f)", c.latitude, c.longitude, metres), "$limit": "200"]),
              let sensors: [FNSensor] = try? await Net.json(su), !sensors.isEmpty else { return [] }
        let ids = sensors.map { "'\($0.sensor_id.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        var hist: [String: FNHist] = [:]
        if let hu = url("aq7i-eu5q", ["$select": "sensor_id,count(*) as n,max(max_depth_inches) as deepest,max(flood_start_time) as last",
                                      "$where": "sensor_id in(\(ids))", "$group": "sensor_id"]),
           let h: [FNHist] = try? await Net.json(hu) {
            for x in h { hist[x.sensor_id] = x }
        }
        let socrata = DateFormatter(); socrata.locale = Locale(identifier: "en_US_POSIX"); socrata.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        socrata.timeZone = TimeZone(identifier: "America/New_York")
        let day = DateFormatter(); day.dateStyle = .medium
        return sensors.compactMap { s -> Sensor? in
            guard let lat = s.latitude.flatMap(Double.init), let lon = s.longitude.flatMap(Double.init) else { return nil }
            let h = hist[s.sensor_id]
            let n = h?.n.flatMap(Int.init) ?? 0
            var r: [Sensor.Reading] = [.init(label: "Floods recorded", value: n == 0 ? "None" : "\(n)", time: nil)]
            if let d = h?.deepest.flatMap(Double.init), n > 0 { r.append(.init(label: "Deepest", value: String(format: "%.1f in", d), time: nil)) }
            if let t = h?.last.flatMap(socrata.date), n > 0 { r.append(.init(label: "Most recent", value: day.string(from: t), time: nil)) }
            if let t = s.date_installed.flatMap(socrata.date) { r.append(.init(label: "Installed", value: day.string(from: t), time: nil)) }
            var x = Sensor(id: "fn-\(s.sensor_id)", network: .floodnet, name: s.sensor_name ?? "FloodNet sensor", coordinate: .init(latitude: lat, longitude: lon),
                           readings: r, page: URL(string: "https://www.floodnet.nyc/"))
            x.street = true
            x.severity = n > 0 ? 1 : 0
            x.note = "Floods this sensor recorded on the street since it went in, from NYC Open Data (updated every two weeks). FloodNet's live readings aren't licensed for reuse, so the app shows history, not today's water."
                + (s.tidally_influenced == "Yes" ? " This street floods with the tide." : "")
            return x
        }
    }
}
