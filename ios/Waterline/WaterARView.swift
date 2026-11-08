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
            waterMaterial = Self.makeWaterMaterial()
            water = ModelEntity(mesh: .generatePlane(width: 30, depth: 30), materials: [waterMaterial])
            water.isEnabled = false
            person = Self.makePerson()
            person.position = SIMD3<Float>(0.75, 0, 0)
            super.init()
        }

        // MARK: water look

        /// Flood water is murky, not pool blue: a brown-grey surface with soft streaks, tiled
        /// every 2.5 m and drifting slowly so it reads as moving water.
        private static func makeWaterMaterial() -> PhysicallyBasedMaterial {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: UIColor(red: 0.42, green: 0.37, blue: 0.27, alpha: 1))
            if let img = streaks(), let tex = try? TextureResource.generate(from: img, options: .init(semantic: .color)) {
                let d = MTLSamplerDescriptor()
                d.sAddressMode = .repeat; d.tAddressMode = .repeat
                d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
                m.baseColor = .init(tint: .white, texture: .init(tex, sampler: .init(d)))
            }
            m.roughness = .init(floatLiteral: 0.15)
            m.metallic = .init(floatLiteral: 0.0)
            m.blending = .transparent(opacity: .init(floatLiteral: 0.78))
            m.textureCoordinateTransform.scale = SIMD2<Float>(12, 12)
            return m
        }

        /// A seamless 256 px tile: sums of whole-period waves, so its edges meet.
        private static func streaks() -> CGImage? {
            let n = 256
            var px = [UInt8](repeating: 255, count: n * n * 4)
            let tau = Float.pi * 2
            for y in 0..<n {
                for x in 0..<n {
                    let u = Float(x) / Float(n), v = Float(y) / Float(n)
                    var t = sin(tau * (3 * u + 2 * v)) * 0.5 + sin(tau * (5 * u - 3 * v) + 1.3) * 0.3
                    t += sin(tau * (2 * u + 7 * v) + 2.1) * 0.25 + sin(tau * (9 * u + 4 * v) + 0.7) * 0.12
                    let k = max(0, min(1, (t + 1.2) / 2.4))
                    let hi = pow(k, 3)                       // a few bright ridges
                    let i = (y * n + x) * 4
                    px[i] = UInt8(min(255, 95 + 55 * k + 70 * hi))
                    px[i + 1] = UInt8(min(255, 84 + 50 * k + 66 * hi))
                    px[i + 2] = UInt8(min(255, 60 + 38 * k + 60 * hi))
                }
            }
            return px.withUnsafeMutableBytes { b in
                CGContext(data: b.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
            }
        }

        /// Drift the surface a little every frame.
        func startRipple() {
            guard ripple == nil, let view else { return }
            ripple = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
                guard let self, self.water.isEnabled else { return }
                self.clock += Float(e.deltaTime)
                self.waterMaterial.textureCoordinateTransform.offset = SIMD2<Float>(self.clock * 0.018, self.clock * 0.011)
                self.water.model?.materials = [self.waterMaterial]
            }
        }

        // MARK: scale

        /// A person 5 ft 9 in (1.75 m) tall, in plain grey blocks, standing on the ground.
        private static func makePerson() -> Entity {
            var mat = PhysicallyBasedMaterial()
            mat.baseColor = .init(tint: UIColor(white: 0.85, alpha: 1))
            mat.roughness = .init(floatLiteral: 0.8)
            mat.blending = .transparent(opacity: .init(floatLiteral: 0.92))
            let p = Entity()
            func part(_ mesh: MeshResource, _ at: SIMD3<Float>) {
                let e = ModelEntity(mesh: mesh, materials: [mat]); e.position = at; p.addChild(e)
            }
            part(.generateBox(size: SIMD3<Float>(0.13, 0.84, 0.15), cornerRadius: 0.05), SIMD3<Float>(-0.09, 0.42, 0))
            part(.generateBox(size: SIMD3<Float>(0.13, 0.84, 0.15), cornerRadius: 0.05), SIMD3<Float>(0.09, 0.42, 0))
            part(.generateBox(size: SIMD3<Float>(0.38, 0.62, 0.21), cornerRadius: 0.07), SIMD3<Float>(0, 1.15, 0))
            part(.generateBox(size: SIMD3<Float>(0.08, 0.6, 0.1), cornerRadius: 0.04), SIMD3<Float>(-0.25, 1.13, 0))
            part(.generateBox(size: SIMD3<Float>(0.08, 0.6, 0.1), cornerRadius: 0.04), SIMD3<Float>(0.25, 1.13, 0))
            part(.generateSphere(radius: 0.11), SIMD3<Float>(0, 1.62, 0))
            let tag = ModelEntity(mesh: .generateText("5 ft 9 in", extrusionDepth: 0.002, font: .systemFont(ofSize: 0.06)),
                                  materials: [UnlitMaterial(color: .white)])
            tag.position = SIMD3<Float>(-0.14, 1.8, 0)
            p.addChild(tag)
            return p
        }

        /// A staff gauge: a white board marked every half foot, numbered every foot, tall enough
        /// to stand a foot over the water.
        private static func makeRuler(feet: Int) -> Entity {
            let r = Entity()
            let ftM = Float(1 / Geo.ftPerM)
            let h = Float(feet) * ftM
            let board = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.06, h, 0.012)), materials: [UnlitMaterial(color: .white)])
            board.position = SIMD3<Float>(0, h / 2, 0)
            r.addChild(board)
            for k in 1...(feet * 2) {
                let y = Float(k) * ftM / 2, whole = k % 2 == 0
                let tick = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(whole ? 0.06 : 0.03, 0.008, 0.014)), materials: [UnlitMaterial(color: .black)])
                tick.position = SIMD3<Float>(whole ? 0 : -0.015, y, 0.001)
                r.addChild(tick)
                if whole {
                    let t = ModelEntity(mesh: .generateText("\(k / 2) ft", extrusionDepth: 0.002, font: .boldSystemFont(ofSize: 0.05)),
                                        materials: [UnlitMaterial(color: .white)])
                    t.position = SIMD3<Float>(0.045, y - 0.02, 0)
                    r.addChild(t)
                }
            }
            return r
        }

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
                let r = Self.makeRuler(feet: feet); r.name = "ruler-\(feet)"
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
