#if os(iOS)
import SwiftUI
import CoreLocation
import Charts
import ARKit

/// The camera view: the water line at your feet for each scenario, plus three sensor tools that
/// turn "the street floods" into "does it reach my door": LiDAR step measure, barometer floor
/// height, and compass arrows to higher ground and the nearest drain.
struct ARTab: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var compass = Compass()
    @StateObject private var floor = FloorMeter()
    @State private var mode: WaterARView.Mode = .water
    @State private var groundFound = false
    @State private var showFloor = false
    @AppStorage("arRange") private var rangeT = ARRange.defaultT     // slider position, 0...1
    @AppStorage(Layer.storageKey) private var hiddenRaw = Layer.defaultOff         // layers turned off, shared with the Map and 3D views
    @State private var screen: [String: CGPoint] = [:]
    /// The hour shown, for a scenario that plays out over time; playing steps it forward.
    @State private var hour: Int?
    @State private var playing = false
    /// The layer shown, for a scenario built up in layers.
    @State private var stage = 0
    /// "On the street": the water spread over the ground around this spot, pinned by geo tracking.
    @State private var street = false
    @State private var streetOK: Bool?
    @State private var streetStatus = ""
    @State private var patch: TerrainPatch?
    @State private var field: GeoWaterField?
    @State private var stacking = false
    @State private var picked: POI?
    @State private var showList = false
    @State private var topEdge: CGFloat = 200
    @State private var panelEdge: CGFloat = 500
    @AppStorage("stepFt") private var stepFt: Double = 0     // doorstep / curb above the street
    @AppStorage("floorFt") private var floorFt: Double = 0   // floor above the street (barometer)

    private var report: SpotReport? { model.usingPin ? nil : model.report }
    private var scenario: WaterScenario? { report?.scenarios.first { $0.id == model.arScenarioID } }

    private var rangeM: Double { ARRange.metres(rangeT) }
    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

    /// Everything inside the distance filter, before the type filter.
    private var inRange: [(POI, Double)] {
        guard let r = report else { return [] }
        return r.pois.map { ($0, Geo.distance(r.coordinate, $0.coordinate)) }.filter { $0.1 <= rangeM && $0.1 > 3 }
    }
    /// Tags that pass both filters, most important first (flooding gauges, then near things).
    private var visiblePOIs: [(POI, Double)] {
        let off = hidden
        return inRange.filter { !off.contains($0.0.group.rawValue) }
            .sorted { ($0.0.severity, -$0.1) > ($1.0.severity, -$1.1) }
    }
    private var placements: [WaterARView.Placement] {
        guard let r = report else { return [] }
        return visiblePOIs.map { .init(id: $0.0.id, bearing: Geo.bearing(from: r.coordinate, to: $0.0.coordinate), metres: $0.1) }
    }

    var body: some View {
        ZStack {
            WaterARView(mode: mode, depthFt: shownDepthFt, playing: playing, street: street, geo: field, onGeoStatus: { streetStatus = $0 }, placements: placements,
                        onGround: { found in groundFound = found },
                        onMeasure: { ft in stepFt = max(0, ft); mode = .water },
                        onProject: { screen = $0 })
                .ignoresSafeArea()
            tags.ignoresSafeArea()
            VStack {
                VStack(spacing: 6) {
                    filters
                    pointers
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topEdge = $0 }
                Spacer()
                panel.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { panelEdge = $0 }
            }
        }
        .onAppear { compass.start(); resetHour() }
        .task(id: "\(street)-\(String(format: "%.2f", shownDepthFt ?? 0))") { await spreadOnStreet() }
        .onChange(of: model.arScenarioID) { _, _ in playing = false; stacking = false; stage = 0; resetHour() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            guard stacking, let s = scenario else { return }
            if stage + 1 < s.stages.count { stage += 1 } else { stacking = false }
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            guard playing, let t = scenario?.timeline, let h = hour else { return }
            let jump = max(1, t.points.count / 120)        // a month-long storm plays in about 50 s
            if h + jump < t.points.count { hour = h + jump } else { hour = t.points.count - 1; playing = false }
        }
        .onDisappear { compass.stop(); floor.stop() }
        .sheet(isPresented: $showFloor) { floorSheet.presentationDetents([.medium]) }
        .sheet(item: $picked) { p in POIDetail(poi: p, report: report).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showList) {
            POIList(items: visiblePOIs, report: report, rangeLabel: "Within \(Geo.walk(rangeM))").presentationDetents([.medium, .large])
        }
    }

    /// Distance and type, like the filters in a flight tracker: what's left is what gets tagged.
    private var filters: some View {
        let near = inRange, off = hidden
        let shown = near.filter { !off.contains($0.0.group.rawValue) }.count
        return VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("Within \(Geo.walk(rangeM))").font(.caption.bold().monospacedDigit()).frame(width: 92, alignment: .leading)
                Slider(value: $rangeT, in: 0...1).accessibilityLabel("Distance")
                Button { showList = true } label: { Label("\(shown)", systemImage: "list.bullet").font(.caption.bold().monospacedDigit()) }
                    .buttonStyle(.bordered).accessibilityLabel("List \(shown) places")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Layer.allCases) { g in
                        let n = near.filter { $0.0.group == g }.count
                        if n > 0 { chip(g, count: n, on: !off.contains(g.rawValue)) }
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10).padding(.top, 4)
    }

    private func chip(_ g: Layer, count: Int, on: Bool) -> some View {
        Button {
            var h = Layer.off(hiddenRaw)
            if on { h.insert(g) } else { h.remove(g) }
            hiddenRaw = Layer.raw(h)
        } label: {
            Text("\(g.rawValue) \(count)").font(.caption2.bold()).padding(.horizontal, 9).padding(.vertical, 5)
                .foregroundStyle(on ? Color.black : Color.primary)
                .background(on ? Color.white.opacity(0.9) : Color.black.opacity(0.25), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Tags at their projected screen points, kept between the filters and the panel. Moved tags
    /// keep a thin line to their true bearing.
    private var tags: some View {
        GeometryReader { geo in
            let lookup = Dictionary(visiblePOIs.map { ($0.0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let band = CGRect(x: 6, y: topEdge + 4, width: geo.size.width - 12, height: max(0, panelEdge - topEdge - 8))
            let items = visiblePOIs.compactMap { p in screen[p.0.id].map { (id: p.0.id, at: $0) } }
            let spots = TagLayout.place(items, in: band).spots
            ZStack {
                Path { path in
                    for s in spots where hypot(s.point.x - s.anchor.x, s.point.y - s.anchor.y) > 14 {
                        path.move(to: s.point); path.addLine(to: s.anchor)
                    }
                }
                .stroke(.white.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
                ForEach(spots, id: \.id) { s in
                    if let (poi, m) = lookup[s.id] {
                        Group {
                            if s.compact { POIDot(poi: poi) } else { POITag(poi: poi, metres: m) }
                        }
                        .position(s.point)
                        .onTapGesture { picked = poi }
                    }
                }
            }
        }
    }

    @ViewBuilder private var pointers: some View {
        if let r = report {
            VStack(spacing: 6) {
                if let hg = r.higherGround {
                    PointerChip(label: "Higher ground", from: r.coordinate, to: hg.coordinate, heading: compass.heading)
                }
                if let d = r.drains.first(where: { !$0.0.deep_pit }) {
                    PointerChip(label: "Drain #\(d.0.rank)", from: r.coordinate, to: d.0.coordinate, heading: compass.heading)
                }
            }
            .padding(.top, 8)
        }
    }

    private var panel: some View {
        VStack(spacing: 8) {
            if model.usingPin {
                Text("The camera view works where you're standing. Tap \"Use my location\" on the Here tab.").font(.subheadline)
            } else if let r = report, !r.scenarios.isEmpty {
                if let s = scenario, s.isStressTest {
                    Text("STRESS TEST · NOT A FORECAST").font(.caption.bold()).padding(6)
                        .background(.red.opacity(0.85), in: Capsule()).foregroundStyle(.white)
                }
                Text(headline).font(.headline.monospacedDigit()).multilineTextAlignment(.center)
                if let t = scenario?.timeline { player(t) }
                if let s = scenario, !s.stages.isEmpty { stacker(s) }
                if let s = scenario { Text(s.detail).font(.caption).foregroundStyle(.secondary) }
                Picker("Scenario", selection: Binding(get: { model.arScenarioID ?? "" }, set: { model.arScenarioID = $0 })) {
                    ForEach(r.scenarios) { s in Text("\(s.label) \(s.provenance.mark)").tag(s.id) }
                }
                .pickerStyle(.menu)
                if WaterARView.Coordinator.geoSupported { streetToggle }
                if stepFt > 0 || floorFt > 0 { thresholds }
                HStack {
                    Button(mode == .measure ? "Tap the street, then the step" : "Measure a step") { mode = mode == .measure ? .water : .measure }
                    if FloorMeter.available { Button("Floor height") { showFloor = true } }
                }
                .buttonStyle(.bordered).font(.footnote)
                Text(WaterARView.hasLiDAR ? "LiDAR on: water hides behind people and objects." : "No LiDAR on this iPhone: the water draws over everything.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if report == nil {
                ProgressView("Reading the ground here…")
            } else {
                Text("No water scenarios here: no tide gauge nearby and no bowl at this spot.").font(.subheadline)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    private var streetToggle: some View {
        VStack(spacing: 2) {
            Picker("Where", selection: $street) {
                Text("At my feet").tag(false)
                Text("On the street").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(streetOK == false)
            if street, !streetStatus.isEmpty { Text(streetStatus).font(.caption2).foregroundStyle(.secondary) }
            if streetOK == false { Text("Apple's street tracking doesn't cover this spot yet.").font(.caption2).foregroundStyle(.secondary) }
        }
        .task {
            guard streetOK == nil, let c = report?.coordinate else { return }
            streetOK = await withCheckedContinuation { k in
                ARGeoTrackingConfiguration.checkAvailability(at: c) { ok, _ in k.resume(returning: ok) }
            }
        }
    }

    /// Spread the shown depth over the USGS ground around this spot.
    private func spreadOnStreet() async {
        guard street, let r = report else { field = nil; return }
        if patch == nil { patch = try? await TerrainPatch.load(r.coordinate) }
        guard let p = patch else { field = nil; return }
        let d = shownDepthFt ?? 0, c = r.coordinate
        field = await Task.detached(priority: .userInitiated) { GeoWaterField.build(p, center: c, depthFt: d) }.value
    }

    /// The depth drawn: the hour on the timeline, or the scenario's own depth.
    private var shownDepthFt: Double? {
        guard let s = scenario else { return nil }
        if !s.stages.isEmpty { return s.stages[min(stage, s.stages.count - 1)].depthFt }
        if let t = s.timeline, let h = hour, t.points.indices.contains(h) {
            let ft = t.points[h].ft
            return ft >= 0.05 ? ft : nil
        }
        return s.depthFt
    }

    /// Start a timeline at the present hour.
    private func resetHour() {
        guard let t = scenario?.timeline else { hour = nil; return }
        hour = t.whatIf != nil ? 0 : t.points.lastIndex { $0.date <= Date() } ?? 0
    }

    /// Add the layers one at a time: each press, or play, raises the water by the next one.
    private func stacker(_ s: WaterScenario) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Button {
                    if stacking { stacking = false } else { if stage + 1 >= s.stages.count { stage = 0 }; stacking = true }
                } label: { Image(systemName: stacking ? "pause.circle.fill" : "play.circle.fill").font(.title) }
                .accessibilityLabel(stacking ? "Pause" : "Add the layers one at a time")
                Text("Add the layers one at a time").font(.caption)
                Spacer()
            }
            ForEach(Array(s.stages.enumerated()), id: \.offset) { i, st in
                Button { stacking = false; stage = i } label: {
                    HStack {
                        Image(systemName: i <= stage ? "drop.fill" : "drop").foregroundStyle(i <= stage ? Color.orange : .secondary)
                        Text("\(st.label) \(st.prov.mark)").font(.caption).bold(i == stage)
                        Spacer()
                        Text(st.depthFt.map { String(format: "%.1f ft", $0) } ?? "below").font(.caption.monospacedDigit())
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Play, pause and scrub through the hours: measured rain first, then the forecast.
    private func player(_ t: WaterTimeline) -> some View {
        let i = min(hour ?? 0, t.points.count - 1)
        let p = t.points[i]
        let top = max(0.5, (t.points.map(\.ft).max() ?? 0) * 1.2)
        return VStack(spacing: 4) {
            Chart {
                ForEach(t.points) { q in
                    AreaMark(x: .value("Hour", q.date), y: .value("Water", q.ft))
                        .foregroundStyle(Color(red: 0.55, green: 0.48, blue: 0.34).opacity(0.7)).interpolationMethod(.monotone)
                }
                RuleMark(x: .value("Shown", p.date)).foregroundStyle(.white).lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Shown", p.date), y: .value("Water", p.ft)).foregroundStyle(.white)
            }
            .chartYScale(domain: 0...top)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading, values: [0, top / 1.2]) { v in
                AxisValueLabel { Text(String(format: "%.1f ft", v.as(Double.self) ?? 0)).font(.system(size: 9)) }
            } }
            .frame(height: 52)
            .accessibilityHidden(true)
            HStack(spacing: 10) {
                Button {
                    if !playing, i + 1 >= t.points.count { hour = 0 }
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.title)
                }
                .accessibilityLabel(playing ? "Pause" : "Play the next 3 days")
                Slider(value: Binding(get: { Double(i) }, set: { hour = Int($0.rounded()); playing = false }),
                       in: 0...Double(max(1, t.points.count - 1)), step: 1)
            }
            HStack {
                Text(t.when(p)).bold()
                Spacer()
                Text(String(format: "%.2f in rain that hour · %@", p.rainIn, t.whatIf != nil ? "NOAA Atlas 14" : p.measured ? "measured" : "forecast"))
            }
            .font(.caption.monospacedDigit())
        }
    }

    private var headline: String {
        guard groundFound else { return "Point at the ground a few steps ahead" }
        guard let s = scenario else { return "" }
        if !s.stages.isEmpty {
            let st = s.stages[min(stage, s.stages.count - 1)]
            guard let d = st.depthFt else { return "\(st.label): stays below where you stand" }
            return String(format: "%@: %.1f ft deep where you stand", st.label, d)
        }
        if s.timeline != nil {
            guard let d = shownDepthFt else { return "Dry where you stand" }
            return String(format: "%.1f ft deep where you stand", d)
        }
        guard let d = s.depthFt else { return "\(s.label): the water doesn't reach this spot" }
        return String(format: "%@: %.1f ft deep where you stand", s.label, d)
    }

    /// What the selected scenario means for the step and floor you measured.
    private var thresholds: some View {
        let d = scenario?.depthFt ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            if stepFt > 0 {
                Text(String(format: "Your step is %.1f ft above the street: %@", stepFt,
                            d >= stepFt ? String(format: "water goes %.1f ft over it", d - stepFt) : String(format: "water stays %.1f ft below it", stepFt - d)))
            }
            if floorFt > 0 {
                Text(String(format: "Your floor is %.0f ft up: %@", floorFt,
                            d >= floorFt ? "water reaches it" : String(format: "%.0f ft of margin", floorFt - d)))
            }
        }
        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var floorSheet: some View {
        VStack(spacing: 14) {
            Text("How high is your floor?").font(.headline)
            Text("Stand on the street outside and press Start. Walk up to your floor, porch or garage, then press Save. The barometer measures the climb.")
                .font(.subheadline).multilineTextAlignment(.center)
            Text(String(format: "%.1f ft", floor.deltaFt ?? 0)).font(.system(size: 44, weight: .bold).monospacedDigit())
            HStack {
                Button(floor.running ? "Restart" : "Start") { floor.start() }.buttonStyle(.bordered)
                Button("Save") { floorFt = max(0, floor.deltaFt ?? 0); floor.stop(); showFloor = false }
                    .buttonStyle(.borderedProminent).disabled(!floor.running)
            }
            Text("Good to about a foot. Weather changes the pressure too, so take under five minutes.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
    }
}
#endif
