import SwiftUI

/// Marker mode (v0): tap a seawall mark whose elevation you know, enter that elevation,
/// and the water plane is drawn at (scenario level - marker level) above it.
/// Absolute anchoring with ARCore Geospatial replaces the manual marker later (plan/ar-anchoring.md).
struct ContentView: View {
    @State private var scenario = Scenario.ferryBuilding[0]
    @State private var markerFt: Double = 10.1          // Ferry Building plaza grade, ft MLLW (lidar)
    @State private var hasMarker = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WaterARView(waterAboveMarkerM: (scenario.levelFtMLLW - markerFt) * 0.3048, hasMarker: $hasMarker)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                if scenario.isStressTest {
                    Text("STRESS TEST · NOT A FORECAST").font(.caption.bold()).padding(6)
                        .background(.red.opacity(0.85), in: Capsule()).foregroundStyle(.white)
                }
                Text(hasMarker ? String(format: "%.2f ft MLLW · %+.1f ft vs the mark", scenario.levelFtMLLW, scenario.levelFtMLLW - markerFt)
                               : "Tap the mark on the seawall")
                    .font(.headline.monospacedDigit())
                Picker("Scenario", selection: $scenario) {
                    ForEach(Scenario.ferryBuilding) { s in
                        Text(s.label + (s.provenance == .assumed ? " ▨" : "")).tag(s)
                    }
                }
                .pickerStyle(.menu)
                HStack {
                    Text("Mark elevation (ft MLLW)")
                    TextField("ft", value: $markerFt, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad).frame(width: 80).textFieldStyle(.roundedBorder)
                }
                .font(.footnote)
                Text("Screening view, not an engineered model. ▨ = assumed value.").font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }
}
