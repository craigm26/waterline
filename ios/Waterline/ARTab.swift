import SwiftUI
import CoreLocation

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
    @State private var zoom: ARZoom = .neighborhood
    @State private var screen: [String: CGPoint] = [:]
    @State private var picked: POI?
    @AppStorage("stepFt") private var stepFt: Double = 0     // doorstep / curb above the street
    @AppStorage("floorFt") private var floorFt: Double = 0   // floor above the street (barometer)

    private var report: SpotReport? { model.usingPin ? nil : model.report }
    private var scenario: WaterScenario? { report?.scenarios.first { $0.id == model.arScenarioID } }

    /// Tags inside the current zoom ring, most important first (flooding gauges, then near things).
    private var visiblePOIs: [(POI, Double)] {
        guard let r = report else { return [] }
        return r.pois.map { ($0, Geo.distance(r.coordinate, $0.coordinate)) }
            .filter { $0.1 <= zoom.maxM && $0.1 > 3 }
            .sorted { ($0.0.severity, -$0.1) > ($1.0.severity, -$1.1) }
            .prefix(30).map { $0 }
    }
    private var placements: [WaterARView.Placement] {
        guard let r = report else { return [] }
        return visiblePOIs.map { .init(id: $0.0.id, bearing: Geo.bearing(from: r.coordinate, to: $0.0.coordinate), metres: $0.1) }
    }

    var body: some View {
        ZStack {
            WaterARView(mode: mode, depthFt: scenario?.depthFt, placements: placements,
                        onGround: { found in groundFound = found },
                        onMeasure: { ft in stepFt = max(0, ft); mode = .water },
                        onProject: { screen = $0 })
                .ignoresSafeArea()
            tags.ignoresSafeArea()
            VStack {
                Picker("Zoom", selection: $zoom) {
                    ForEach(ARZoom.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.top, 6)
                pointers
                Spacer()
                panel
            }
        }
        .onAppear { compass.start() }
        .onDisappear { compass.stop(); floor.stop() }
        .sheet(isPresented: $showFloor) { floorSheet.presentationDetents([.medium]) }
        .sheet(item: $picked) { p in POIDetail(poi: p, from: report?.coordinate ?? p.coordinate).presentationDetents([.medium, .large]) }
    }

    /// Tags at their projected screen points. Greedy declutter: a tag that would overlap one
    /// already placed moves up a row, so the most important tag keeps its true position.
    private var tags: some View {
        var placed: [CGRect] = []
        var items: [PlacedTag] = []
        for (p, d) in visiblePOIs {
            guard var pt = screen[p.id] else { continue }
            var box = CGRect(x: pt.x - 100, y: pt.y - 18, width: 200, height: 36)
            var tries = 0
            while placed.contains(where: { $0.intersects(box) }) && tries < 6 { box.origin.y -= 40; pt.y -= 40; tries += 1 }
            placed.append(box)
            items.append(PlacedTag(poi: p, metres: d, point: pt))
        }
        return ZStack {
            ForEach(items) { item in
                POITag(poi: item.poi, metres: item.metres)
                    .position(item.point)
                    .onTapGesture { picked = item.poi }
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
                if let s = scenario { Text(s.detail).font(.caption).foregroundStyle(.secondary) }
                Picker("Scenario", selection: Binding(get: { model.arScenarioID ?? "" }, set: { model.arScenarioID = $0 })) {
                    ForEach(r.scenarios) { s in Text("\(s.label) \(s.provenance.mark)").tag(s.id) }
                }
                .pickerStyle(.menu)
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

    private var headline: String {
        guard groundFound else { return "Point at the ground a few steps ahead" }
        guard let s = scenario else { return "" }
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

private struct PlacedTag: Identifiable {
    let poi: POI
    let metres: Double
    let point: CGPoint
    var id: String { poi.id }
}
