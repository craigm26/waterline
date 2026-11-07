import Foundation
import CoreLocation

/// NWS river gauges (National Water Prediction Service) anywhere in the US: live stage, forecast,
/// and flood categories. The gauge's vertical datum turns flood stage into an elevation (NAVD88)
/// that can be compared with the ground at your spot.
struct RiverGauge: Identifiable, Hashable {
    let id: String              // NWS location id, e.g. SACC1
    let name: String
    let coordinate: CLLocationCoordinate2D
    let observed: Double?
    let observedUnit: String
    let forecast: Double?
    let category: String        // no_flooding, action, minor, moderate, major, not_defined, obs_not_current
    let validTime: String?

    static func == (a: RiverGauge, b: RiverGauge) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var categoryLabel: String {
        switch category {
        case "no_flooding": return "Below flood stage"
        case "action": return "Action stage"
        case "minor": return "Minor flooding"
        case "moderate": return "Moderate flooding"
        case "major": return "Major flooding"
        default: return "No flood stages defined"
        }
    }
    var severity: Int { ["action": 1, "minor": 2, "moderate": 3, "major": 4][category] ?? 0 }
    var page: URL { URL(string: "https://water.noaa.gov/gauges/\(id.lowercased())")! }
    var hydrograph: URL { URL(string: "https://water.noaa.gov/resources/hydrographs/\(id.lowercased())_hg.png")! }

    private struct List: Decodable {
        struct G: Decodable {
            struct Status: Decodable {
                struct V: Decodable { let primary: Double?; let primaryUnit: String?; let floodCategory: String?; let validTime: String? }
                let observed: V?; let forecast: V?
            }
            let lid: String; let name: String; let latitude: Double; let longitude: Double; let status: Status?
        }
        let gauges: [G]
    }

    /// Gauges within `km` of a spot, nearest first. Stage readings only (flow-only gauges are skipped).
    static func near(_ c: CLLocationCoordinate2D, km: Double = 60) async throws -> [RiverGauge] {
        let dLat = km / 111.0, dLon = km / (111.0 * cos(c.latitude * .pi / 180))
        let url = URL(string: String(format: "https://api.water.noaa.gov/nwps/v1/gauges?bbox.xmin=%.4f&bbox.ymin=%.4f&bbox.xmax=%.4f&bbox.ymax=%.4f&srid=EPSG_4326",
                                     c.longitude - dLon, c.latitude - dLat, c.longitude + dLon, c.latitude + dLat))!
        let l: List = try await Net.json(url)
        return l.gauges.compactMap { g -> RiverGauge? in
            let o = g.status?.observed, f = g.status?.forecast
            guard (o?.primaryUnit ?? "ft") == "ft" else { return nil }
            func v(_ x: Double?) -> Double? { x.flatMap { $0 > -900 ? $0 : nil } }
            return RiverGauge(id: g.lid, name: g.name, coordinate: .init(latitude: g.latitude, longitude: g.longitude),
                              observed: v(o?.primary), observedUnit: "ft", forecast: v(f?.primary),
                              category: o?.floodCategory ?? "not_defined", validTime: o?.validTime)
        }
        .filter { Geo.distance(c, $0.coordinate) <= km * 1000 }
        .sorted { Geo.distance(c, $0.coordinate) < Geo.distance(c, $1.coordinate) }
    }
}

/// The rest of what NOAA publishes about a gauge, read when someone opens its sheet.
struct GaugeDetail {
    struct Impact: Identifiable { let stage: Double, statement: String; var id: String { "\(stage)\(statement)" } }
    var action: Double?, minor: Double?, moderate: Double?, major: Double?
    var flowNow: String?
    var forecastTime: Date?
    /// Highest crest NOAA lists in the gauge's current datum. Older crests can be in another datum.
    var topCrest: (stage: Double, time: Date)?
    var impacts: [Impact] = []
    var photo: URL?
    var photoCaption: String?
    var credit: String?

    private struct Resp: Decodable {
        struct V: Decodable { let secondary: Double?; let secondaryUnit: String?; let validTime: String? }
        struct Status: Decodable { let observed: V?; let forecast: V? }
        struct Stage: Decodable { let stage: Double? }
        struct Cats: Decodable { let action: Stage?; let minor: Stage?; let moderate: Stage?; let major: Stage? }
        struct Crest: Decodable { let occurredTime: String?; let stage: Double?; let olddatum: Bool? }
        struct Crests: Decodable { let historic: [Crest]?; let recent: [Crest]? }
        struct Imp: Decodable { let stage: Double?; let statement: String? }
        struct Flood: Decodable { let categories: Cats?; let crests: Crests?; let impacts: [Imp]? }
        struct Photo: Decodable { struct P: Decodable { let image: URL?; let caption: String? }; let properties: P? }
        struct Images: Decodable { let photos: [Photo]? }
        struct Credit: Decodable { let title: String? }
        let status: Status?; let flood: Flood?; let images: Images?; let dataAttribution: [Credit]?
    }

    static func load(_ id: String) async -> GaugeDetail? {
        guard let r: Resp = try? await Net.json(URL(string: "https://api.water.noaa.gov/nwps/v1/gauges/\(id.lowercased())")!) else { return nil }
        func v(_ x: Double?) -> Double? { x.flatMap { $0 > -900 ? $0 : nil } }
        let iso = ISO8601DateFormatter()
        var d = GaugeDetail()
        let c = r.flood?.categories
        d.action = v(c?.action?.stage); d.minor = v(c?.minor?.stage); d.moderate = v(c?.moderate?.stage); d.major = v(c?.major?.stage)
        if let f = v(r.status?.observed?.secondary), f > 0, let u = r.status?.observed?.secondaryUnit, !u.isEmpty { d.flowNow = String(format: "%.1f %@", f, u) }
        d.forecastTime = r.status?.forecast?.validTime.flatMap(iso.date)
        let crests = (r.flood?.crests?.historic ?? []) + (r.flood?.crests?.recent ?? [])
        d.topCrest = crests.compactMap { c -> (stage: Double, time: Date)? in
            guard c.olddatum != true, let s = v(c.stage), let t = c.occurredTime.flatMap(iso.date) else { return nil }
            return (s, t)
        }.max { $0.stage < $1.stage }
        d.impacts = (r.flood?.impacts ?? []).compactMap { i in
            guard let s = v(i.stage), let t = i.statement, !t.isEmpty else { return nil }
            return Impact(stage: s, statement: t)
        }.sorted { $0.stage < $1.stage }
        if let p = r.images?.photos?.first?.properties { d.photo = p.image; d.photoCaption = p.caption }
        d.credit = r.dataAttribution?.first?.title
        return d
    }
}

/// One gauge's flood stages as elevations (ft NAVD88), when its datum checks out.
struct RiverFloodLevels {
    let gauge: RiverGauge
    let km: Double
    let minorNAVD88: Double
    let majorNAVD88: Double
    let observedNAVD88: Double?

    private struct Detail: Decodable {
        struct Flood: Decodable {
            struct Cat: Decodable { let stage: Double? }
            struct Cats: Decodable { let action: Cat?; let minor: Cat?; let moderate: Cat?; let major: Cat? }
            let categories: Cats?
            let stageUnits: String?
        }
        struct Datums: Decodable {
            struct V: Decodable { struct D: Decodable { let abbrev: String?; let value: Double? }; let value: [D]? }
            let vertical: V?
        }
        let flood: Flood?
        let datums: Datums?
    }

    /// The nearest gauge within `maxKm` whose stages convert to NAVD88 and pass a sanity check
    /// against the ground at the gauge (a missing datum can show up as 0).
    /// Only within `maxKm`: a river's surface rises upstream (the American River drops ~80 ft from Nimbus
    /// to H Street), so a gauge's stage says little about the water level a long way from it.
    static func load(_ gauges: [RiverGauge], near c: CLLocationCoordinate2D, maxKm: Double = 8) async -> RiverFloodLevels? {
        for g in gauges.prefix(4) {
            let km = Geo.distance(c, g.coordinate) / 1000
            guard km <= maxKm else { break }
            guard let d: Detail = try? await Net.json(URL(string: "https://api.water.noaa.gov/nwps/v1/gauges/\(g.id.lowercased())")!),
                  d.flood?.stageUnits ?? "ft" == "ft",
                  let minor = d.flood?.categories?.minor?.stage, minor > -900,
                  let major = d.flood?.categories?.major?.stage, major > -900,
                  let datum = d.datums?.vertical?.value?.first(where: { $0.abbrev == "NAVD88" })?.value else { continue }
            let minorElev = datum + minor
            if let groundAtGauge = await GroundElevation.load(g.coordinate)?.navd88Ft, abs(minorElev - groundAtGauge) > 40 { continue }
            return RiverFloodLevels(gauge: g, km: km, minorNAVD88: minorElev, majorNAVD88: datum + major,
                                    observedNAVD88: g.observed.map { datum + $0 })
        }
        return nil
    }
}

/// FEMA National Flood Hazard Layer at a point: the official flood zone.
struct FEMAZone {
    let zone: String
    let subtype: String?
    let inSFHA: Bool
    let bfe: Double?
    let bfeDatum: String?

    var plain: String {
        let s = (subtype ?? "").uppercased()
        switch zone {
        case "V", "VE": return "Coastal high-hazard zone (\(zone)): 1% annual chance flood with waves"
        case "A", "AE", "AH", "AO", "AR": return "1% annual chance flood zone (\(zone)), the \"100-year\" floodplain"
        case "A99": return "Zone A99: protected by a levee still being built to the 1% standard"
        case "D": return "Zone D: flood hazard not determined"
        case "X":
            if s.contains("LEVEE") { return "Zone X: reduced risk because of a levee (the risk isn't zero)" }
            if s.contains("0.2") { return "Zone X (shaded): 0.2% annual chance, the \"500-year\" floodplain" }
            return "Zone X: minimal flood hazard on FEMA's map"
        default: return "FEMA zone \(zone)"
        }
    }

    private struct Resp: Decodable {
        struct F: Decodable {
            struct A: Decodable { let FLD_ZONE: String?; let ZONE_SUBTY: String?; let SFHA_TF: String?; let STATIC_BFE: Double?; let V_DATUM: String? }
            let attributes: A
        }
        let features: [F]?
    }

    static func load(_ c: CLLocationCoordinate2D) async -> FEMAZone? {
        let q = String(format: "geometry=%.6f,%.6f&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=FLD_ZONE,ZONE_SUBTY,SFHA_TF,STATIC_BFE,V_DATUM&returnGeometry=false&f=json",
                       c.longitude, c.latitude)
        let url = URL(string: "https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer/28/query?" + q)!
        guard let r: Resp = try? await Net.json(url), let a = r.features?.first?.attributes, let z = a.FLD_ZONE else { return nil }
        return FEMAZone(zone: z, subtype: a.ZONE_SUBTY, inSFHA: a.SFHA_TF == "T",
                        bfe: a.STATIC_BFE.flatMap { $0 > -9000 ? $0 : nil }, bfeDatum: a.V_DATUM)
    }
}
