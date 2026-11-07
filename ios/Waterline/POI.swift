import SwiftUI
import CoreLocation

/// A tagged place in the AR sky view: river gauges upstream, the tide station, drains, low spots,
/// higher ground, downloaded lidar scenes. Placed by true bearing from where you stand.
struct POI: Identifiable, Hashable {
    enum Kind { case gauge, tide, drain, lowSpot, higherGround, scene, levee, floodwall, pump, ponding }
    let id: String
    let kind: Kind
    let title: String
    let value: String            // the live or computed number on the tag
    let coordinate: CLLocationCoordinate2D
    let severity: Int            // 0 ok, 1 watch, 2+ flooding; colours the tag
    let gauge: RiverGauge?

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
}

/// How far out the AR view looks, like zoom levels in a sky or flight-tracking app.
enum ARZoom: String, CaseIterable, Identifiable {
    case street = "Street", neighborhood = "Neighborhood", watershed = "Watershed"
    var id: String { rawValue }
    var maxM: Double { switch self { case .street: return 400; case .neighborhood: return 4_000; case .watershed: return 80_000 } }
}

extension SpotReport {
    /// The tags that come from a place's layers. Worked out once per report, since the AR view
    /// reads `pois` on every frame.
    static func layerPOIs(_ p: Places, at c: CLLocationCoordinate2D) -> [POI] {
        var out: [POI] = []
        for (d, _) in p.drains(near: c, within: 1_500, limit: 25) {
            out.append(POI(id: "d-\(d.id)", kind: .drain, title: d.label,
                           value: d.deep_pit ? "deep pit: report it" : d.ranked ? "\(d.flood311) past reports nearby" : "city storm drain map",
                           coordinate: d.coordinate, severity: d.ranked && d.rank <= 100 ? 1 : 0, gauge: nil))
        }
        for s in p.hotspots where Geo.distance(c, s.coordinate) < 6_000 {
            let reports = p.flood311_total > 0 ? String(format: " · %d reports", s.flood311) : ""
            out.append(POI(id: "l-\(s.rank)", kind: .lowSpot, title: "Low spot #\(s.rank): \(s.name)",
                           value: String(format: "up to %.1f ft deep", s.max_depth_m * Geo.ftPerM) + reports,
                           coordinate: s.coordinate, severity: 1, gauge: nil))
        }
        for (i, l) in p.leveesNear(c, within: 20_000, limit: 8).enumerated() {
            let wall = l.kind == "floodwall"
            out.append(POI(id: "v-\(i)", kind: wall ? .floodwall : .levee, title: wall ? "Floodwall" : "Levee",
                           value: "USACE National Levee Database", coordinate: l.at, severity: 0, gauge: nil))
        }
        for (i, u) in (p.pumps ?? []).enumerated() where Geo.distance(c, u.coordinate) < 20_000 {
            out.append(POI(id: "u-\(i)", kind: .pump, title: u.name, value: "USACE National Levee Database", coordinate: u.coordinate, severity: 0, gauge: nil))
        }
        return out
    }

    /// Everything worth tagging around this spot.
    var pois: [POI] {
        var out: [POI] = []
        for g in gauges {
            let stage = g.observed.map { String(format: "%.1f ft", $0) } ?? "no reading"
            let fc = g.forecast.map { String(format: " → %.1f", $0) } ?? ""
            out.append(POI(id: "g-\(g.id)", kind: .gauge, title: g.name, value: "\(stage)\(fc) · \(g.categoryLabel)",
                           coordinate: g.coordinate, severity: g.severity, gauge: g))
        }
        if let t = tide {
            let v = t.nextHigh.map { String(format: "next high %.1f ft", $0.ft) } ?? ""
            let a = t.anomalyFt.map { String(format: " · %+.1f ft vs prediction", $0) } ?? ""
            out.append(POI(id: "t-\(t.stationID)", kind: .tide, title: "Tide: \(t.stationName)", value: v + a,
                           coordinate: t.stationCoordinate, severity: (t.anomalyFt ?? 0) > 0.75 ? 1 : 0, gauge: nil))
        }
        out += layerPOIs
        for p in rainEstimate?.ponds ?? [] {
            out.append(POI(id: "w-\(p.id)", kind: .ponding, title: "Estimated ponding",
                           value: String(format: "Up to %.1f ft if the next 24 h of forecast rain falls and drains are blocked", p.maxFt),
                           coordinate: p.coordinate, severity: p.maxFt >= 1.5 ? 2 : 1, gauge: nil))
        }
        if let b = nearbyBowl, b.valueFt >= 1 {
            out.append(POI(id: "bowl", kind: .lowSpot, title: "Bowl", value: String(format: "%.1f ft deep", b.valueFt),
                           coordinate: b.coordinate, severity: 1, gauge: nil))
        }
        if let h = higherGround {
            out.append(POI(id: "hg", kind: .higherGround, title: "Higher ground", value: String(format: "%.0f ft NAVD88", h.valueFt),
                           coordinate: h.coordinate, severity: 0, gauge: nil))
        }
        for s in LidarScene.installed {
            if let c = s.coordinate { out.append(POI(id: "s-\(s.id)", kind: .scene, title: s.title, value: "lidar on this phone", coordinate: c, severity: 0, gauge: nil)) }
        }
        return out
    }
}

/// The floating tag drawn over the camera.
struct POITag: View {
    let poi: POI
    let metres: Double
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: poi.icon).foregroundStyle(poi.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(poi.title).font(.caption.bold()).lineLimit(1)
                Text("\(poi.value) · \(Geo.walk(metres))").font(.caption2.monospacedDigit()).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(poi.tint.opacity(0.8), lineWidth: poi.severity >= 2 ? 2 : 1))
        .foregroundStyle(.white)
        .frame(maxWidth: 230)
    }
}

/// Detail sheet for a tag. River gauges show NOAA's live hydrograph (observed + forecast).
struct POIDetail: View {
    let poi: POI
    let from: CLLocationCoordinate2D
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Distance", value: "\(Geo.walk(Geo.distance(from, poi.coordinate))) \(Geo.compass(from: from, to: poi.coordinate))")
                    Text(poi.value)
                }
                if poi.kind == .drain || poi.kind == .ponding, let a = PackStore.shared.adopt(at: poi.coordinate), let u = a.url {
                    Section("Keep it clear") {
                        Link("\(a.name ?? "Adopt a drain")\(a.operator.map { ", \($0)" } ?? "")", destination: u)
                        Text(a.detail).font(.caption).foregroundStyle(.secondary)
                        Text("Stay out of traffic, wear gloves, and clear only the top of the grate. Never lift a cover.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let g = poi.gauge {
                    Section("NOAA hydrograph (observed and forecast)") {
                        AsyncImage(url: g.hydrograph) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                        Link("Open \(g.id) on water.noaa.gov", destination: g.page)
                        if let t = g.validTime { Text("Reading time: \(t) UTC").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle(poi.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
