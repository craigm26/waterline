#if os(iOS)
import SwiftUI
import RealityKit
import ARKit
import Combine
import Metal

/// RealityKit camera view with two jobs.
///
/// Water: finds the ground in front of you (a raycast against the LiDAR mesh or estimated planes),
/// treats it as the ground the lidar report describes, and floats a murky, slowly moving water plane
/// `depthFt` above it, beside a staff gauge marked in feet and a 5 ft 9 in person for scale.
/// The water rises into place, so the change reads as water coming up. Tap the ground to re-anchor.
///
/// Measure: tap a low point (street, gutter), then a high point (curb, doorstep). The vertical
/// difference comes back through `onMeasure`, in feet. On LiDAR iPhones this reads the mesh, so it's
/// good to about an inch at arm's length.
struct WaterARView: UIViewRepresentable {
    enum Mode { case water, measure }

    /// A tag to place by true bearing (degrees from north) and ground distance (m).
    struct Placement: Equatable { let id: String; let bearing: Double; let metres: Double }

    var mode: Mode
    var depthFt: Double?
    /// While a timeline plays, depth changes glide quickly from hour to hour; otherwise the water
    /// rises slowly into place, so the change itself reads as water coming up.
    var playing = false
    /// "On the street": water spread over the real ground, pinned to its latitude and longitude
    /// with ARKit geo tracking. nil = the level at your feet.
    var street = false
    var geo: GeoWaterField? = nil
    var onGeoStatus: (String) -> Void = { _ in }
    var placements: [Placement] = []
    var onGround: (Bool) -> Void = { _ in }
    var onMeasure: (Double) -> Void = { _ in }
    /// Screen points of the visible tags, about 15 times a second.
    var onProject: ([String: CGPoint]) -> Void = { _ in }

    static var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        // -z = true north, +x = east, so tags can sit at their real bearings
        config.worldAlignment = .gravityAndHeading
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
            view.environment.sceneUnderstanding.options.insert(.occlusion)
        } else if Self.hasLiDAR {
            config.sceneReconstruction = .mesh
            view.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        let co = context.coordinator
        view.session.delegate = co
        view.session.run(config)
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
        co.onProject = onProject
        co.placements = placements
        co.playing = playing
        co.onGeoStatus = onGeoStatus
        co.setGeo(street: street, field: geo)
        co.setDepth(depthFt)
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        coordinator.ripple?.cancel()
        view.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var view: ARView?
        var placements: [Placement] = []
        var onProject: ([String: CGPoint]) -> Void = { _ in }
        private var lastProject: TimeInterval = 0
        var mode: Mode = .water
        var onGround: (Bool) -> Void = { _ in }
        var onMeasure: (Double) -> Void = { _ in }
        var timer: Timer?
        var playing = false
        var ripple: Cancellable?
        var onGeoStatus: (String) -> Void = { _ in }
        private var geoField: GeoWaterField?
        private var streetOn = false
        private var geoAnchor: ARGeoAnchor?
        private var geoEntity: AnchorEntity?

        private var groundAnchor: AnchorEntity?
        private let water: ModelEntity
        private var ruler: Entity?
        private var label: ModelEntity?
        private let person: Entity
        private var depthM: Float?
        private var waterMaterial: PhysicallyBasedMaterial
        private var clock: Float = 0
        private var measureA: SIMD3<Float>?
        private var measureAnchors: [AnchorEntity] = []

        override init() {
            waterMaterial = WaterLook.material()
            water = ModelEntity(mesh: .generatePlane(width: 30, depth: 30), materials: [waterMaterial])
            water.isEnabled = false
            person = WaterLook.person()
            person.position = SIMD3<Float>(0.75, 0, 0)
            super.init()
        }

        // MARK: on the street

        static var geoSupported: Bool { ARGeoTrackingConfiguration.isSupported }

        /// Switch between the level at your feet and water pinned to the street.
        func setGeo(street: Bool, field f: GeoWaterField?) {
            guard let view, street != streetOn || f != geoField else { return }
            let wasGeo = streetOn
            streetOn = street
            geoField = f
            if street, !wasGeo {
                groundAnchor?.isEnabled = false
                let c = ARGeoTrackingConfiguration()
                c.planeDetection = [.horizontal]
                view.session.run(c, options: [.resetTracking, .removeExistingAnchors])
                geoAnchor = nil; geoEntity = nil
                onGeoStatus("Finding where you are: point the camera at buildings across the street")
            } else if !street, wasGeo {
                geoEntity?.removeFromParent(); geoEntity = nil; geoAnchor = nil
                let c = ARWorldTrackingConfiguration()
                c.planeDetection = [.horizontal, .vertical]
                c.worldAlignment = .gravityAndHeading
                if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { c.sceneReconstruction = .mesh }
                view.session.run(c, options: [.resetTracking, .removeExistingAnchors])
                groundAnchor = nil
                startAutoGround()
                return
            }
            guard street, let f else { geoEntity?.children.removeAll(); return }
            if let a = geoAnchor, a.coordinate.latitude == f.center.latitude, a.coordinate.longitude == f.center.longitude {
                fillGeo()
            } else {
                if let a = geoAnchor { view.session.remove(anchor: a) }
                let a = ARGeoAnchor(coordinate: f.center)   // altitude: ARKit's own ground there
                geoAnchor = a
                view.session.add(anchor: a)
            }
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            guard let view, let a = anchors.compactMap({ $0 as? ARGeoAnchor }).first(where: { $0 === geoAnchor }) else { return }
            let e = AnchorEntity(anchor: a)
            view.scene.addAnchor(e)
            geoEntity = e
            startRipple()
            fillGeo()
        }

        func session(_ session: ARSession, didChange status: ARGeoTrackingStatus) {
            let text: String
            switch status.state {
            case .localized: text = "On the street: the water sits on the ground around your spot"
            case .localizing: text = "Finding where you are: point the camera at buildings across the street"
            case .initializing: text = "Starting street tracking…"
            default: text = "Street tracking isn't available here. Use \"At my feet\"."
            }
            DispatchQueue.main.async { self.onGeoStatus(text) }
        }

        /// One flat sheet over the field's cells, with the gauge and the person at the spot.
        private func fillGeo() {
            guard let e = geoEntity, let f = geoField else { return }
            e.children.removeAll()
            var pos: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], idx: [UInt32] = []
            let h = f.cellM / 2, y = f.levelM
            for c in f.cells {
                let b = UInt32(pos.count)
                for (dx, dz) in [(-h, -h), (h, -h), (h, h), (-h, h)] as [(Float, Float)] {
                    let p = SIMD3<Float>(c.x + dx, y, c.y + dz)
                    pos.append(p); uv.append(SIMD2<Float>(p.x / 30, p.z / 30))
                }
                idx += [b, b + 2, b + 1, b, b + 3, b + 2]
            }
            var d = MeshDescriptor(name: "street-water")
            d.positions = MeshBuffers.Positions(pos)
            d.textureCoordinates = MeshBuffers.TextureCoordinates(uv)
            d.primitives = .triangles(idx)
            if !pos.isEmpty, let mesh = try? MeshResource.generate(from: [d]) {
                let sheet = ModelEntity(mesh: mesh, materials: [waterMaterial])
                sheet.name = "sheet"
                e.addChild(sheet)
            }
            let feet = max(3, Int((Double(y) * Geo.ftPerM).rounded(.up)) + 1)
            e.addChild(WaterLook.ruler(feet: feet))
            let p = WaterLook.person(); p.position = SIMD3<Float>(0.75, 0, 0); e.addChild(p)
        }

        // MARK: water look

        /// Drift the surface a little every frame.
        func startRipple() {
            guard ripple == nil, let view else { return }
            ripple = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
                guard let self else { return }
                self.clock += Float(e.deltaTime)
                self.waterMaterial.textureCoordinateTransform.offset = SIMD2<Float>(self.clock * 0.018, self.clock * 0.011)
                if self.water.isEnabled { self.water.model?.materials = [self.waterMaterial] }
                if let sheet = self.geoEntity?.findEntity(named: "sheet") as? ModelEntity { sheet.model?.materials = [self.waterMaterial] }
            }
        }

        // MARK: scale

        /// Project each tag onto the screen: a point 10 m out along its bearing, dipped below the
        /// horizon by its true angle from eye height, so near drains sit low and far gauges near the horizon.
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard let view, !placements.isEmpty, frame.timestamp - lastProject > 1.0 / 15 else { return }
            lastProject = frame.timestamp
            let t = frame.camera.transform
            let cam = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let fwd = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            var out: [String: CGPoint] = [:]
            for p in placements {
                let th = Float(p.bearing * .pi / 180)
                let el = Float(max(-0.26, -atan(1.4 / max(p.metres, 1))))
                let dir = SIMD3<Float>(sin(th) * cos(el), sin(el), -cos(th) * cos(el))
                guard simd_dot(dir, fwd) > 0.3, let pt = view.project(cam + dir * 10),
                      view.bounds.insetBy(dx: -40, dy: -40).contains(pt) else { continue }
                out[p.id] = pt
            }
            let cb = onProject
            DispatchQueue.main.async { cb(out) }
        }

        /// Until the ground is found, raycast a spot ahead of your feet twice a second.
        func startAutoGround() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
                guard let self, let view = self.view else { return }
                if self.streetOn { return }
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
            // Level, but turned to face the camera, so the gauge and the person stand side by side.
            let a = AnchorEntity(world: SIMD3<Float>(t.x, t.y, t.z))
            if let cam = view.session.currentFrame?.camera.transform {
                let back = SIMD3<Float>(cam.columns.2.x, 0, cam.columns.2.z)
                if simd_length(back) > 0.01 { a.orientation = simd_quatf(angle: atan2(back.x, back.z), axis: SIMD3<Float>(0, 1, 0)) }
            }
            a.addChild(water)
            a.addChild(person)
            view.scene.addAnchor(a)
            groundAnchor = a
            water.position = .zero
            startRipple()
            apply(rise: true)
            onGround(true)
        }

        func setDepth(_ ft: Double?) {
            let m = ft.map { Float($0 / Geo.ftPerM) }
            guard m != depthM else { return }
            depthM = m
            apply(rise: !playing)
        }

        /// Move the water to the depth: slowly when it's a new scenario, quickly while a timeline
        /// plays. The gauge always shows, so a dry spot still has a scale.
        private func apply(rise: Bool) {
            guard let a = groundAnchor else { return }
            let d = max(0, depthM ?? 0)
            let feet = max(3, Int((Double(d) * Geo.ftPerM).rounded(.up)) + 1)
            if ruler?.name != "ruler-\(feet)" {
                ruler?.removeFromParent()
                let r = WaterLook.ruler(feet: feet); r.name = "ruler-\(feet)"
                a.addChild(r); ruler = r
            }
            label?.removeFromParent(); label = nil
            let from = water.isEnabled ? water.position.y : 0
            let duration = rise ? 2.5 : 0.35
            if d > 0.005 {
                if !water.isEnabled { water.position = .zero; water.isEnabled = true }
                water.move(to: Transform(scale: .one, rotation: water.orientation, translation: SIMD3<Float>(0, d, 0)),
                           relativeTo: a, duration: rise ? 2.5 : 0.35, timingFunction: .easeInOut)
                let l = ModelEntity(mesh: .generateText(String(format: "%.1f ft", Double(d) * Geo.ftPerM), extrusionDepth: 0.004, font: .boldSystemFont(ofSize: 0.09)),
                                    materials: [UnlitMaterial(color: .white)])
                l.position = SIMD3<Float>(-0.32, d + 0.03, 0)
                a.addChild(l)
                label = l
            } else if water.isEnabled, from > 0.005 {
                // Drain away, then hide: water drawn under the ground would show without LiDAR.
                water.move(to: Transform(scale: .one, rotation: water.orientation, translation: .zero), relativeTo: a, duration: duration, timingFunction: .easeInOut)
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    if (self?.depthM ?? 0) <= 0.005 { self?.water.isEnabled = false }
                }
            } else {
                water.isEnabled = false
            }
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let p = g.location(in: view)
            switch mode {
            case .water:
                if streetOn { return }
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
#endif
