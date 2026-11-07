import SwiftUI
import CoreLocation

/// A tagged place on the Map and in the AR sky view: river gauges, the tide station, drains, low
/// spots, higher ground, downloaded lidar scenes. It carries what the place is, why it's shown,
/// and its numbers with their provenance, so a tap can answer all three.
struct POI: Identifiable, Hashable {
    enum Kind { case gauge, tide, drain, lowSpot, higherGround, scene, levee, floodwall, pump, ponding }
    struct Fact: Identifiable {
        let label: String, value: String, provenance: Provenance
        var id: String { label }
    }
    struct Source { let name: String; var url: URL? = nil }

    let id: String
    let kind: Kind
    let title: String
    let value: String            // the short live or computed number on the tag
    let coordinate: CLLocationCoordinate2D
    let severity: Int            // 0 ok, 1 watch, 2+ flooding; colours the tag
    let gauge: RiverGauge?
    var what = ""
    var why = ""
    var facts: [Fact] = []
    var notes: [String] = []
    var source: Source? = nil
    var scene: LidarScene? = nil

    static func == (a: POI, b: POI) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var icon: String {
        switch kind {
        case .gauge: return "water.waves"
        case .tide: return "arrow.up.and.down.and.sparkles"
        case .drain: return "circle.grid.cross"
        case .lowSpot: return "drop.triangle.fill"
        case .higherGround: return "figure.walk.motion"
        case .scene: return "cube.transparent"
        case .levee: return "line.diagonal"
        case .floodwall: return "rectangle.split.3x1"
        case .pump: return "drop.degreesign"
        case .ponding: return "drop.fill"
        }
    }
    var tint: Color {
        switch severity {
        case 0: return kind == .higherGround ? .green : .white
        case 1: return .yellow
        case 2: return .orange
        default: return .red
        }
    }
    /// The filter chip this tag belongs to.
    var group: POIGroup {
        switch kind {
        case .gauge: return .rivers
        case .tide: return .tide
        case .drain: return .drains
        case .lowSpot: return .lowSpots
        case .higherGround: return .higherGround
        case .scene: return .lidar
        case .levee, .floodwall: return .levees
        case .pump: return .pumps
        case .ponding: return .rainWater
        }
    }
}

/// The AR view's type filter.
enum POIGroup: String, CaseIterable, Identifiable {
    case rivers = "Rivers", tide = "Tide", rainWater = "Rain water", drains = "Drains", lowSpots = "Low spots"
    case levees = "Levees", pumps = "Pumps", higherGround = "Higher ground", lidar = "Lidar"
    var id: String { rawValue }
}

/// The AR distance filter: a slider position from 0 to 1 on a log scale, 330 ft to 40 mi, so the
/// street end and the watershed end get the same room on the slider.
enum ARRange {
    static let minM = 100.0, maxM = 64_000.0
    static let defaultT = log(4_000 / minM) / log(maxM / minM)      // 2.5 mi
    static func metres(_ t: Double) -> Double { minM * pow(maxM / minM, t) }
}

// MARK: building tags, shared by the Map and AR

extension POI {
    static func drain(_ d: Places.Drain) -> POI {
        var p = POI(id: "d-\(d.id)", kind: .drain, title: d.label,
                    value: d.deep_pit ? "deep pit: report it" : d.ranked ? "\(d.flood311) past reports nearby" : "city drain map",
                    coordinate: d.coordinate, severity: d.ranked && d.rank <= 100 ? 1 : 0, gauge: nil)
        if d.ranked {
            p.what = d.deep_pit ? "A storm drain at the bottom of a deep pit, usually an underpass or stairwell." : "A storm drain inlet on San Francisco's drain map."
            p.why = "It's on the app's short list of the top 500 inlets, ranked by how deep the nearest street bowl gets and how much ground drains to this grate."
            p.facts = [.init(label: "Rank", value: "#\(d.rank) of 23,835", provenance: .derived),
                       .init(label: "Nearest bowl", value: String(format: "%.1f ft deep", d.sump_m * Geo.ftPerM), provenance: .derived),
                       .init(label: "Past 311 flooding reports", value: "\(d.flood311) within 250 ft", provenance: .official)]
            if !d.hood.isEmpty { p.facts.append(.init(label: "Neighborhood", value: d.hood, provenance: .official)) }
            p.facts.append(.init(label: "Asset ID", value: d.id, provenance: .official))
            if d.deep_pit { p.notes = ["Don't climb in. Report it to 311."] }
            p.source = .init(name: "SFPUC drain inlets, SF 311 and city lidar")
        } else {
            p.what = "A storm drain inlet from the local open data feed."
            p.why = "It's one of the closest drains to this spot. The feed gives only its location, so it has no rank or flood history."
            p.source = .init(name: "Local open data, read live and never copied")
        }
        return p
    }

    static func lowSpot(_ s: Places.LowSpot, in places: Places) -> POI {
        let reports = places.flood311_total > 0 ? String(format: " · %d reports", s.flood311) : ""
        var p = POI(id: "l-\(s.rank)", kind: .lowSpot, title: "Low spot #\(s.rank): \(s.name)",
                    value: String(format: "up to %.1f ft deep", s.max_depth_m * Geo.ftPerM) + reports,
                    coordinate: s.coordinate, severity: 1, gauge: nil)
        p.what = "A dip in the ground. Rain collects here and can't run off over the surface until it fills."
        p.why = places.isSF
            ? "It's one of San Francisco's 50 worst street low spots, ranked by how much water the bowl holds, past 311 flooding reports within 500 ft, and whether it's inside the city's 100-year flood zone."
            : "It's one of the deepest, widest dips Waterline found in the \(places.name ?? "local") elevation model. It comes from elevation, not flood records, so it shows where the ground is low, not that it has flooded."
        p.facts = [.init(label: "Rank", value: "#\(s.rank) of \(places.hotspots.count)", provenance: .derived),
                   .init(label: "Deepest point", value: String(format: "%.1f ft", s.max_depth_m * Geo.ftPerM), provenance: .derived),
                   .init(label: "Area", value: String(format: "%.1f acres", Double(s.area_m2) / 4_047), provenance: .derived),
                   .init(label: places.zoneLabel, value: s.in_zone ? "Inside" : "Outside", provenance: .official)]
        if places.isSF || s.flood311 > 0 {
            p.facts.append(.init(label: places.reportsLabel, value: "\(s.flood311) within 500 ft", provenance: .official))
        }
        p.notes = ["The depth is the shape of the ground, not a forecast. Storm drain pipes aren't modeled."]
        p.source = places.isSF ? .init(name: "San Francisco lidar, SF 311 and SFPUC")
            : .init(name: "USGS 3DEP elevation. Street names © OpenStreetMap contributors", url: URL(string: "https://www.usgs.gov/3d-elevation-program"))
        return p
    }

    static func levee(id: String, wall: Bool, at c: CLLocationCoordinate2D) -> POI {
        var p = POI(id: id, kind: wall ? .floodwall : .levee, title: wall ? "Floodwall" : "Levee",
                    value: "USACE levee database", coordinate: c, severity: 0, gauge: nil)
        p.what = wall ? "A flood wall, listed in the National Levee Database." : "A levee, listed in the National Levee Database."
        p.why = "It helps keep high water off the land behind it, which is why ground below a river's flood level can stay dry. The tag marks its closest point to this spot."
        p.notes = ["Waterline doesn't rate its condition. A levee lowers flood risk but doesn't remove it."]
        p.source = .init(name: "USACE National Levee Database", url: URL(string: "https://levees.sec.usace.army.mil/"))
        return p
    }

    static func pump(_ u: Places.Pump, index: Int) -> POI {
        var p = POI(id: "u-\(index)", kind: .pump, title: u.name, value: "USACE levee database", coordinate: u.coordinate, severity: 0, gauge: nil)
        p.what = "A pump station that moves water out of the land behind a levee."
        p.why = "When the river is high, rain behind a levee can't drain out by gravity, so it has to be pumped. It's mapped because it's part of what keeps this basin dry."
        p.notes = ["Whether it's running now isn't public, so Waterline can't show its status."]
        p.source = .init(name: "USACE National Levee Database", url: URL(string: "https://levees.sec.usace.army.mil/"))
        return p
    }

    static func gauge(_ g: RiverGauge) -> POI {
        let stage = g.observed.map { String(format: "%.1f ft", $0) } ?? "no reading"
        let fc = g.forecast.map { String(format: " → %.1f", $0) } ?? ""
        var p = POI(id: "g-\(g.id)", kind: .gauge, title: g.name, value: g.severity > 0 ? "\(stage) · \(g.categoryLabel)" : stage + fc,
                    coordinate: g.coordinate, severity: g.severity, gauge: g)
        p.what = "A river gauge that reports to the National Weather Service."
        p.why = "Waterline watches every stage gauge within 37 mi. If the nearest one is within 9 mi and reaches flood stage, your risk level goes to high."
        p.facts = [.init(label: "Stage now", value: stage, provenance: .official),
                   .init(label: "Status", value: g.categoryLabel, provenance: .official)]
        if let f = g.forecast { p.facts.append(.init(label: "Forecast", value: String(format: "%.1f ft", f), provenance: .official)) }
        p.notes = ["Stage is the height on this gauge's own scale, not the depth of the river."]
        p.source = .init(name: "NOAA National Water Prediction Service", url: g.page)
        return p
    }

    static func tide(_ t: TideOutlook) -> POI {
        let v = t.nextHigh.map { String(format: "next high %.1f ft", $0.ft) } ?? ""
        let a = t.anomalyFt.map { String(format: " · %+.1f vs forecast", $0) } ?? ""
        var p = POI(id: "t-\(t.stationID)", kind: .tide, title: "Tide: \(t.stationName)", value: v + a,
                    coordinate: t.stationCoordinate, severity: (t.anomalyFt ?? 0) > 0.75 ? 1 : 0, gauge: nil)
        p.what = "A NOAA water-level station."
        p.why = String(format: "It's the nearest tide station to this spot, %.0f mi away. Its predictions and how far the water has been running from them set the tide levels in the Water line tab.", t.stationKm / 1.609)
        if let n = t.nextHigh { p.facts.append(.init(label: "Next high tide", value: String(format: "%.1f ft, ", n.ft) + SpotReport.day.string(from: n.time), provenance: .official)) }
        if let h = t.highest { p.facts.append(.init(label: "Highest this month", value: String(format: "%.1f ft, ", h.ft) + SpotReport.day.string(from: h.time), provenance: .official)) }
        if let an = t.anomalyFt { p.facts.append(.init(label: "Observed vs prediction", value: String(format: "%+.2f ft over 30 days", an), provenance: .derived)) }
        for th in t.thresholds { p.facts.append(.init(label: "\(th.name) flood level", value: String(format: "%.1f ft", th.ft), provenance: .official)) }
        p.notes = ["Heights are ft MLLW at this station."]
        p.source = .init(name: "NOAA CO-OPS station \(t.stationID)", url: URL(string: TideOutlook.stationURL.absoluteString + t.stationID))
        return p
    }

    /// `rain` says which rain made this estimate, and whether it's a forecast or a stress test.
    static func pond(_ w: DrainageMap.Pond, rainIn: Double, rain: String, rainProvenance: Provenance, drainsWorking: Bool) -> POI {
        var p = POI(id: "w-\(w.id)", kind: .ponding, title: "Estimated ponding",
                    value: String(format: "up to %.1f ft, drains %@", w.maxFt, drainsWorking ? "working" : "blocked"),
                    coordinate: w.coordinate, severity: w.maxFt >= 1.5 ? 2 : 1, gauge: nil)
        p.what = "A place where Waterline estimates rain water would stand."
        p.why = "The estimate runs the rain over the ground, fills each dip level and spills the rest downhill. This is one of the deepest spots it found."
        p.facts = [.init(label: "Deepest water", value: String(format: "%.1f ft", w.maxFt), provenance: .derived),
                   .init(label: "Rain", value: String(format: "%.2f in, %@", rainIn, rain), provenance: rainProvenance),
                   .init(label: "Runs off the ground", value: String(format: "%.0f%%", DrainageAssumptions.runoff * 100), provenance: .assumed),
                   .init(label: "Drains", value: drainsWorking ? String(format: "Working, taking %.1f in/h", DrainageAssumptions.drainInPerHour) : "Blocked", provenance: .assumed)]
        p.notes = ["Waterline estimate, not a forecast of flooding. Pipes, backups and tides aren't modeled."]
        p.source = .init(name: "NWS rain, USGS or city ground, Waterline model")
        return p
    }

    static func bowl(_ b: ElevationGrid.GridSpot) -> POI {
        var p = POI(id: "bowl", kind: .lowSpot, title: "Bowl", value: String(format: "%.1f ft deep", b.valueFt),
                    coordinate: b.coordinate, severity: 1, gauge: nil)
        p.what = "The deepest dip in the ground near this spot."
        p.why = "Rain collects in a bowl before it can drain away, and a flood that tops the rim fills it."
        p.facts = [.init(label: "Depth to the rim", value: String(format: "%.1f ft", b.valueFt), provenance: .derived)]
        p.source = .init(name: "Ground model on this phone")
        return p
    }

    static func higherGround(_ h: ElevationGrid.GridSpot) -> POI {
        var p = POI(id: "hg", kind: .higherGround, title: "Higher ground", value: String(format: "%.0f ft NAVD88", h.valueFt),
                    coordinate: h.coordinate, severity: 0, gauge: nil)
        p.what = "The nearest ground that stays dry in the worst case Waterline checks here."
        p.why = "It clears this month's highest tide plus a 2 ft storm, and a major flood on the nearby river, whichever applies here."
        p.facts = [.init(label: "Ground height", value: String(format: "%.0f ft NAVD88", h.valueFt), provenance: .derived)]
        p.notes = ["It's measured in a straight line. Check the route before you rely on it."]
        p.source = .init(name: "Ground model on this phone")
        return p
    }

    static func scene(_ s: LidarScene, at c: CLLocationCoordinate2D) -> POI {
        var p = POI(id: "s-\(s.id)", kind: .scene, title: s.title, value: "lidar on this phone", coordinate: c, severity: 0, gauge: nil)
        p.what = "A block scanned by aerial lidar, saved on this phone as 3D points."
        p.why = "You downloaded this scene. Open it to orbit the block and raise the water."
        if let v = s.survey { p.facts.append(.init(label: "Survey", value: v, provenance: .official)) }
        if let n = s.groundNote { p.notes = [n] }
        p.scene = s
        return p
    }
}

extension SpotReport {
    /// The tags that come from a place's layers.
    static func layerPOIs(_ p: Places, at c: CLLocationCoordinate2D) -> [POI] {
        var out = p.drains(near: c, within: 1_500, limit: 25).map { POI.drain($0.0) }
        out += p.hotspots.filter { Geo.distance(c, $0.coordinate) < ARRange.maxM }.map { POI.lowSpot($0, in: p) }
        out += p.leveesNear(c, within: ARRange.maxM, limit: 30).enumerated().map { POI.levee(id: "v-\($0.offset)", wall: $0.element.kind == "floodwall", at: $0.element.at) }
        for (i, u) in (p.pumps ?? []).enumerated() where Geo.distance(c, u.coordinate) < ARRange.maxM { out.append(.pump(u, index: i)) }
        return out
    }

    /// Everything worth tagging around this spot. Built once per report: the AR view reads the
    /// list on every frame.
    func makePOIs() -> [POI] {
        var out = gauges.map(POI.gauge)
        if let t = tide { out.append(.tide(t)) }
        out += layerPOIs
        if let e = rainEstimate {
            out += e.ponds.map { POI.pond($0, rainIn: e.forecastIn, rain: "NWS forecast, next 24 h", rainProvenance: .official, drainsWorking: false) }
        }
        if let b = nearbyBowl, b.valueFt >= 1 { out.append(.bowl(b)) }
        if let h = higherGround { out.append(.higherGround(h)) }
        for s in LidarScene.installed { if let c = s.coordinate { out.append(.scene(s, at: c)) } }
        return out
    }
}

/// The floating tag drawn over the camera. The distance comes first so truncation never hides it.
struct POITag: View {
    let poi: POI
    let metres: Double
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: poi.icon).foregroundStyle(poi.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(poi.title).font(.caption.bold()).lineLimit(1)
                Text("\(Geo.walk(metres)) · \(poi.value)").font(.caption2.monospacedDigit()).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .frame(width: TagLayout.tagSize.width, height: TagLayout.tagSize.height)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(poi.tint.opacity(0.8), lineWidth: poi.severity >= 2 ? 2 : 1))
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A tag with no room for words: still tappable, still at its true bearing.
struct POIDot: View {
    let poi: POI
    var body: some View {
        Image(systemName: poi.icon).font(.caption).foregroundStyle(poi.tint)
            .frame(width: TagLayout.dotSize, height: TagLayout.dotSize)
            .background(.black.opacity(0.62), in: Circle())
            .overlay(Circle().stroke(poi.tint.opacity(0.8), lineWidth: 1))
            .contentShape(Circle())
            .accessibilityLabel(poi.title)
            .accessibilityAddTraits(.isButton)
    }
}
