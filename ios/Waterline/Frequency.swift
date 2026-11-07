import Foundation
import CoreLocation
import ImageIO
import CoreGraphics

/// NOAA Atlas 14: how much rain falls at this spot in a storm of a given return period. Official
/// numbers; what that rain does on the ground is Waterline's estimate.
struct RainFrequency {
    /// Inches, by duration ("60-min", "24-hr", ...) then by return period in years.
    let depths: [String: [Int: Double]]
    let volume: String?

    func inches(_ duration: String, years: Int) -> Double? { depths[duration]?[years] }
    var hour10: Double? { inches("60-min", years: 10) }
    var hour100: Double? { inches("60-min", years: 100) }
    var day100: Double? { inches("24-hr", years: 100) }

    static let page = URL(string: "https://hdsc.nws.noaa.gov/pfds/")!

    private static var memo: (key: String, value: RainFrequency)?

    /// About 1 km cells: Atlas 14 changes slowly across a city, so nearby spots share one request.
    static func load(_ c: CLLocationCoordinate2D) async -> RainFrequency? {
        let key = String(format: "%.2f,%.2f", c.latitude, c.longitude)
        if let m = memo, m.key == key { return m.value }
        let url = URL(string: String(format: "https://hdsc.nws.noaa.gov/cgi-bin/new/fe_text_mean.csv?lat=%.4f&lon=%.4f&data=depth&units=english&series=pds", c.latitude, c.longitude))!
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8), let f = parse(text) else { return nil }
        memo = (key, f)
        return f
    }

    /// The CSV NOAA serves: a header row of return periods, then one row per duration.
    static func parse(_ text: String) -> RainFrequency? {
        var years: [Int] = []
        var depths: [String: [Int: Double]] = [:]
        var volume: String?
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("NOAA Atlas 14") { volume = line }
            let cells = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count > 3 else { continue }
            if cells[0].hasPrefix("by duration for ARI") { years = cells.dropFirst().compactMap { Int($0) }; continue }
            guard !years.isEmpty, cells[0].hasSuffix(":") else { continue }
            if !depths.isEmpty, cells[0].hasPrefix("5-min"), depths["5-min"] != nil { break }   // the upper and lower bound tables follow
            let vals = cells.dropFirst().map { Double($0) }
            guard vals.count == years.count, vals.allSatisfy({ $0 != nil }) else { continue }
            depths[String(cells[0].dropLast())] = Dictionary(uniqueKeysWithValues: zip(years, vals.map { $0! }))
        }
        guard depths["60-min"] != nil else { return nil }
        return RainFrequency(depths: depths, volume: volume)
    }
}

/// NOAA's 2022 sea level rise scenarios at the tide station Waterline uses (CO-OPS derived product),
/// as rise from this year, so they stack on today's tide predictions.
struct SeaLevelRise {
    struct Step: Hashable { let year: Int; let ft: Double }
    let station: String
    /// Rise from now, ft, by scenario name ("Intermediate", "High", ...).
    let rise: [String: [Step]]

    func ft(_ scenario: String = "Intermediate", by year: Int) -> Double? { rise[scenario]?.first { $0.year == year }?.ft }
    static let page = URL(string: "https://coast.noaa.gov/slr/")!
    static let report = "NOAA 2022 Sea Level Rise Technical Report"

    private struct Resp: Decodable {
        struct P: Decodable { let scenario: String; let projectionYear: Int; let projectionRsl: Double?; let units: String? }
        let SlrProjections: [P]?
    }

    static func load(station id: String) async -> SeaLevelRise? {
        guard let r: Resp = try? await Net.json(URL(string: "https://api.tidesandcurrents.noaa.gov/dpapi/prod/webapi/product/slr_projections.json?station=\(id)")!),
              let rows = r.SlrProjections, !rows.isEmpty else { return nil }
        let year = Double(Calendar.current.component(.year, from: Date()))
        var out: [String: [Step]] = [:]
        for (name, list) in Dictionary(grouping: rows, by: \.scenario) {
            let pts = list.compactMap { p -> (Double, Double)? in
                guard let v = p.projectionRsl else { return nil }
                let ft = (p.units ?? "cm") == "m" ? v * 3.28084 : v / 30.48
                return (Double(p.projectionYear), ft)
            }.sorted { $0.0 < $1.0 }
            guard let now = interpolate(pts, year) else { continue }
            out[name] = [2050, 2070, 2100].compactMap { y in interpolate(pts, Double(y)).map { Step(year: y, ft: $0 - now) } }
        }
        return out.isEmpty ? nil : SeaLevelRise(station: id, rise: out)
    }

    private static func interpolate(_ pts: [(Double, Double)], _ x: Double) -> Double? {
        guard let i = pts.firstIndex(where: { $0.0 >= x }) else { return nil }
        if pts[i].0 == x || i == 0 { return pts[i].1 }
        let (x0, y0) = pts[i - 1], (x1, y1) = pts[i]
        return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    }
}

/// California DWR's Best Available Maps at a point: which 100, 200 and 500 year floodplains contain
/// it, by who mapped them, and DWR's Levee Flood Protection Zone (how deep water could get if a
/// state-federal levee failed). California only.
struct CAFloodplains {
    var in100: [String] = []
    var in200: [String] = []
    var in500: [String] = []
    var leveeZone: (depthClass: String, range: String?, sources: String?)?
    /// False when the floodplain service didn't answer: then the app says nothing about floodplains.
    var mapsAnswered = true

    var isEmpty: Bool { in100.isEmpty && in200.isEmpty && in500.isEmpty && leveeZone == nil }
    static let page = URL(string: "https://gis.bam.water.ca.gov/bam/")!

    static func covers(_ c: CLLocationCoordinate2D) -> Bool {
        (32.5...42.0).contains(c.latitude) && (-124.5...(-114.0)).contains(c.longitude)
    }

    private struct Identify: Decodable { struct R: Decodable { let layerId: Int }; let results: [R]? }
    private struct Query: Decodable {
        struct F: Decodable { struct A: Decodable { let Depth_Clas: String?; let Depth_Rang: String?; let Flood_Sour: String? }; let attributes: A }
        let features: [F]?
    }
    private static let bam = "https://utility.arcgis.com/usrsvcs/servers/69889c3b9c13475eb3fdb3c78363a369/rest/services/Boundaries/BAM/MapServer"
    private static let lfpz = "https://services.arcgis.com/BLN4oKB0N1YSgvY8/arcgis/rest/services"

    static func load(_ c: CLLocationCoordinate2D) async -> CAFloodplains? {
        guard covers(c) else { return nil }
        let pt = String(format: "%.6f,%.6f", c.longitude, c.latitude)
        let ext = String(format: "%.4f,%.4f,%.4f,%.4f", c.longitude - 0.05, c.latitude - 0.05, c.longitude + 0.05, c.latitude + 0.05)
        let idURL = URL(string: "\(bam)/identify?f=json&geometry=\(pt)&geometryType=esriGeometryPoint&sr=4326&layers=all:5,6,7,8,9,11,13,14,15,16&tolerance=0&mapExtent=\(ext)&imageDisplay=400,400,96&returnGeometry=false")!
        func zone(_ service: String, _ layer: Int) async -> Query? {
            try? await Net.json(URL(string: "\(lfpz)/\(service)/FeatureServer/\(layer)/query?f=json&geometry=\(pt)&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=Depth_Clas,Depth_Rang,Flood_Sour&returnGeometry=false")!)
        }
        async let id: Identify? = { if let a: Identify = try? await Net.json(idURL) { return a }; return try? await Net.json(idURL) }()
        async let deep = zone("Levee_Flood_Protection_Zone_Deep", 9)
        async let shallow = zone("Levee_Flood_Protection_Zone_Shallow", 10)
        let ids = await id, d = await deep, s = await shallow
        guard ids != nil || d != nil || s != nil else { return nil }
        let names: [Int: String] = [5: "FEMA effective", 6: "FEMA preliminary", 7: "regional study", 8: "DWR awareness", 9: "USACE comprehensive study",
                                    11: "USACE comprehensive study", 13: "FEMA effective", 14: "FEMA preliminary", 15: "regional study", 16: "USACE comprehensive study"]
        var out = CAFloodplains()
        out.mapsAnswered = ids?.results != nil
        for r in ids?.results ?? [] {
            guard let n = names[r.layerId] else { continue }
            switch r.layerId {
            case 5...9: if !out.in100.contains(n) { out.in100.append(n) }
            case 11: if !out.in200.contains(n) { out.in200.append(n) }
            default: if !out.in500.contains(n) { out.in500.append(n) }
            }
        }
        if let a = (d?.features?.first ?? s?.features?.first)?.attributes, let cls = a.Depth_Clas {
            out.leveeZone = (cls, a.Depth_Rang, a.Flood_Sour)
        }
        return out
    }

    /// One line for the report.
    var plain: String {
        var parts: [String] = []
        if !in100.isEmpty { parts.append("the 100-year floodplain (\(in100.joined(separator: ", ")))") }
        if !in200.isEmpty { parts.append("the 200-year floodplain (\(in200.joined(separator: ", ")))") }
        if in100.isEmpty && in200.isEmpty && !in500.isEmpty { parts.append("the 500-year floodplain (\(in500.joined(separator: ", ")))") }
        var s = !mapsAnswered ? "" : parts.isEmpty ? "California's Best Available Maps show no mapped floodplain here." : "California's Best Available Maps put this spot in " + parts.joined(separator: " and ") + "."
        if let z = leveeZone {
            s += (s.isEmpty ? "" : " ") + "If a nearby state-federal levee failed, DWR maps water here as \(z.depthClass.lowercased())" + (z.range.map { " (\($0.replacingOccurrences(of: "'", with: " ft")))" } ?? "") + (z.sources.map { ", from the \($0)" } ?? "") + "."
        }
        return s
    }
}

/// NOAA NHC's storm surge hazard maps: the worst-case surge for each hurricane category, at high tide,
/// as depth above ground. NHC publishes them only as map images, so the depth comes in bands, read
/// from the colour of the pixel at this spot.
struct SurgeHazard {
    enum Band: Int, Comparable {
        case none = 0, under3, over3, over6, over9, levee
        static func < (a: Band, b: Band) -> Bool { a.rawValue < b.rawValue }
        var words: String {
            switch self {
            case .none: return "no surge mapped"
            case .under3: return "up to 3 ft"
            case .over3: return "over 3 ft"
            case .over6: return "over 6 ft"
            case .over9: return "over 9 ft"
            case .levee: return "levee-protected area (not modeled)"
            }
        }
        /// The least depth the band promises, ft above ground.
        var atLeastFt: Double? { [.over3: 3, .over6: 6, .over9: 9][self] }
    }
    /// Index 0 is Category 1.
    let bands: [Band]
    static let page = URL(string: "https://www.nhc.noaa.gov/nationalsurge/")!

    /// Atlantic and Gulf coasts only.
    static func covers(_ c: CLLocationCoordinate2D) -> Bool { c.longitude > -98 && c.latitude < 46 }

    static func load(_ c: CLLocationCoordinate2D) async -> SurgeHazard? {
        guard covers(c) else { return nil }
        let z = 14.0, n = pow(2, z)
        let x = (c.longitude + 180) / 360 * n
        let lat = c.latitude * .pi / 180
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * n
        let tx = Int(x), ty = Int(y), px = Int((x - Double(tx)) * 256), py = Int((y - Double(ty)) * 256)
        var bands: [Band] = []
        for cat in 1...5 {
            let u = URL(string: "https://tiles.arcgis.com/tiles/C8EMgrsFcRFL6LrL/arcgis/rest/services/Storm_Surge_HazardMaps_Category\(cat)_v3/MapServer/tile/14/\(ty)/\(tx)")!
            var r = URLRequest(url: u, timeoutInterval: 20)
            r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
            // A missing tile is open water or land outside every surge zone.
            if code == 404 { bands.append(.none); continue }
            guard code == 200, let px = pixel(data, px, py) else { return nil }
            bands.append(band(px))
        }
        return SurgeHazard(bands: bands)
    }

    private static func band(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Band {
        guard p.a > 128 else { return .none }
        func near(_ r: Int, _ g: Int, _ b: Int) -> Bool { abs(p.r - r) + abs(p.g - g) + abs(p.b - b) < 60 }
        if near(0, 92, 230) { return .under3 }
        if near(255, 255, 0) { return .over3 }
        if near(255, 170, 0) { return .over6 }
        if near(255, 0, 0) { return .over9 }
        if near(255, 255, 255) { return .levee }
        return .none
    }

    private static func pixel(_ data: Data, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var buf = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: -x, y: y - img.height + 1, width: img.width, height: img.height))
        let a = Int(buf[3])
        guard a > 0 else { return (0, 0, 0, 0) }
        return (Int(buf[0]) * 255 / a, Int(buf[1]) * 255 / a, Int(buf[2]) * 255 / a, a)
    }

    var plain: String? {
        guard let first = bands.firstIndex(where: { $0 != .none && $0 != .levee }) else {
            return bands.contains(.levee) ? "NOAA's hurricane surge map marks this as a levee-protected area, where it doesn't model surge." : nil
        }
        var s = "NOAA's hurricane surge map, worst case at high tide: surge first reaches this spot in a Category \(first + 1) storm (\(bands[first].words) above ground)"
        if first < 4 { s += ", and Category 5 brings \(bands[4].words)" }
        return s + ". NHC made the map for community planning, not a single lot."
    }
}
