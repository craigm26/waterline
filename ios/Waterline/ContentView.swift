import SwiftUI

/// Marker mode: tap a seawall mark whose elevation you know, and the water plane is drawn at
/// (scenario level - mark elevation) above it. Absolute anchoring (plan/ar-anchoring.md) comes later.
struct ContentView: View {
    @State private var forecast: Forecast?
    @State private var loadError = false
    @State private var scenario: Scenario = Scenario.christmasEve(anomalyFt: Self.fallbackAnomaly, anomalyIsLive: false)[0]
    @State private var markerFt: Double = Scenario.plazaFt
    @State private var hasMarker = false
    @State private var showHelp = false
    @State private var showAbout = false
    @AppStorage("seenHelp") private var seenHelp = false

    /// October 2026 mean anomaly at 9414290, used only until the live fetch returns.
    static let fallbackAnomaly = 0.98

    private var scenarios: [Scenario] {
        (forecast.map(Scenario.live) ?? [])
            + Scenario.christmasEve(anomalyFt: forecast?.anomalyFt ?? Self.fallbackAnomaly, anomalyIsLive: forecast != nil)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            WaterARView(waterAboveMarkerM: (scenario.levelFtMLLW - markerFt) * 0.3048, hasMarker: $hasMarker)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel("How to use")
                    Button { showAbout = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("About and sources")
                }
                .font(.title2).padding(10)
                .background(.ultraThinMaterial, in: Capsule()).padding(.horizontal)
                Spacer()
            }
            panel
        }
        .task { await load() }
        .sheet(isPresented: $showHelp) { HelpView() }
        .sheet(isPresented: $showAbout) { AboutView(forecast: forecast) }
        .onAppear { if !seenHelp { showHelp = true; seenHelp = true } }
    }

    private var panel: some View {
        VStack(spacing: 8) {
            if scenario.isStressTest {
                Text("STRESS TEST · NOT A FORECAST").font(.caption.bold()).padding(6)
                    .background(.red.opacity(0.85), in: Capsule()).foregroundStyle(.white)
            }
            Text(hasMarker ? String(format: "%.2f ft MLLW · %+.2f ft vs the mark", scenario.levelFtMLLW, scenario.levelFtMLLW - markerFt)
                           : "Tap the mark on the seawall")
                .font(.headline.monospacedDigit())
            Text(scenario.detail + " · " + Scenario.thresholdNote(scenario.levelFtMLLW))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Picker("Scenario", selection: $scenario) {
                ForEach(scenarios) { s in
                    Text(s.label + (s.provenance == .assumed ? " ▨" : s.provenance == .derived ? " ○" : "")).tag(s)
                }
            }
            .pickerStyle(.menu)
            HStack {
                Text("Mark elevation (ft MLLW)")
                TextField("ft", value: $markerFt, format: .number.precision(.fractionLength(2)))
                    .keyboardType(.decimalPad).frame(width: 80).textFieldStyle(.roundedBorder)
            }
            .font(.footnote)
            Text(status).font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    private var status: String {
        if let f = forecast { return "NOAA live, \(Forecast.shortLabel(f.fetched)). ○ derived · ▨ assumed. Screening view, not an official alert." }
        return loadError ? "NOAA unreachable: using stored values. ○ derived · ▨ assumed." : "Loading NOAA forecast…"
    }

    private func load() async {
        do {
            let f = try await Forecast.load()
            let keep = scenario.id
            forecast = f
            scenario = scenarios.first { $0.id == keep } ?? scenarios[0]
        } catch {
            loadError = true
        }
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("How to use it") {
                    Label("Stand at the Ferry Building seawall and point the camera at a mark whose height you know.", systemImage: "1.circle")
                    Label("Enter that mark's height in ft above MLLW. The default is the plaza in front of the Ferry Building, 10.16 ft from USGS lidar.", systemImage: "2.circle")
                    Label("Tap the mark. A water plane appears at the chosen level, relative to the mark.", systemImage: "3.circle")
                    Label("Pick a scenario: the next high tide, the Christmas Eve king tide, or what stacks on top of it.", systemImage: "4.circle")
                }
                Section("Read it right") {
                    Text("Solid scenarios are NOAA predictions. ○ adds the gauge's current anomaly, assuming it holds. ▨ is an assumed storm or stress test, not a forecast.")
                    Text("The plane is only as accurate as the mark's height. On iPhones with LiDAR, people and bollards hide the water behind them.")
                    Text("This is a screening view, not an official alert. Follow AlertSF and the National Weather Service.")
                }
            }
            .navigationTitle("Waterline")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct AboutView: View {
    let forecast: Forecast?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Right now") {
                    if let f = forecast {
                        LabeledContent("Gauge anomaly, 30 days", value: String(format: "%+.2f ft", f.anomalyFt))
                        if let n = f.highs.first { LabeledContent("Next high tide", value: String(format: "%.2f ft · %@", n.ft, n.label)) }
                    } else {
                        Text("NOAA forecast not loaded.")
                    }
                }
                Section("Thresholds at 9414290, ft MLLW") {
                    ForEach(Scenario.thresholds, id: \.0) { t in LabeledContent(t.0, value: String(format: "%.2f", t.1)) }
                    LabeledContent("Ferry Building plaza (lidar)", value: String(format: "%.2f", Scenario.plazaFt))
                }
                Section("Sources") {
                    Link("NOAA CO-OPS station 9414290", destination: URL(string: "https://tidesandcurrents.noaa.gov/stationhome.html?id=9414290")!)
                    Link("City-manager view and method", destination: URL(string: "https://craigmerry.com/waterline/")!)
                    Link("Code and data", destination: URL(string: "https://github.com/craigm26/waterline")!)
                }
                Section {
                    Text("Built with Claude Code by Craig Merry. No data leaves your phone; the app only reads NOAA.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
