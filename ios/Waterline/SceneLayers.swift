import SwiftUI
import SceneKit
import CoreLocation

/// Map layers in the 3D views. Both views use x = metres east and z = metres south of a centre
/// point, with y = elevation in metres NAVD88, so one builder serves the streamed ground and the
/// lidar scenes. Every node carries a name: "poi:<id>" opens that marker's sheet when tapped.
struct GeoFrame {
    let center: CLLocationCoordinate2D
    let halfM: Double
    /// Radians from true north to the scene's +y (UTM grid convergence for lidar scenes, 0 for the streamed ground).
    var rotation = 0.0
    /// Where `center` sits in the scene's own coordinates.
    var offset: (x: Float, z: Float) = (0, 0)

    private func relative(_ c: CLLocationCoordinate2D) -> (x: Double, z: Double) {
        let e = (c.longitude - center.longitude) * 111_320 * cos(center.latitude * .pi / 180)
        let n = (c.latitude - center.latitude) * 110_574
        let x = e * cos(rotation) - n * sin(rotation), y = e * sin(rotation) + n * cos(rotation)
        return (x, -y)
    }
    func local(_ c: CLLocationCoordinate2D) -> (x: Float, z: Float) {
        let r = relative(c)
        return (Float(r.x) + offset.x, Float(r.z) + offset.z)
    }
    func contains(_ c: CLLocationCoordinate2D, margin: Double = 0) -> Bool {
        let r = relative(c)
        return abs(r.x) <= halfM - margin && abs(r.z) <= halfM - margin
    }
    /// UTM grid convergence: how far the scene's grid north turns from true north.
    static func utmConvergence(_ c: CLLocationCoordinate2D) -> Double {
        let zone = floor((c.longitude + 180) / 6) + 1, lon0 = zone * 6 - 183
        return atan(tan((c.longitude - lon0) * .pi / 180) * sin(c.latitude * .pi / 180))
    }
}

enum SceneLayers {
    static let rootName = "layers"

    static func color(_ l: Layer) -> UIColor {
        switch l {
        case .rainWater: return .systemBlue
        case .rivers: return .systemIndigo
        case .tide: return .systemTeal
        case .floodZones: return .systemBlue
        case .levees: return .brown
        case .pumps: return .systemTeal
        case .drains: return .systemCyan
        case .reports: return .systemPurple
        case .lowSpots: return .systemOrange
        case .streetSensors: return .systemPink
        case .higherGround: return .systemGreen
        case .lidar: return .white
        }
    }

    /// Everything the switches allow, for this frame. `ground` returns metres NAVD88 at a local x, z.
    static func build(frame f: GeoFrame, ground: (Float, Float) -> Float?, off: Set<Layer>,
                      pois: [POI], places: Places?, water: DrainageMap?) -> SCNNode {
        let root = SCNNode(); root.name = rootName
        // Markers: a stalk and a ball, tall enough to see over a block.
        for p in pois where !off.contains(p.group) && f.contains(p.coordinate) {
            let at = f.local(p.coordinate)
            guard let g = ground(at.x, at.z) else { continue }
            root.addChildNode(pin(name: "poi:\(p.id)", at: SCNVector3(at.x, g, at.z), color: p.severity >= 2 ? .systemRed : color(p.group),
                                  height: p.kind == .drain ? 8 : 18))
        }
        if let pl = places {
            if !off.contains(.reports) {
                let dots = pl.flood311Points(near: f.center, within: f.halfM * 1.4).prefix(800)
                for c in dots where f.contains(c) {
                    let at = f.local(c)
                    if let g = ground(at.x, at.z) { root.addChildNode(dot(at: SCNVector3(at.x, g + 0.4, at.z), color: .systemPurple)) }
                }
            }
            if !off.contains(.floodZones) {
                for ring in pl.zone_rings where ring.contains(where: { f.contains(.init(latitude: $0[1], longitude: $0[0]), margin: -50) }) {
                    root.addChildNode(drape(ring, f, ground, color: .systemBlue, lift: 0.6))
                }
            }
            if !off.contains(.levees) {
                for l in pl.levees ?? [] where l.path.contains(where: { f.contains(.init(latitude: $0[1], longitude: $0[0]), margin: -50) }) {
                    root.addChildNode(drape(l.path, f, ground, color: l.kind == "floodwall" ? .systemRed : .brown, lift: 1.2))
                }
            }
        }
        if !off.contains(.rainWater), let w = water { root.addChildNode(waterSurface(w, f)) }
        return root
    }

    static func pin(name: String, at p: SCNVector3, color: UIColor, height: Float) -> SCNNode {
        let n = SCNNode(); n.name = name
        let stalk = SCNCylinder(radius: 0.5, height: CGFloat(height))
        stalk.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(0.85)
        stalk.firstMaterial?.lightingModel = .constant
        let s = SCNNode(geometry: stalk); s.position = SCNVector3(0, height / 2, 0); s.name = name
        let ball = SCNSphere(radius: 3.5)
        ball.firstMaterial?.diffuse.contents = color
        ball.firstMaterial?.lightingModel = .constant
        let b = SCNNode(geometry: ball); b.position = SCNVector3(0, height + 3.5, 0); b.name = name
        n.addChildNode(s); n.addChildNode(b)
        n.position = p
        return n
    }

    private static func dot(at p: SCNVector3, color: UIColor) -> SCNNode {
        let s = SCNSphere(radius: 0.7)
        s.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.8)
        s.firstMaterial?.lightingModel = .constant
        let n = SCNNode(geometry: s); n.position = p
        return n
    }

    /// A line laid on the ground, sampled every few metres so it follows the terrain.
    private static func drape(_ path: [[Double]], _ f: GeoFrame, _ ground: (Float, Float) -> Float?, color: UIColor, lift: Float) -> SCNNode {
        var verts: [SCNVector3] = [], idx: [Int32] = []
        var last: SCNVector3?
        func add(_ v: SCNVector3?) {
            guard let v else { last = nil; return }
            if last != nil { idx += [Int32(verts.count - 1), Int32(verts.count)] }
            verts.append(v); last = v
        }
        for i in 0..<path.count {
            let a = f.local(.init(latitude: path[i][1], longitude: path[i][0]))
            let b = i + 1 < path.count ? f.local(.init(latitude: path[i + 1][1], longitude: path[i + 1][0])) : a
            let steps = max(1, Int(hypot(b.x - a.x, b.z - a.z) / 3))
            for k in 0..<steps {
                let t = Float(k) / Float(steps)
                let x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t
                guard let g = ground(x, z) else { add(nil); continue }
                add(SCNVector3(x, g + lift, z))
            }
        }
        guard idx.count >= 2 else { return SCNNode() }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        geo.firstMaterial?.diffuse.contents = color
        geo.firstMaterial?.lightingModel = .constant
        return SCNNode(geometry: geo)
    }

    /// The rain water estimate as a surface: one quad per wet cell, at the water's own level
    /// (ground + computed depth), so it sits in the dips and nowhere else.
    private static func waterSurface(_ w: DrainageMap, _ f: GeoFrame) -> SCNNode {
        let win = w.field.window
        var verts: [SCNVector3] = [], idx: [Int32] = [], colors: [Float] = []
        for i in 0..<w.result.depthM.count {
            let d = w.result.depthM[i]
            guard d >= 0.03 else { continue }
            let r = i / win.cols, c = i % win.cols
            let g = win.groundM[i]
            guard !g.isNaN else { continue }
            let corners = [win.coordinate(row: Double(r), col: Double(c)), win.coordinate(row: Double(r), col: Double(c + 1)),
                           win.coordinate(row: Double(r + 1), col: Double(c + 1)), win.coordinate(row: Double(r + 1), col: Double(c))]
            guard corners.contains(where: { f.contains($0) }) else { continue }
            let y = g + d
            let base = Int32(verts.count)
            for q in corners { let p = f.local(q); verts.append(SCNVector3(p.x, y, p.z)) }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
            let ft = Double(d) * Geo.ftPerM
            let shade: [Float] = ft < 0.5 ? [0.35, 0.65, 1.0] : ft < 1.5 ? [0.15, 0.45, 0.95] : [0.05, 0.25, 0.8]
            for _ in 0..<4 { colors += shade }
        }
        guard !idx.isEmpty else { return SCNNode() }
        let cData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let cSrc = SCNGeometrySource(data: cData, semantic: .color, vectorCount: verts.count, usesFloatComponents: true,
                                     componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), cSrc], elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        geo.firstMaterial?.isDoubleSided = true
        geo.firstMaterial?.lightingModel = .constant
        geo.firstMaterial?.transparency = 0.8
        let n = SCNNode(geometry: geo); n.name = "rainwater"
        return n
    }
}

/// SceneKit with camera control and taps: a tapped node named "poi:<id>" is reported.
struct SceneHost: UIViewRepresentable {
    let scene: SCNScene
    var onTap: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = scene
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.backgroundColor = .black
        v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return v
    }
    func updateUIView(_ v: SCNView, context: Context) {
        if v.scene !== scene { v.scene = scene }
        context.coordinator.onTap = onTap
    }
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        var onTap: (String) -> Void
        init(onTap: @escaping (String) -> Void) { self.onTap = onTap }
        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? SCNView else { return }
            let hits = v.hitTest(g.location(in: v), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for h in hits {
                var n: SCNNode? = h.node
                while let x = n { if let name = x.name, name.hasPrefix("poi:") { onTap(String(name.dropFirst(4))); return }; n = x.parent }
            }
        }
    }
}

/// The controls under a 3D view for the rain water layer: which storm, and whether drains work.
struct StormControls: View {
    @AppStorage("storm") private var storm: StormCase = .next24
    @AppStorage("drainsWorking") private var drainsWorking = true
    var note: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Rain", selection: $storm) { ForEach(StormCase.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            Toggle("Drains working", isOn: $drainsWorking).font(.caption)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
