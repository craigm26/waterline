import SwiftUI
import RealityKit
import ARKit

/// RealityKit view with LiDAR occlusion. A tap raycasts to the seawall mark and places a
/// translucent water plane `waterAboveMarkerM` metres above it (negative = below the mark).
struct WaterARView: UIViewRepresentable {
    var waterAboveMarkerM: Double
    @Binding var hasMarker: Bool

    func makeCoordinator() -> Coordinator { Coordinator(hasMarker: $hasMarker) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            view.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        view.session.run(config)
        context.coordinator.view = view
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.setWaterOffset(Float(waterAboveMarkerM))
    }

    final class Coordinator: NSObject {
        weak var view: ARView?
        private var anchor: AnchorEntity?
        private let water: ModelEntity
        private var offset: Float = 0
        private var hasMarker: Binding<Bool>

        init(hasMarker: Binding<Bool>) {
            self.hasMarker = hasMarker
            var material = UnlitMaterial(color: UIColor(red: 0.12, green: 0.55, blue: 0.95, alpha: 1))
            material.blending = .transparent(opacity: 0.45)
            water = ModelEntity(mesh: .generatePlane(width: 60, depth: 60), materials: [material])
            super.init()
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let point = g.location(in: view)
            guard let hit = view.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first else { return }
            anchor?.removeFromParent()
            let t = hit.worldTransform.columns.3
            // keep the plane level: anchor at the mark's position with no rotation
            let a = AnchorEntity(world: SIMD3<Float>(t.x, t.y, t.z))
            a.addChild(water)
            view.scene.addAnchor(a)
            anchor = a
            setWaterOffset(offset)
            hasMarker.wrappedValue = true
        }

        func setWaterOffset(_ metres: Float) {
            offset = metres
            water.position = SIMD3<Float>(0, metres, 0)
        }
    }
}
