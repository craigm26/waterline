import SwiftUI
import RealityKit
import ARKit

/// RealityKit camera view with two jobs.
///
/// Water: finds the ground in front of you (a raycast against the LiDAR mesh or estimated planes),
/// treats it as the ground the lidar report describes, and floats a translucent water plane
/// `depthFt` above it, with a marker pole and label. Tap the ground to re-anchor.
///
/// Measure: tap a low point (street, gutter), then a high point (curb, doorstep). The vertical
/// difference comes back through `onMeasure`, in feet. On LiDAR iPhones this reads the mesh, so it's
/// good to about an inch at arm's length.
struct WaterARView: UIViewRepresentable {
    enum Mode { case water, measure }

    var mode: Mode
    var depthFt: Double?
    var onGround: (Bool) -> Void = { _ in }
    var onMeasure: (Double) -> Void = { _ in }

    static var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
            view.environment.sceneUnderstanding.options.insert(.occlusion)
        } else if Self.hasLiDAR {
            config.sceneReconstruction = .mesh
            view.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        view.session.run(config)
        let co = context.coordinator
        co.view = view
        view.addGestureRecognizer(UITapGestureRecognizer(target: co, action: #selector(Coordinator.tap(_:))))
        co.startAutoGround()
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let co = context.coordinator
        co.mode = mode
        co.onGround = onGround
        co.onMeasure = onMeasure
        co.setDepth(depthFt)
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        view.session.pause()
    }

    final class Coordinator: NSObject {
        weak var view: ARView?
        var mode: Mode = .water
        var onGround: (Bool) -> Void = { _ in }
        var onMeasure: (Double) -> Void = { _ in }
        var timer: Timer?

        private var groundAnchor: AnchorEntity?
        private let water: ModelEntity
        private let pole: ModelEntity
        private var label: ModelEntity?
        private var depthM: Float?
        private var measureA: SIMD3<Float>?
        private var measureAnchors: [AnchorEntity] = []

        override init() {
            var w = UnlitMaterial(color: UIColor(red: 0.12, green: 0.55, blue: 0.95, alpha: 1))
            w.blending = .transparent(opacity: 0.45)
            water = ModelEntity(mesh: .generatePlane(width: 30, depth: 30), materials: [w])
            pole = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.02, 1, 0.02)),
                               materials: [UnlitMaterial(color: .white)])
            super.init()
        }

        /// Until the ground is found, raycast a spot ahead of your feet twice a second.
        func startAutoGround() {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
                guard let self, let view = self.view else { return }
                if self.groundAnchor != nil { t.invalidate(); return }
                let p = CGPoint(x: view.bounds.midX, y: view.bounds.height * 0.75)
                if let hit = view.raycast(from: p, allowing: .estimatedPlane, alignment: .horizontal).first {
                    self.placeGround(hit.worldTransform.columns.3)
                }
            }
        }

        private func placeGround(_ t: SIMD4<Float>) {
            guard let view else { return }
            groundAnchor?.removeFromParent()
            let a = AnchorEntity(world: SIMD3<Float>(t.x, t.y, t.z))   // level: no rotation
            a.addChild(water)
            a.addChild(pole)
            view.scene.addAnchor(a)
            groundAnchor = a
            apply()
            onGround(true)
        }

        func setDepth(_ ft: Double?) {
            let m = ft.map { Float($0 / Geo.ftPerM) }
            guard m != depthM else { return }
            depthM = m
            apply()
        }

        private func apply() {
            guard let a = groundAnchor else { return }
            label?.removeFromParent(); label = nil
            guard let d = depthM, d > 0.005 else {
                water.isEnabled = false; pole.isEnabled = false
                return
            }
            water.isEnabled = true; pole.isEnabled = true
            water.position = SIMD3<Float>(0, d, 0)
            pole.scale = SIMD3<Float>(1, max(d, 0.01), 1)
            pole.position = SIMD3<Float>(0, d / 2, 0)
            let text = String(format: "%.1f ft", Double(d) * Geo.ftPerM)
            let l = ModelEntity(mesh: .generateText(text, extrusionDepth: 0.005, font: .boldSystemFont(ofSize: 0.12)),
                                materials: [UnlitMaterial(color: .white)])
            l.position = SIMD3<Float>(0.05, d + 0.08, 0)
            a.addChild(l)
            label = l
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let p = g.location(in: view)
            switch mode {
            case .water:
                if let hit = view.raycast(from: p, allowing: .estimatedPlane, alignment: .horizontal).first {
                    placeGround(hit.worldTransform.columns.3)
                }
            case .measure:
                guard let hit = view.raycast(from: p, allowing: .estimatedPlane, alignment: .any).first else { return }
                let c = hit.worldTransform.columns.3, pt = SIMD3<Float>(c.x, c.y, c.z)
                if let a = measureA {
                    dot(pt)
                    onMeasure(Double(pt.y - a.y) * Geo.ftPerM)
                    measureA = nil
                } else {
                    measureAnchors.forEach { $0.removeFromParent() }
                    measureAnchors.removeAll()
                    dot(pt)
                    measureA = pt
                }
            }
        }

        private func dot(_ p: SIMD3<Float>) {
            guard let view else { return }
            let a = AnchorEntity(world: p)
            a.addChild(ModelEntity(mesh: .generateSphere(radius: 0.015), materials: [UnlitMaterial(color: .systemYellow)]))
            view.scene.addAnchor(a)
            measureAnchors.append(a)
        }
    }
}
