import Foundation
import CoreLocation

/// The phone-only path: the same layers a region pack holds, fetched straight from FEMA and USACE
/// for the area around you, anywhere in the US, and cached so they keep working offline. Low spots
/// come from a downloaded 10 m grid when there is one. A downloaded pack always wins over this.
enum LiveLayers {
    private static let nfhl = "https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer/28/query"
    private static let nld = "https://geospatial.sec.usace.army.mil/dls/rest/services/NLD/Public/FeatureServer"
    /// A city's own drain and service-request feeds (regions/city_sources.json, in the manifest).
    /// The phone reads these directly and keeps them on the phone: most carry no license that would
    /// let us copy them into a pack.
    struct Feed: Decodable { let type: String; let url: String; let `where`: String }
    struct Feeds: Decodable { let reports_label: String?; let drains: Feed?; let reports: Feed? }
    private struct CityCell: Codable { var drains: [Places.Drain]; var reports: [[Double]]; var label: String? }

    private static var memory: [String: Places] = [:]
    private static var cityMemory: [String: CityCell] = [:]
    private static let cityCell = 0.02  // degrees, about 2 km
    private static let lock = NSLock()
    private static let cell = 0.1      // degrees, about 11 km
    private static let maxAge: TimeInterval = 7 * 86400

    private static func key(_ c: CLLocationCoordinate2D) -> String {
        "live-layers-\(Int((c.latitude / cell).rounded(.down)))_\(Int((c.longitude / cell).rounded(.down))).json"
    }
    private static func file(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    /// Whatever is cached for this area, at any age: stale layers beat none when offline.
    static func cached(near c: CLLocationCoordinate2D) -> Places? {
        let k = key(c)
        lock.lock(); defer { lock.unlock() }
        if let m = memory[k] { return m }
        guard let d = try? Data(contentsOf: file(k)), let p = try? JSONDecoder().decode(Places.self, from: d) else { return nil }
        memory[k] = p
        return p
    }

    /// Before a report: this area's layers unless a pack or the bundle has them, then the city's feeds.
    static func prepare(near c: CLLocationCoordinate2D) async {
        if Places.inSF(c) { await load(near: c); return }
        if Places.covering(c)?.region ?? "live" == "live" { await load(near: c) }
        await loadCity(near: c)
    }

    private static func cityKey(_ c: CLLocationCoordinate2D) -> String {
        "city-\(Int((c.latitude / cityCell).rounded(.down)))_\(Int((c.longitude / cityCell).rounded(.down))).json"
    }

    /// The layers with this spot's city drains and requests added, when they've been fetched.
    static func withCity(_ p: Places, near c: CLLocationCoordinate2D) -> Places {
        let k = cityKey(c)
        lock.lock(); defer { lock.unlock() }
        var cell = cityMemory[k]
        if cell == nil, let d = try? Data(contentsOf: file(k)), let v = try? JSONDecoder().decode(CityCell.self, from: d) { cell = v; cityMemory[k] = v }
        guard let cell else { return p }
        var out = p
        out.drains = cell.drains; out.flood311 = cell.reports; out.flood311_total = cell.reports.count; out.reports_label = cell.label
        return out
    }

    static func loadCity(near c: CLLocationCoordinate2D) async {
        let k = cityKey(c), url = file(k)
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path), let d = a[.modificationDate] as? Date,
           Date().timeIntervalSince(d) < maxAge { return }
        var groups = await MainActor.run { PackStore.shared.manifest?.groups }
        if groups == nil { await PackStore.shared.load(); groups = await MainActor.run { PackStore.shared.manifest?.groups } }
        guard let feeds = groups?.first(where: { $0.contains(c) })?.live else { return }
        let lat0 = (c.latitude / cityCell).rounded(.down) * cityCell, lon0 = (c.longitude / cityCell).rounded(.down) * cityCell
        let m = 0.012   // past the cell's edge, so standing near one still sees the far side
        let box = (w: lon0 - m, s: lat0 - m, e: lon0 + cityCell + m, n: lat0 + cityCell + m)
        async let d = optionalPoints(feeds.drains, box)
        async let r = optionalPoints(feeds.reports, box)
        let dr = await d, rp = await r
        guard dr != nil || rp != nil else { return }      // try again next time; a rate limit isn't an empty city
        let drains = (dr ?? []).enumerated().map { i, p in
            Places.Drain(rank: 900_000 + i, id: "\(k)-\(i)", lon: p[0], lat: p[1], sump_m: 0, flood311: 0, hood: "", deep_pit: false)
        }
        let cell = CityCell(drains: drains, reports: rp ?? [], label: feeds.reports_label)
        if rp != nil, dr != nil, let e = try? JSONEncoder().encode(cell) { try? e.write(to: url) }
        lock.lock(); cityMemory[k] = cell; lock.unlock()
    }

    /// A city with no such feed counts as answered and empty.
    private static func optionalPoints(_ f: Feed?, _ b: (w: Double, s: Double, e: Double, n: Double)) async -> [[Double]]? {
        guard let f else { return [] }
        return await points(f, b)
    }

    /// [lon, lat] points from a feed, or nil if the service didn't answer.
    private static func points(_ f: Feed, _ b: (w: Double, s: Double, e: Double, n: Double)) async -> [[Double]]? {
        let fmt = { (v: Double) in String(format: "%.5f", v) }
        let wh = f.where.replacingOccurrences(of: "{n}", with: fmt(b.n)).replacingOccurrences(of: "{s}", with: fmt(b.s))
            .replacingOccurrences(of: "{e}", with: fmt(b.e)).replacingOccurrences(of: "{w}", with: fmt(b.w))
        guard var u = URLComponents(string: f.url) else { return nil }
        if f.type == "socrata" {
            u.queryItems = [.init(name: "$where", value: wh), .init(name: "$limit", value: "1500")]
        } else {
            u.queryItems = [.init(name: "where", value: wh), .init(name: "outFields", value: "*"), .init(name: "outSR", value: "4326"),
                            .init(name: "f", value: "geojson"), .init(name: "returnGeometry", value: "true"), .init(name: "resultRecordCount", value: "1500")]
            if f.type == "arcgis" {
                u.queryItems! += [.init(name: "geometry", value: [b.w, b.s, b.e, b.n].map(fmt).joined(separator: ",")), .init(name: "geometryType", value: "esriGeometryEnvelope"),
                                  .init(name: "inSR", value: "4326"), .init(name: "spatialRel", value: "esriSpatialRelIntersects")]
            }
        }
        // literal + in a query means a space to these services; URLComponents leaves it alone
        u.percentEncodedQuery = u.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = u.url else { return nil }
        var q = URLRequest(url: url, timeoutInterval: 40)
        q.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await URLSession.shared.data(for: q), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
        let rows: [[String: Any]]
        if let list = o as? [[String: Any]] { rows = list }
        else if let m = o as? [String: Any], m["error"] == nil, let fs = m["features"] as? [[String: Any]] { rows = fs }
        else { return nil }
        return rows.compactMap(point)
    }

    private static func point(_ row: [String: Any]) -> [Double]? {
        for key in ["geometry", "the_geom"] {
            if let g = row[key] as? [String: Any], g["type"] as? String == "Point", let c = g["coordinates"] as? [Double], c.count >= 2 { return [c[0], c[1]] }
        }
        let props = (row["properties"] as? [String: Any]) ?? row
        var lat: Double?, lon: Double?
        for (k, v) in props {
            let d = (v as? Double) ?? (v as? String).flatMap(Double.init)
            if k.lowercased() == "latitude" { lat = d }
            if k.lowercased() == "longitude" { lon = d }
        }
        guard let lat, let lon, lat != 0, lon != 0 else { return nil }
        return [lon, lat]
    }

    /// Fetch this area's layers unless a recent copy exists. Returns nil only when nothing is available.
    @discardableResult static func load(near c: CLLocationCoordinate2D) async -> Places? {
        let k = key(c), url = file(k)
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path), let d = a[.modificationDate] as? Date,
           Date().timeIntervalSince(d) < maxAge, let p = cached(near: c) { return p }
        let lat0 = (c.latitude / cell).rounded(.down) * cell, lon0 = (c.longitude / cell).rounded(.down) * cell
        let pad = 0.03
        let box = [lon0 - pad, lat0 - pad, lon0 + cell + pad, lat0 + cell + pad]
        async let fema = zone(box)
        async let walls = levees(box)
        async let stations = pumps(box)
        let rings = await fema, lines = await walls, pu = await stations
        guard rings != nil || lines != nil else { return cached(near: c) }   // both services down
        let spots = await Task.detached(priority: .utility) { () -> [Places.LowSpot] in
            guard let g = ElevationGrid.covering(c) else { return [] }
            return g.lowSpots(near: c, radiusM: 6_000, limit: 25)
        }.value
        let p = Places(drains: [], hotspots: spots, flood311: [], zone_rings: rings ?? [], flood311_total: 0,
                       region: "live", name: nil, bbox: box, zone_label: "FEMA 1% flood zone", levees: lines ?? [], pumps: pu ?? [])
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: url) }
        lock.lock(); memory[k] = p; lock.unlock()
        return p
    }

    private static func query(_ base: String, _ box: [Double], _ extra: [URLQueryItem]) async -> [[String: Any]]? {
        var u = URLComponents(string: base)!
        u.queryItems = [.init(name: "geometry", value: box.map { String(format: "%.4f", $0) }.joined(separator: ",")),
                        .init(name: "geometryType", value: "esriGeometryEnvelope"), .init(name: "inSR", value: "4326"),
                        .init(name: "outSR", value: "4326"), .init(name: "spatialRel", value: "esriSpatialRelIntersects"),
                        .init(name: "returnGeometry", value: "true"), .init(name: "f", value: "geojson")] + extra
        var r = URLRequest(url: u.url!, timeoutInterval: 45)
        r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["features"] as? [[String: Any]]
    }

    private static func zone(_ box: [Double]) async -> [[[Double]]]? {
        guard let fs = await query(nfhl, box, [.init(name: "where", value: "SFHA_TF='T'"), .init(name: "outFields", value: "FLD_ZONE"),
                                               .init(name: "maxAllowableOffset", value: "0.0001"), .init(name: "resultRecordCount", value: "800")]) else { return nil }
        var rings: [[[Double]]] = []
        for f in fs {
            guard let g = f["geometry"] as? [String: Any] else { continue }
            if g["type"] as? String == "Polygon", let c = g["coordinates"] as? [[[Double]]] { rings += c }
            if g["type"] as? String == "MultiPolygon", let c = g["coordinates"] as? [[[[Double]]]] { rings += c.flatMap { $0 } }
        }
        return rings
    }

    /// What the National Levee Database says about the levee, floodwall or pump at a point. Read
    /// when someone opens its sheet, so the packs don't have to carry it.
    static func nldRecord(_ kind: POI.Kind, at c: CLLocationCoordinate2D) async -> (name: String?, facts: [POI.Fact])? {
        let layer: Int
        switch kind { case .pump: layer = 4; case .floodwall: layer = 12; case .levee: layer = 7; default: return nil }
        let d = 0.0006      // about 60 m, for a tag that sits on the line
        var u = URLComponents(string: "\(nld)/\(layer)/query")!
        u.queryItems = [.init(name: "geometry", value: String(format: "%.5f,%.5f,%.5f,%.5f", c.longitude - d, c.latitude - d, c.longitude + d, c.latitude + d)),
                        .init(name: "geometryType", value: "esriGeometryEnvelope"), .init(name: "inSR", value: "4326"),
                        .init(name: "spatialRel", value: "esriSpatialRelIntersects"), .init(name: "where", value: "1=1"),
                        .init(name: "outFields", value: "*"), .init(name: "returnGeometry", value: "false"),
                        .init(name: "resultRecordCount", value: "1"), .init(name: "f", value: "json")]
        var r = URLRequest(url: u.url!, timeoutInterval: 20)
        r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = (o["features"] as? [[String: Any]])?.first?["attributes"] as? [String: Any] else { return nil }
        func text(_ k: String) -> String? {
            if let s = a[k] as? String { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
            if let n = a[k] as? Double, n > 0 { return n == n.rounded() ? String(Int(n)) : String(n) }
            return nil
        }
        let rows: [(String, String)]
        switch kind {
        case .pump: rows = [("Pumps", "NUMBER_PUMPS"), ("Capacity", "PUMP_CAPACITY"), ("Backup power", "BACKUP_POWER"), ("Built", "CONSTRUCTION_YEAR"),
                            ("Levee system", "SYSTEM_NAME"), ("Responsible", "RESPONSIBLE_ORGANIZATION")]
        case .floodwall: rows = [("Height", "WALL_HEIGHT_FEET"), ("Material", "PRIMARY_MATERIAL"), ("Segment", "SEGMENT_NAME"), ("Levee system", "SYSTEM_NAME"),
                                 ("Holds back", "FLOOD_SOURCES"), ("Sponsors", "SPONSORS"), ("Responsible", "RESPONSIBLE_ORGANIZATION")]
        default: rows = [("Segment", "SEGMENT_NAME"), ("Levee system", "SYSTEM_NAME"), ("Holds back", "FLOOD_SOURCES"), ("Communities", "COMMUNITY_NAMES"),
                         ("Sponsors", "SPONSORS"), ("Responsible", "RESPONSIBLE_ORGANIZATION")]
        }
        let facts = rows.compactMap { row in text(row.1).map { POI.Fact(label: row.0, value: row.0 == "Height" ? "\($0) ft" : $0, provenance: .official) } }
        return (text("PUMPSTATION_NAME"), facts)
    }

    private static func levees(_ box: [Double]) async -> [Places.Line]? {
        var out: [Places.Line]?
        for (layer, kind) in [(7, "levee"), (12, "floodwall")] {
            guard let fs = await query("\(nld)/\(layer)/query", box, [.init(name: "where", value: "1=1"), .init(name: "outFields", value: "*"),
                                                                      .init(name: "maxAllowableOffset", value: "0.0001")]) else { continue }
            for f in fs {
                guard let g = f["geometry"] as? [String: Any] else { continue }
                var paths: [[[Double]]] = []
                if g["type"] as? String == "LineString", let c = g["coordinates"] as? [[Double]] { paths = [c] }
                if g["type"] as? String == "MultiLineString", let c = g["coordinates"] as? [[[Double]]] { paths = c }
                out = (out ?? []) + paths.filter { $0.count >= 2 }.map { Places.Line(kind: kind, path: $0) }
            }
            if out == nil { out = [] }
        }
        return out
    }

    private static func pumps(_ box: [Double]) async -> [Places.Pump]? {
        guard let fs = await query("\(nld)/4/query", box, [.init(name: "where", value: "1=1"), .init(name: "outFields", value: "*")]) else { return nil }
        return fs.compactMap { f in
            guard let g = f["geometry"] as? [String: Any], let c = g["coordinates"] as? [Double], c.count >= 2 else { return nil }
            return Places.Pump(name: "Pump station", lon: c[0], lat: c[1])
        }
    }
}
