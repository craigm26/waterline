#if os(visionOS)
import SwiftUI
import RealityKit

/// Vision Pro: the scenario's water at full size in your own room. In a mixed immersive space
/// the origin sits on the floor under you, so the water stands at its computed depth above your
/// real floor, with the staff gauge and a 5 ft 9 in person beside you for scale.
struct RoomFlood: View {
    static let spaceID = "flood-room"
    @EnvironmentObject var model: AppModel
    /// RealityKit entities live in a reference holder, so updating them isn't a SwiftUI state change.
    final class Parts { var water: ModelEntity?; var label: ModelEntity?; var ruler: Entity?; var material = WaterLook.material(); var clock: Float = 0; var sub: EventSubscription? }
    @State private var parts = Parts()

    var body: some View {
        RealityView { content in
            let parts = self.parts
            let w = ModelEntity(mesh: .generatePlane(width: 24, depth: 24), materials: [parts.material])
            w.position = .zero
            w.isEnabled = false
            content.add(w)
            parts.water = w
            let p = WaterLook.person(); p.position = SIMD3<Float>(1.4, 0, -2.6)
            content.add(p)
            parts.sub = content.subscribe(to: SceneEvents.Update.self) { e in
                parts.clock += Float(e.deltaTime)
                parts.material.textureCoordinateTransform.offset = SIMD2<Float>(parts.clock * 0.018, parts.clock * 0.011)
                parts.water?.model?.materials = [parts.material]
            }
        } update: { content in
            let d = Float((model.roomDepthFt ?? 0) / Geo.ftPerM)
            let parts = self.parts
            guard let w = parts.water else { return }
            let feet = max(3, Int((Double(d) * Geo.ftPerM).rounded(.up)) + 1)
            if parts.ruler?.name != "ruler-\(feet)" {
                parts.ruler?.removeFromParent()
                let r = WaterLook.ruler(feet: feet); r.name = "ruler-\(feet)"; r.position = SIMD3<Float>(0.9, 0, -2.2)
                content.add(r); parts.ruler = r
            }
            parts.label?.removeFromParent()
            if d > 0.005 {
                if !w.isEnabled { w.position = .zero; w.isEnabled = true }
                w.move(to: Transform(translation: SIMD3<Float>(0, d, 0)), relativeTo: nil, duration: model.roomPlaying ? 0.35 : 2.5, timingFunction: .easeInOut)
                let l = ModelEntity(mesh: .generateText(String(format: "%.1f ft", Double(d) * Geo.ftPerM), extrusionDepth: 0.004, font: .boldSystemFont(ofSize: 0.09)),
                                    materials: [UnlitMaterial(color: .white)])
                l.position = SIMD3<Float>(0.58, d + 0.03, -2.2)
                content.add(l); parts.label = l
            } else {
                w.isEnabled = false
            }
        }
    }
}

/// The window beside the room: pick a scenario, play its hours or layers, and open the room.
struct RoomTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var closeSpace
    @State private var open = false
    @State private var step = 0
    @State private var playing = false
    @State private var tick = 0

    private var report: SpotReport? { model.report }
    private var scenario: WaterScenario? { report?.scenarios.first { $0.id == model.arScenarioID } }
    private var steps: Int { scenario.map { !$0.stages.isEmpty ? $0.stages.count : $0.timeline?.points.count ?? 1 } ?? 1 }

    private var depth: Double? {
        guard let s = scenario else { return nil }
        if !s.stages.isEmpty { return s.stages[min(step, s.stages.count - 1)].depthFt }
        if let t = s.timeline, t.points.indices.contains(step) { let ft = t.points[step].ft; return ft >= 0.05 ? ft : nil }
        return s.depthFt
    }
    private var stepLabel: String? {
        guard let s = scenario else { return nil }
        if !s.stages.isEmpty { return s.stages[min(step, s.stages.count - 1)].label }
        if let t = s.timeline, t.points.indices.contains(step) { return t.when(t.points[step]) }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let r = report, !r.scenarios.isEmpty {
                    Section {
                        Picker("Scenario", selection: Binding(get: { model.arScenarioID ?? "" }, set: { model.arScenarioID = $0; step = start; playing = false })) {
                            ForEach(r.scenarios) { s in Text("\(s.label) \(s.provenance.mark)").tag(s.id) }
                        }
                        if let s = scenario {
                            if s.isStressTest { Text("STRESS TEST · NOT A FORECAST").font(.caption.bold()).foregroundStyle(.red) }
                            Text(s.detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Text(depth.map { String(format: "%.1f ft deep where you'd stand", $0) } ?? "Dry where you'd stand").font(.title2.bold())
                        if steps > 1 {
                            HStack {
                                Button { playing.toggle(); model.roomPlaying = playing && scenario?.stages.isEmpty != false } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                                Slider(value: Binding(get: { Double(step) }, set: { step = Int($0.rounded()); playing = false; model.roomPlaying = false }), in: 0...Double(steps - 1), step: 1)
                            }
                            if let l = stepLabel { Text(l).font(.callout.monospacedDigit()) }
                        }
                    }
                    Section {
                        Toggle("Show the water in your room", isOn: $open)
                        Text("The water rises from your real floor to the depth this spot would see, beside a ruler in feet and a 5 ft 9 in person. Waterline's estimate for \(r.placeLabel ?? "this spot"), not a forecast of your room.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Reading the ground here…")
                }
            }
            .navigationTitle("In your room")
        }
        .onChange(of: open) { _, on in
            Task {
                if on { _ = await openSpace(id: RoomFlood.spaceID) } else { await closeSpace() }
            }
        }
        .onChange(of: depth) { _, d in model.roomDepthFt = d }
        .onAppear { step = start; model.roomDepthFt = depth }
        .onReceive(Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()) { _ in
            guard playing else { return }
            tick += 1
            // Layers rise slowly, one every 3 seconds; hours step quickly.
            if scenario?.stages.isEmpty == false, tick % 5 != 0 { return }
            let jump = max(1, steps / 120)
            if step + jump < steps { step += jump } else { step = steps - 1; playing = false; model.roomPlaying = false }
        }
    }

    private var start: Int {
        guard let t = scenario?.timeline, t.whatIf == nil else { return 0 }
        return t.points.lastIndex { $0.date <= Date() } ?? 0
    }
}
#endif
