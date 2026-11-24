import SwiftUI
import CoreLocation
import MapKit

/// The main live dashboard: quick spot switcher, at-a-glance risk/rain/tide/camera tiles,
/// live verification camera strip, and detailed provenance-marked cards (2-column on iPad).
struct HereView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var packs = PackStore.shared
    @ObservedObject private var cameraStore = CaltransCameraStore.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showInfo = false
    @State private var showSearch = false
    @State private var allFindings = false
    @State private var selectedCamera: CaltransCamera?
    #if DEBUG
    @State private var debug3D = false
    #endif

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    whereBar
                    quickPlaceStrip
                    if model.locationDenied && model.pinned == nil {
                        Card {
                            Text("Location is off").font(.headline)
                            Text("Waterline needs your location to read the ground under you. Turn it on in Settings, or tap any city above or Search address.")
                                .font(.subheadline)
                            Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                        }
                    } else if let r = model.report {
                        dashboardKPIs(r)
                        summary(r)
                        liveCameraStrip(r)
                        nextDays(r)
                        seeIt(r)
                        lidarLink(r)
                        regionOffer(r)
                        if isWide {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)], spacing: 14) {
                                coast(r).id("coast")
                                VStack(spacing: 14) {
                                    river(r).id("river")
                                    rain(r).id("rain")
                                }
                            }
                        } else {
                            coast(r).id("coast")
                            river(r).id("river")
                            rain(r).id("rain")
                        }
                        if !r.actions.isEmpty { todo(r) }
                        ForEach(r.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        footer
                    } else {
                        ProgressView("Reading the ground, tides and forecast…").frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding()
                .frame(maxWidth: isWide ? 1120 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            #if DEBUG
            // Simulator screenshots: WL_SCROLL=coast|river|rain opens the Here tab on that card.
            .onChange(of: model.report?.coast) {
                guard let to = ProcessInfo.processInfo.environment["WL_SCROLL"] else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { proxy.scrollTo(to, anchor: to == "enso" ? .center : .top) }
            }
            .navigationDestination(isPresented: $debug3D) {
                if let r = model.report {
                    TerrainSceneView(title: r.placeLabel ?? "This block", coordinate: r.coordinate, presets: terrainPresets(r), report: r)
                }
            }
            .onChange(of: model.report != nil) {
                if ProcessInfo.processInfo.environment["WL_3D"] != nil { debug3D = true }
            }
            #endif
            }
            .refreshable {
                model.refresh(force: true)
                cameraStore.bumpSnapshots()
            }
            .task { await PackStore.shared.load() }
            .task(id: model.report?.coordinate.latitude) {
                if let c = model.report?.coordinate {
                    await cameraStore.ensureLoaded(near: c)
                }
            }
            .navigationTitle("Waterline")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search address or city")
                    NavigationLink { DataPacksView() } label: { Image(systemName: "arrow.down.circle") }
                        .accessibilityLabel("Offline data")
                    Button { showInfo = true } label: { Image(systemName: "info.circle") }
                }
            }
            .sheet(isPresented: $showInfo) { InfoView() }
            .sheet(isPresented: $showSearch) { PlaceSearchSheet().environmentObject(model) }
            .sheet(item: $selectedCamera) { cam in
                CameraDetailSheet(camera: cam, origin: model.report?.coordinate ?? cam.coordinate)
                    .environmentObject(model)
            }
        }
    }

    private var quickPlaceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    showSearch = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    model.unpin()
                } label: {
                    Label("My spot", systemImage: "location.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(!model.usingPin ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                        .foregroundStyle(!model.usingPin ? .white : .primary)
                }
                .buttonStyle(.plain)

                ForEach(AppModel.quickPlaces) { place in
                    let active = model.pinned.map { Geo.distance($0, place.coordinate) < 500 } ?? false
                    Button {
                        model.pin(place.coordinate)
                    } label: {
                        Text(place.name)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(active ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                            .foregroundStyle(active ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func dashboardKPIs(_ r: SpotReport) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: isWide ? 4 : 2)
        let riskColor: Color = r.level == .high ? .red : r.level == .watch ? .orange : .green
        let riskWord = r.level == .high ? "High" : r.level == .watch ? "Watch" : "Clear"
        let rainText = r.rain.map { String(format: "%.2f in", $0.next72In) } ?? "—"
        let tideText: String = {
            if let m = r.coastalMarginFt { return String(format: "%+.1f ft", m) }
            if let g = r.gauges.first, let obs = g.observed { return String(format: "%.1f ft", obs) }
            return "—"
        }()
        let tideSub = r.coastalMarginFt != nil ? "Tide margin" : "Nearest river"
        let nearCams = CaltransDistrict.nearest(to: r.coordinate) != nil ? cameraStore.nearestCameras(to: r.coordinate, limit: 12).count : 0

        return LazyVGrid(columns: cols, spacing: 10) {
            KPITile(title: "Risk now", value: riskWord, subtitle: r.placeLabel ?? "This spot", tint: riskColor, icon: "shield.lefthalf.filled")
            KPITile(title: "Next 3 days rain", value: rainText, subtitle: r.next72.reaches ? "Water ponds here" : "NWS forecast", tint: .blue, icon: "cloud.rain.fill")
            KPITile(title: tideSub, value: tideText, subtitle: r.tide?.stationName ?? "Official gauge", tint: .teal, icon: "water.waves")
            Button {
                model.tab = .cameras
            } label: {
                KPITile(title: "Live cameras", value: nearCams > 0 ? "\(nearCams) nearby" : "Browse CA", subtitle: "Caltrans visual check", tint: .indigo, icon: "video.fill")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func liveCameraStrip(_ r: SpotReport) -> some View {
        if CaltransDistrict.nearest(to: r.coordinate) != nil {
            let cams = cameraStore.nearestCameras(to: r.coordinate, limit: isWide ? 4 : 3)
            Card {
                HStack {
                    Label("Verify on live cameras", systemImage: "video.fill")
                        .font(.headline)
                    Spacer()
                    Button("See all") { model.tab = .cameras }
                        .font(.subheadline)
                }
                if cams.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading nearest Caltrans cameras…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: isWide ? 4 : 3)
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(cams) { cam in
                            Button {
                                selectedCamera = cam
                            } label: {
                                CameraTile(camera: cam, origin: r.coordinate, refreshTick: cameraStore.refreshTick)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var whereBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.usingPin ? "mappin.circle.fill" : "location.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.report?.placeLabel ?? (model.usingPin ? "Pinned spot" : "Your location")).font(.subheadline.bold())
                Text(model.usingPin ? "Pinned on the map" : model.gpsAccuracyM.map { "GPS ±\(Int(($0 * Geo.ftPerM).rounded())) ft" } ?? "Finding you…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.loading { ProgressView() }
            if model.usingPin { Button("Use my location") { model.unpin() }.font(.caption) }
        }
    }

    private func summary(_ r: SpotReport) -> some View {
        let tint: Color = r.level == .high ? .red : r.level == .watch ? .orange : .green
        return Card(tint: tint) {
            Text(r.title).font(.title3.bold())
            let shown = allFindings ? r.findings : Array(r.findings.prefix(4))
            ForEach(shown, id: \.self) { f in
                Label { Text(f) } icon: { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(tint) }
                    .font(.subheadline)
            }
            if r.findings.count > 4 {
                Button(allFindings ? "Show fewer" : "Show \(r.findings.count - 4) more") { withAnimation { allFindings.toggle() } }
                    .font(.subheadline)
            }
        }
    }

    /// What the next three days bring to this spot: rain, the water it leaves here, the river and the tide.
    private func nextDays(_ r: SpotReport) -> some View {
        let f = r.next72
        return Card(tint: f.reaches ? .orange : .secondary) {
            Text("Next 3 days here").font(.headline)
            Text(f.headline).font(.subheadline.bold())
            if let e = r.rainEstimate, let w = e.water {
                WaterGauge(timelines: [w] + [e.waterDay100, (e.waterDay100King?.lockedHours ?? 0) > 0 ? e.waterDay100King : nil, e.waterDay1000].compactMap { $0 } + e.megastorms, station: r.rainStation,
                           onWatch: WaterlineApp.hasWaterView && !model.usingPin ? { id in model.arScenarioID = id; model.tab = .ar } : nil)
            }
            ForEach(f.rows, id: \.label) { row in
                Row(label: row.label, value: row.value, prov: row.prov, note: row.note)
            }
            Text("Forecasts from NWS and NOAA, run over the ground at this spot. A screening estimate, not an official warning.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func coast(_ r: SpotReport) -> some View {
        Card {
            Text("Ground and tide").font(.headline)
            if let g = r.groundMLLW {
                Row(label: "Ground here", value: String(format: "%.1f ft", g), prov: .derived,
                    note: r.ground?.source ?? "")
            } else if let g = r.ground {
                Row(label: "Ground here", value: String(format: "%.1f ft NAVD88", g.navd88Ft), prov: .derived, note: g.source)
            }
            if let b = r.bayReachesMLLW, r.connectivityKnown, r.bowlFt >= 0.1 {
                Row(label: "Bay reaches here at", value: String(format: "%.1f ft", b), prov: .derived,
                    note: "Lowest Bay level that gets here overland (lidar, 5 m)")
            }
            if let t = r.tide {
                if let n = t.nextHigh { Row(label: "Next high tide", value: String(format: "%.1f ft", n.ft), prov: .official, note: SpotReport.day.string(from: n.time)) }
                if let h = t.highest { Row(label: "Highest in 30 days", value: String(format: "%.1f ft", h.ft), prov: .official, note: SpotReport.day.string(from: h.time)) }
                if let a = t.anomalyFt { Row(label: "Running above prediction", value: String(format: "%+.2f ft", a), prov: .derived, note: "30-day mean, observed − predicted") }
                if let m = r.coastalMarginFt {
                    Row(label: "Margin to highest water", value: String(format: "%+.1f ft", m), prov: .derived,
                        note: r.connectivityKnown ? "Overland, from lidar" : "Assumes an open connection to the water (bathtub)")
                }
                Text("Heights in ft above MLLW at NOAA \(t.stationName) (\(Int(t.stationKm.rounded())) km away).")
                    .font(.caption2).foregroundStyle(.secondary)
                if let layers = r.coastLayers, layers.count >= 2, let reach = r.bayReachesMLLW {
                    Divider()
                    Text("What can stack on a high tide").font(.subheadline.bold())
                    CoastStackChart(stages: layers, reachFt: reach)
                    ForEach(layers, id: \.self) { l in
                        Row(label: l.label, value: l.depthFt.map { String(format: "%.1f ft deep here", $0) } ?? String(format: "%.1f ft below", reach - l.levelFt), prov: l.prov, note: l.detail)
                    }
                    if let o = r.floodDays {
                        Row(label: "High tide flood days ahead", value: o.low == o.high ? "\(o.high)" : "\(o.low) to \(o.high)", prov: .official,
                            note: "NOAA outlook, \(o.span), counting El Niño and the trend" + (o.top.map { ". Most on record: \($0.days) in \($0.year)-\(($0.year + 1) % 100)" } ?? ""))
                    }
                    if let s = r.surge?.plain {
                        Row(label: "Hurricane storm surge", value: "NHC", prov: .official, note: s + " NHC's maps already assume high tide, so they aren't stacked on it here.")
                    }
                    if let e = r.enso {
                        Row(label: "El Niño index (RONI)", value: String(format: "%+.2f", e.index), prov: .official,
                            note: "NOAA CPC, \(e.season): \(e.phase)." + (e.record.map { String(format: " Highest since 1950: %+.2f (%@).", $0.index, $0.season) } ?? "") + " On the Pacific coast El Niño lifts the sea for months.")
                            .id("enso")
                        if let o = e.ahead, let line = e.aheadLine {
                            Row(label: "El Niño ahead", value: "\(o.veryStrong >= 50 ? o.veryStrong : o.strong >= 50 ? o.strong : o.elNino)%", prov: .official,
                                note: "NOAA CPC outlook, updated monthly: \(line)." + (o.veryStrong >= 50 || o.strong < 50 ? "" : " \(o.veryStrong)% very strong.") + " Strong events raise the odds of El Niño weather; they don't guarantee it.")
                        }
                    }
                    if let c = r.coast, !c.monthTop.isEmpty {
                        Row(label: "Highest months since \(c.firstYearLabel)", value: c.monthTop.map { String(format: "%+.1f", $0.ft) }.joined(separator: ", "), prov: .derived,
                            note: c.monthTop.map(\.label).joined(separator: ", ") + ". NOAA monthly mean sea level, long-term rise and seasons taken out")
                    }
                    Text("Stacked, these are a what-if ▨: the layers rarely peak on the same day. Orange bars reach this spot.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func river(_ r: SpotReport) -> some View {
        if !r.gauges.isEmpty || r.fema != nil {
            Card {
                Text("Rivers and flood zone").font(.headline)
                if let f = r.fema {
                    Row(label: "FEMA flood zone", value: f.zone, prov: .official, note: f.plain)
                    if let b = f.bfe { Row(label: "Base flood elevation", value: String(format: "%.0f ft", b), prov: .official, note: f.bfeDatum ?? "") }
                }
                if let rv = r.river {
                    Row(label: "Major flood stage", value: String(format: "%.1f ft", rv.majorNAVD88), prov: .official,
                        note: "\(rv.gauge.name), \(String(format: "%.0f", rv.km)) km · NAVD88")
                    if let d = r.riverMajorAboveGroundFt {
                        Row(label: d > 0 ? "River above your ground" : "Your ground above it", value: String(format: "%.1f ft", abs(d)), prov: .derived,
                            note: "At major stage, if water got past the levee or bank")
                    }
                }
                ForEach(r.gauges.prefix(4)) { g in
                    Row(label: g.name, value: g.observed.map { String(format: "%.1f ft", $0) } ?? "–", prov: .official,
                        note: "\(g.categoryLabel) · \(Geo.walk(Geo.distance(r.coordinate, g.coordinate))) \(Geo.compass(from: r.coordinate, to: g.coordinate))")
                }
                Text("Live from the NWS National Water Prediction Service and FEMA's National Flood Hazard Layer. The Water line tab tags every gauge within 50 miles.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Offer the region pack when this spot is inside one that isn't downloaded.
    @ViewBuilder private func regionOffer(_ r: SpotReport) -> some View {
        if let g = packs.manifest?.groups?.first(where: { $0.contains(r.coordinate) }), !g.id.hasPrefix("san-francisco") {
            let missing = packs.packs(in: g.id).filter { packs.states[$0.id] != .installed }
            if !missing.isEmpty {
                NavigationLink { DataPacksView() } label: {
                    Label("Get \(g.name)'s data for offline use", systemImage: "arrow.down.circle").font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Water levels from this report, in ft NAVD88, for the 3D view's buttons.
    private func terrainPresets(_ r: SpotReport) -> [(String, Double)] {
        var out: [(String, Double)] = []
        if let bfe = r.fema?.bfe, bfe > -9000, (r.fema?.bfeDatum ?? "").uppercased().contains("88") { out.append((String(format: "FEMA 1%% flood %.1f", bfe), bfe)) }
        if let rv = r.river { out.append((String(format: "River major flood %.1f", rv.majorNAVD88), rv.majorNAVD88)) }
        return out
    }

    private func rain(_ r: SpotReport) -> some View {
        Card {
            Text("Rain").font(.headline)
            if let rr = r.rain {
                Row(label: "Next 24 h", value: String(format: "%.2f in", rr.next24In), prov: .official, note: "\(rr.chance24Pct)% chance · NWS")
                Row(label: "Next 3 days", value: String(format: "%.2f in", rr.next72In), prov: .official, note: "NWS gridpoint forecast")
            }
            if r.grid != nil {
                Row(label: "Bowl depth here", value: String(format: "%.1f ft", r.bowlFt), prov: .derived, note: "Ponding before it spills (lidar)")
            }
            if let l = r.layers {
                if l.flood311_total > 0 {
                    Row(label: l.reportsLabel, value: "\(r.flood311Near)", prov: .official, note: l.isSF ? "Within 500 ft, all years on DataSF" : "Within 500 ft, city open data")
                }
                if !l.zone_rings.isEmpty {
                    Row(label: l.zoneLabel, value: r.inZone ? "Inside" : "Outside", prov: .official, note: l.isSF ? "SFPUC storm flood risk map" : "FEMA National Flood Hazard Layer")
                }
                ForEach(r.drains.map { NearDrain(drain: $0.0, metres: $0.1) }) { n in
                    Row(label: n.drain.label, value: Geo.walk(n.metres) + " " + Geo.compass(from: r.coordinate, to: n.drain.coordinate),
                        prov: n.drain.ranked ? .derived : .official,
                        note: n.drain.deep_pit ? "Deep pit: report, don't clear" : n.drain.ranked ? "\(n.drain.hood) · \(n.drain.flood311) reports within 250 ft" : "City storm drain map")
                }
                if r.drains.isEmpty, l.drains.isEmpty {
                    Text("Storm drains: none found near here in this city's public data.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Local layers load when you're online.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func todo(_ r: SpotReport) -> some View {
        Card {
            Text("What you can do").font(.headline)
            ForEach(Array(r.actions.enumerated()), id: \.offset) { i, a in
                Label { Text(a).font(.subheadline) } icon: { Text("\(i + 1)").font(.caption.bold()) }
            }
            if let a = PackStore.shared.adopt(at: r.coordinate), let u = a.url, !r.drains.isEmpty {
                Link("Adopt a drain here: \(a.name ?? "city program")", destination: u).font(.subheadline.bold())
            }
        }
    }

    @ViewBuilder private func seeIt(_ r: SpotReport) -> some View {
        if WaterlineApp.hasAR { seeItButton(r) }
    }

    private func seeItButton(_ r: SpotReport) -> some View {
        Button {
            model.tab = .ar
        } label: {
            Label("See the water line here", systemImage: "camera.viewfinder").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(r.scenarios.isEmpty || model.usingPin)
    }

    /// The point cloud of this block when it's downloaded; otherwise a pointer to the packs.
    @ViewBuilder private func lidarLink(_ r: SpotReport) -> some View {
        if let scene = LidarScene.nearest(to: r.coordinate) {
            NavigationLink { LidarSceneView(scene: scene, report: r) } label: {
                Label("See the lidar of this block", systemImage: "cube.transparent").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        let ground = NavigationLink {
            TerrainSceneView(title: r.placeLabel ?? "This block", coordinate: r.coordinate, presets: terrainPresets(r), report: r)
        } label: {
            Label("See the rain on this block in 3D", systemImage: "mountain.2").frame(maxWidth: .infinity)
        }
        if WaterlineApp.hasAR { ground.buttonStyle(.bordered) } else { ground.buttonStyle(.borderedProminent) }
        if r.inSF, PackStore.installedVersion("sf-ground-1m") == nil {
            NavigationLink { DataPacksView() } label: {
                Label("Download 1 m lidar for offline use (45 MB)", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).font(.footnote)
        }
    }

    private var footer: some View {
        Text("● official  ○ derived  ▨ assumed. A screening view, not an engineered flood model or an official alert. Ground ±0.5 ft; your GPS position adds more on slopes.")
            .font(.caption2).foregroundStyle(.secondary)
    }
}

struct Card<Content: View>: View {
    var tint: Color = .secondary
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.25)))
    }
}

struct Row: View {
    let label: String
    let value: String
    let prov: Provenance
    var note: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(value + " " + prov.mark).font(.subheadline.monospacedDigit().bold())
            }
            if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

struct InfoView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("What it does") {
                    Text("Waterline reads the ground where you stand from USGS lidar, then compares it with NOAA's tide forecast and the National Weather Service rain forecast. In San Francisco it also knows the bowls rain collects in, the drains that matter, 26,458 past 311 flooding reports and SFPUC's 100-year flood zone.")
                }
                Section("How to read it") {
                    Text("● official numbers come straight from NOAA, NWS, USGS, SFPUC or 311. ○ derived numbers are computed from them. ▨ assumed numbers are scenarios, not forecasts. A stress test is labelled as one.")
                    Text("\"Bay reaches here at\" is the lowest Bay level that gets to this spot over the ground. It ignores seawalls the lidar doesn't see, and water coming up through storm drains.")
                    Text("This is screening, not an engineered flood model (HEC-RAS or similar), and not an official alert. In SF, text your ZIP code to 888-777 for AlertSF.")
                }
                Section("Sources") {
                    Link("NOAA CO-OPS tides and datums", destination: URL(string: "https://tidesandcurrents.noaa.gov/")!)
                    Link("NWS forecast (api.weather.gov)", destination: URL(string: "https://www.weather.gov/documentation/services-web-api")!)
                    Link("USGS 3DEP elevation", destination: URL(string: "https://www.usgs.gov/3d-elevation-program")!)
                    Link("SF drains, 311 and SFPUC flood map (DataSF)", destination: URL(string: "https://datasf.org/opendata/")!)
                    Link("NOAA river gauges (National Water Prediction Service)", destination: URL(string: "https://water.noaa.gov/")!)
                    Link("USGS stream gauges (Water Data)", destination: URL(string: "https://waterdata.usgs.gov/")!)
                    Link("NOAA Atlas 14 rainfall frequency", destination: RainFrequency.page)
                    Link("NOAA sea level rise scenarios (2022 report)", destination: SeaLevelRise.page)
                    Link("NOAA monthly mean sea level and trends", destination: CoastStack.monthlyPage)
                    Link("NOAA CPC El Niño index (RONI)", destination: ENSO.page)
                    Link("NOAA CPC El Niño strength outlook", destination: ENSO.outlookPage)
                    Link("NOAA high tide flooding outlook", destination: FloodDaysOutlook.page)
                    Link("NOAA NHC storm surge hazard maps", destination: SurgeHazard.page)
                    Link("FEMA National Flood Hazard Layer", destination: URL(string: "https://www.fema.gov/flood-maps/national-flood-hazard-layer")!)
                    Link("USACE National Levee Database", destination: URL(string: "https://levees.sec.usace.army.mil/")!)
                    Link("California DWR Best Available Maps and CDEC", destination: CAFloodplains.page)
                    Link("FloodNet NYC (NYC Open Data)", destination: URL(string: "https://www.floodnet.nyc/")!)
                    Link("City-manager view", destination: URL(string: "https://craigmerry.com/waterline/")!)
                    Link("Code, data and method", destination: URL(string: "https://github.com/craigm26/waterline")!)
                }
                Section {
                    Text("Built with Claude Code by Craig Merry. Your location stays on the phone; the app sends the coordinates of the spot you check only to the public data services listed above (NOAA, NWS, USGS, FEMA, USACE, California DWR and city open data) to get the numbers for that spot.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About Waterline")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

/// Compact glanceable KPI tile for the iPhone/iPad dashboard grid.
struct KPITile: View {
    let title: String
    let value: String
    let subtitle: String
    let tint: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption).foregroundStyle(tint)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.35), lineWidth: 1))
    }
}

/// Address and city search using MapKit's MKLocalSearch so users can check any
/// street or landmark in seconds.
struct PlaceSearchSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section("Quick cities") {
                        ForEach(AppModel.quickPlaces) { place in
                            Button {
                                model.pin(place.coordinate)
                                dismiss()
                            } label: {
                                Label(place.name, systemImage: "mappin.circle.fill")
                            }
                        }
                    }
                } else {
                    Section("Results") {
                        if searching {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Searching…").foregroundStyle(.secondary)
                            }
                        } else if results.isEmpty {
                            Text("No places found for \"\(query)\".").foregroundStyle(.secondary)
                        } else {
                            ForEach(results, id: \.self) { item in
                                Button {
                                    model.pin(item.placemark.coordinate)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name ?? "Place").font(.body.weight(.medium))
                                        if let title = item.placemark.title {
                                            Text(title).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Check any spot")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Address, intersection, or city")
            .onChange(of: query) { _, next in
                Task { await runSearch(next) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func runSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { results = []; return }
        searching = true
        defer { searching = false }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = trimmed
        if let center = model.target {
            req.region = MKCoordinateRegion(center: center, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        do {
            let resp = try await MKLocalSearch(request: req).start()
            results = Array(resp.mapItems.prefix(10))
        } catch {
            results = []
        }
    }
}
