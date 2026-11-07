import SwiftUI
import CoreLocation

/// The sheet behind a Map marker or AR tag: what it is, why it's there, its numbers with their
/// provenance, and what you can do with it.
struct POIDetail: View {
    let poi: POI
    let report: SpotReport?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            POIDetailBody(poi: poi, report: report, close: { dismiss() })
                .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct POIDetailBody: View {
    let poi: POI
    let report: SpotReport?
    var close: () -> Void = {}
    @EnvironmentObject private var model: AppModel
    @State private var gauge: GaugeDetail?
    @State private var nldName: String?
    @State private var nld: [POI.Fact] = []
    @State private var loading = false

    private var from: CLLocationCoordinate2D? { report?.coordinate }
    /// This gauge when your risk reading uses it.
    private var usedRiver: RiverFloodLevels? { report?.river.flatMap { $0.gauge.id == poi.gauge?.id ? $0 : nil } }

    var body: some View {
        List {
            Section("What it is") {
                if let n = nldName { Text(n).font(.headline) }
                Text(poi.what)
            }
            Section("Why it's here") {
                if let f = from {
                    LabeledContent("From this spot", value: "\(Geo.walk(Geo.distance(f, poi.coordinate))) \(Geo.compass(from: f, to: poi.coordinate))")
                }
                Text(poi.why)
                if let r = usedRiver { Text("Your risk reading uses this gauge for river flooding, \(String(format: "%.0f", r.km / 1.609)) mi away.") }
            }
            numbers
            if let g = gauge, !g.impacts.isEmpty { impacts(g) }
            adopt
            hydrograph
            if let g = gauge, let u = g.photo {
                Section {
                    AsyncImage(url: u) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                    if let c = g.photoCaption { Text(c).font(.caption).foregroundStyle(.secondary) }
                }
            }
            actions
            if let s = poi.source { sourceSection(s) }
        }
        .navigationTitle(nldName ?? poi.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: poi.id) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let g = poi.gauge { gauge = await GaugeDetail.load(g.id) }
        if let r = await LiveLayers.nldRecord(poi.kind, at: poi.coordinate) { nldName = r.name; nld = r.facts }
    }

    /// The tag's own facts, then whatever the sheet read live.
    private var allFacts: [POI.Fact] {
        var out = poi.facts
        if let g = gauge {
            if let f = g.flowNow { out.append(.init(label: "Flow now", value: f, provenance: .official)) }
            if let t = g.forecastTime, poi.gauge?.forecast != nil { out.append(.init(label: "Forecast for", value: SpotReport.day.string(from: t), provenance: .official)) }
            let obs = poi.gauge?.observed
            func stage(_ name: String, _ s: Double?) {
                guard let s else { return }
                let gap = obs.map { $0 < s ? String(format: ", %.1f ft above now", s - $0) : ", reached" } ?? ""
                out.append(.init(label: name, value: String(format: "%.1f ft", s) + gap, provenance: .official))
            }
            stage("Action stage", g.action); stage("Minor flood stage", g.minor); stage("Moderate flood stage", g.moderate); stage("Major flood stage", g.major)
            if let c = g.topCrest {
                out.append(.init(label: "Highest crest listed", value: String(format: "%.1f ft, ", c.stage) + Self.date.string(from: c.time), provenance: .official))
            }
        }
        if let r = usedRiver {
            out.append(.init(label: "Major flood elevation", value: String(format: "%.1f ft NAVD88", r.majorNAVD88), provenance: .derived))
            if let g = report?.ground { out.append(.init(label: "Ground at this spot", value: String(format: "%.1f ft NAVD88", g.navd88Ft), provenance: .official)) }
        }
        return out + nld
    }
    private static let date: DateFormatter = { let d = DateFormatter(); d.dateFormat = "MMM d, yyyy"; return d }()

    @ViewBuilder private var numbers: some View {
        let facts = allFacts
        if !facts.isEmpty || loading || !poi.notes.isEmpty {
            Section {
                ForEach(facts) { f in
                    LabeledContent {
                        Text("\(f.value) \(f.provenance.mark)").multilineTextAlignment(.trailing)
                    } label: { Text(f.label) }
                }
                if loading { ProgressView() }
                ForEach(poi.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("The numbers") } footer: { if !facts.isEmpty { Text("● official   ○ computed by Waterline   ▨ assumed") } }
        }
    }

    private func impacts(_ g: GaugeDetail) -> some View {
        Section("What NOAA says happens at each level") {
            ForEach(g.impacts) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f ft", i.stage)).font(.subheadline.bold().monospacedDigit())
                    Text(i.statement).font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder private var adopt: some View {
        if poi.kind == .drain || poi.kind == .ponding, let a = PackStore.shared.adopt(at: poi.coordinate), let u = a.url {
            Section("Keep it clear") {
                Link("\(a.name ?? "Adopt a drain")\(a.operator.map { ", \($0)" } ?? "")", destination: u)
                Text(a.detail).font(.caption).foregroundStyle(.secondary)
                Text("Stay out of traffic, wear gloves, and clear only the top of the grate. Never lift a cover.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var hydrograph: some View {
        if let g = poi.gauge {
            Section("NOAA hydrograph (observed and forecast)") {
                AsyncImage(url: g.hydrograph) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                if let t = g.validTime.flatMap(ISO8601DateFormatter().date) {
                    Text("Reading time: \(SpotReport.day.string(from: t))").font(.caption2).foregroundStyle(.secondary)
                }
                if let c = gauge?.credit { Text(c).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private var actions: some View {
        Section {
            if let s = poi.scene {
                NavigationLink { LidarSceneView(scene: s) } label: { Label("Open the 3D lidar view", systemImage: "cube.transparent") }
            }
            Button {
                model.pin(poi.coordinate)
                model.tab = .here
                close()
            } label: { Label("Check flood risk at this spot", systemImage: "mappin.and.ellipse") }
            if let u = mapsLink { Link(destination: u) { Label("Open in Maps", systemImage: "map") } }
        }
    }

    private var mapsLink: URL? {
        var u = URLComponents(string: "https://maps.apple.com/")
        u?.queryItems = [.init(name: "ll", value: String(format: "%.6f,%.6f", poi.coordinate.latitude, poi.coordinate.longitude)), .init(name: "q", value: nldName ?? poi.title)]
        return u?.url
    }

    @ViewBuilder private func sourceSection(_ s: POI.Source) -> some View {
        Section("Source") {
            if let u = s.url { Link(s.name, destination: u) } else { Text(s.name).font(.subheadline) }
        }
    }
}

/// Every tag the filters let through, nearest first, so nothing depends on pointing at it.
struct POIList: View {
    let items: [(POI, Double)]
    let report: SpotReport?
    let rangeLabel: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(items.sorted { $0.1 < $1.1 }, id: \.0.id) { poi, m in
                    NavigationLink {
                        POIDetailBody(poi: poi, report: report, close: { dismiss() })
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: poi.icon).foregroundStyle(poi.severity > 0 ? poi.tint : .accentColor).frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(poi.title).font(.subheadline.bold()).lineLimit(1)
                                Text(poi.value).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(Geo.walk(m)).font(.caption.monospacedDigit())
                                if let c = report?.coordinate { Text(Geo.compass(from: c, to: poi.coordinate)).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .overlay { if items.isEmpty { ContentUnavailableView("Nothing in range", systemImage: "scope", description: Text("Widen the distance or turn on more types.")) } }
            .navigationTitle(rangeLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
