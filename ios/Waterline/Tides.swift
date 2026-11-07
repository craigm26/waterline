import Foundation
import CoreLocation

/// The nearest NOAA CO-OPS water-level station to a spot, and what it says about the coming weeks:
/// predicted highs, the 30-day anomaly (observed minus predicted), datums and flood thresholds.
/// Works on any US coast. All levels are ft MLLW at that station.
struct TideOutlook {
    struct High: Hashable { let time: Date; let ft: Double }
    struct Threshold: Hashable { let name: String; let ft: Double }

    let stationID: String
    let stationName: String
    let stationKm: Double
    let stationCoordinate: CLLocationCoordinate2D
    let highs: [High]              // next 30 days
    let anomalyFt: Double?         // nil when the station has no recent observations
    let thresholds: [Threshold]    // NOAA flood levels that exist at this station, ascending
    /// ft MLLW = ft NAVD88 + this. nil when the station has no NAVD88 tie.
    let navd88ToMLLW: Double?

    var nextHigh: High? { highs.first }
    var highest: High? { highs.max { $0.ft < $1.ft } }

    /// Which NOAA threshold a level reaches, in words.
    func band(_ ft: Double) -> String? {
        thresholds.last { ft >= $0.ft }.map { "\($0.name) flood level" }
    }

    static let stationURL = URL(string: "https://tidesandcurrents.noaa.gov/stationhome.html?id=")!

    // MARK: loading

    private struct StationList: Decodable {
        struct S: Decodable { let id: String; let name: String; let lat: Double; let lng: Double; let tidal: Bool? }
        let stations: [S]
    }
    private struct Datums: Decodable { struct D: Decodable { let name: String; let value: Double? }; let datums: [D]? }
    private struct Floods: Decodable { let nos_minor: Double?; let nos_moderate: Double?; let nos_major: Double?; let nws_minor: Double? }
    private struct Row: Decodable { let t: String; let v: String; let type: String? }
    private struct Page: Decodable { let predictions: [Row]?; let data: [Row]? }

    static let mdapi = "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi"

    /// Nearest tidal station within `maxKm`, trying the next one if a station has no predictions.
    static func load(near c: CLLocationCoordinate2D, maxKm: Double = 60) async throws -> TideOutlook? {
        let list: StationList = try await Net.cachedJSON(URL(string: "\(mdapi)/stations.json?type=waterlevels")!,
                                                         cacheName: "coops-stations.json", maxAge: 7 * 86400)
        let near = list.stations.filter { $0.tidal ?? true }
            .map { ($0, Geo.distance(c, .init(latitude: $0.lat, longitude: $0.lng)) / 1000) }
            .filter { $0.1 <= maxKm }.sorted { $0.1 < $1.1 }
        for (s, km) in near.prefix(3) {
            if let o = try? await outlook(s.id, s.name, km, .init(latitude: s.lat, longitude: s.lng)) { return o }
        }
        return nil
    }

    private static func outlook(_ id: String, _ name: String, _ km: Double, _ at: CLLocationCoordinate2D) async throws -> TideOutlook {
        let now = Date()
        async let hilo = rows(id, "predictions", now, now.addingTimeInterval(30 * 86400), "&interval=hilo")
        async let obs = try? rows(id, "water_level", now.addingTimeInterval(-30 * 86400), now, "")
        async let pred = try? rows(id, "predictions", now.addingTimeInterval(-30 * 86400), now, "&interval=6")
        async let dat = try? (Net.json(URL(string: "\(mdapi)/stations/\(id)/datums.json?units=english")!) as Datums)
        async let fl = try? (Net.json(URL(string: "\(mdapi)/stations/\(id)/floodlevels.json")!) as Floods)

        let highs = try await hilo.filter { $0.type == "H" || $0.type == "HH" }.compactMap { r -> High? in
            guard let ft = Double(r.v), let t = parse(r.t), t > now else { return nil }
            return High(time: t, ft: ft)
        }
        guard !highs.isEmpty else { throw URLError(.cannotParseResponse) }

        var anomaly: Double?
        if let o = await obs, let p = await pred {
            let predicted = Dictionary(p.compactMap { r in Double(r.v).map { (r.t, $0) } }, uniquingKeysWith: { a, _ in a })
            let res = o.compactMap { r -> Double? in
                guard let v = Double(r.v), let q = predicted[r.t] else { return nil }
                return v - q
            }
            if res.count > 500 { anomaly = res.reduce(0, +) / Double(res.count) }
        }

        let d = Dictionary((await dat)?.datums?.compactMap { x in x.value.map { (x.name, $0) } } ?? [], uniquingKeysWith: { a, _ in a })
        let mllw = d["MLLW"]
        var thresholds: [Threshold] = []
        if let f = await fl, let mllw {
            let pairs: [(String, Double?)] = [("NWS minor", f.nws_minor), ("NOS minor", f.nos_minor),
                                              ("NOS moderate", f.nos_moderate), ("NOS major", f.nos_major)]
            thresholds = pairs.compactMap { n, v in v.map { Threshold(name: n, ft: $0 - mllw) } }.sorted { $0.ft < $1.ft }
        }
        let tie: Double? = (d["NAVD88"] != nil && mllw != nil) ? d["NAVD88"]! - mllw! : nil
        return TideOutlook(stationID: id, stationName: name, stationKm: km, stationCoordinate: at, highs: highs, anomalyFt: anomaly,
                           thresholds: thresholds, navd88ToMLLW: tie)
    }

    // MARK: CO-OPS plumbing (local standard/daylight time, ft MLLW)

    private static let local = TimeZone.current
    private static func formatter(_ f: String) -> DateFormatter {
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.timeZone = TimeZone(identifier: "UTC"); d.dateFormat = f; return d
    }
    private static let coopsTime = formatter("yyyy-MM-dd HH:mm")
    private static let query = formatter("yyyyMMdd HH:mm")
    static func parse(_ s: String) -> Date? { coopsTime.date(from: s) }

    private static func rows(_ id: String, _ product: String, _ from: Date, _ to: Date, _ extra: String) async throws -> [Row] {
        var c = URLComponents(string: "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter")!
        c.percentEncodedQuery = [
            "station=\(id)", "product=\(product)", "datum=MLLW", "units=english", "time_zone=gmt",
            "format=json", "application=waterline-ios",
            "begin_date=\(query.string(from: from).replacingOccurrences(of: " ", with: "%20"))",
            "end_date=\(query.string(from: to).replacingOccurrences(of: " ", with: "%20"))",
        ].joined(separator: "&") + extra
        let page: Page = try await Net.json(c.url!)
        return (product == "water_level" ? page.data : page.predictions) ?? []
    }
}

/// Small JSON-over-HTTPS helper with a polite User-Agent (NWS requires one) and a disk cache.
enum Net {
    static let userAgent = "Waterline iOS (https://github.com/craigm26/waterline)"

    static func json<T: Decodable>(_ url: URL, accept: String = "application/json") async throws -> T {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The network's copy, falling back to the last one saved when offline. For a file that
    /// changes shape between builds: a stale copy can hide new data entirely.
    static func freshJSON<T: Decodable>(_ url: URL, cacheName: String) async throws -> T {
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(cacheName)
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let v = try JSONDecoder().decode(T.self, from: data)
            try? data.write(to: file)
            return v
        } catch {
            guard let d = try? Data(contentsOf: file), let v = try? JSONDecoder().decode(T.self, from: d) else { throw error }
            return v
        }
    }

    static func cachedJSON<T: Decodable>(_ url: URL, cacheName: String, maxAge: TimeInterval) async throws -> T {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let file = dir.appendingPathComponent(cacheName)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < maxAge,
           let data = try? Data(contentsOf: file), let v = try? JSONDecoder().decode(T.self, from: data) {
            return v
        }
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let v = try JSONDecoder().decode(T.self, from: data)
        try? data.write(to: file)
        return v
    }
}
