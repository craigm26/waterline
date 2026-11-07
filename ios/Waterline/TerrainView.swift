import SwiftUI
import SceneKit
import CoreLocation

/// The phone-only 3D view: about 1 m bare-earth ground for any block in the US, streamed from the
/// USGS 3DEP elevation service with no pack. It's a surface, so it shows the shape of the ground
/// but not buildings. Downloaded lidar scenes show the real points.
struct TerrainPatch {
    let side: Int          // samples per side
    let spacingM: Double
    let z: [Float]         // m NAVD88, north row first; NaN = no data

    private static let service = "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/exportImage"

    static func load(_ c: CLLocationCoordinate2D, halfM: Double = 200) async throws -> TerrainPatch {
        let name = String(format: "terrain-%.4f_%.4f_%.0f.tif", c.latitude, c.longitude, halfM)
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        let side = 400, spacing = halfM * 2 / Double(side)
        if let d = try? Data(contentsOf: file), let p = parse(d, spacing: spacing) { return p }
        // Web Mercator is stretched by 1/cos(lat), so a real 400 m square is wider in projected metres.
        let r = 6378137.0, s = halfM / cos(c.latitude * .pi / 180)
        let cx = c.longitude * .pi / 180 * r, cy = log(tan(.pi / 4 + c.latitude * .pi / 360)) * r
        var u = URLComponents(string: service)!
        u.queryItems = [.init(name: "bbox", value: String(format: "%.1f,%.1f,%.1f,%.1f", cx - s, cy - s, cx + s, cy + s)),
                        .init(name: "bboxSR", value: "3857"), .init(name: "imageSR", value: "3857"), .init(name: "size", value: "\(side),\(side)"),
                        .init(name: "format", value: "tiff"), .init(name: "pixelType", value: "F32"), .init(name: "f", value: "image")]
        var q = URLRequest(url: u.url!, timeoutInterval: 60)
        q.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await URLSession.shared.data(for: q)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let p = parse(d, spacing: spacing) else { throw URLError(.badServerResponse) }
        try? d.write(to: file)
        return p
    }

    /// Reads the one TIFF this service returns: little-endian, tiled, uncompressed, float32.
    static func parse(_ d: Data, spacing: Double) -> TerrainPatch? {
        guard d.count > 16, d[d.startIndex] == 0x49, d[d.startIndex + 1] == 0x49 else { return nil }
        let bytes = [UInt8](d)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let ifd = u32(4)
        guard ifd + 2 < bytes.count else { return nil }
        var tags: [Int: (type: Int, count: Int, at: Int)] = [:]
        for i in 0..<u16(ifd) {
            let e = ifd + 2 + i * 12
            guard e + 12 <= bytes.count else { return nil }
            tags[u16(e)] = (u16(e + 2), u32(e + 4), e + 8)
        }
        func single(_ t: Int) -> Int? {
            guard let x = tags[t] else { return nil }
            return x.type == 3 ? u16(x.at) : u32(x.at)
        }
        func list(_ t: Int) -> [Int]? {
            guard let x = tags[t] else { return nil }
            if x.count == 1 { return [single(t) ?? 0] }
            let base = u32(x.at)
            guard base + x.count * 4 <= bytes.count else { return nil }
            return (0..<x.count).map { u32(base + $0 * 4) }
        }
        guard let w = single(256), let h = single(257), w == h, w > 1, single(259) == 1, single(258) == 32,
              let tw = single(322), let th = single(323), let offs = list(324) else { return nil }
        let across = (w + tw - 1) / tw
        var z = [Float](repeating: .nan, count: w * h)
        for (i, off) in offs.enumerated() {
            let col0 = (i % across) * tw, row0 = (i / across) * th
            guard off + tw * th * 4 <= bytes.count else { return nil }
            for r in 0..<th where row0 + r < h {
                for c in 0..<tw where col0 + c < w {
                    let o = off + (r * tw + c) * 4
                    let v = Float(bitPattern: UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24)
                    if v > -500, v < 9000 { z[(row0 + r) * w + col0 + c] = v }
                }
            }
        }
        guard z.contains(where: { !$0.isNaN }) else { return nil }
        return TerrainPatch(side: w, spacingM: spacing, z: z)
    }

    var groundValues: [Float] { z.filter { !$0.isNaN } }
}

struct TerrainSceneView: View {
    let title: String
    let coordinate: CLLocationCoordinate2D
    var presets: [(String, Double)] = []     // label, ft NAVD88
    var report: SpotReport? = nil
    @AppStorage(Layer.storageKey) private var layersOff = Layer.defaultOff
    @AppStorage("storm") private var storm: StormCase = .next24
    @AppStorage("drainsWorking") private var drainsWorking = true
    @State private var rainMap: DrainageMap?
    @State private var noGrid = false
    @State private var picked: POI?
    @State private var patch: TerrainPatch?
    @State private var scene: SCNScene?
    @State private var water: SCNNode?
    @State private var failed = false
    @State private var levelFt = 0.0
    @State private var range = 0.0...1.0
    @State private var sorted: [Float] = []

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let s = scene {
                    SceneHost(scene: s) { id in picked = report?.pois.first { $0.id == id } }
                } else if failed {
                    Text("Couldn't reach the USGS elevation service. Check your connection.").foregroundStyle(.secondary).padding()
                } else {
                    ProgressView("Streaming the ground from USGS…")
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.black)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(String(format: "Water %.1f ft NAVD88", levelFt)).font(.headline.monospacedDigit())
                    Spacer()
                    if scene != nil { Text(wetShare).font(.subheadline.monospacedDigit()) }
                }
                if scene != nil { Slider(value: $levelFt, in: range, step: 0.1) }
                if !presets.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(presets.indices, id: \.self) { i in
                                Button(presets[i].0) { levelFt = min(max(presets[i].1, range.lowerBound), range.upperBound) }.buttonStyle(.bordered).font(.caption)
                            }
                        }
                    }
                }
                if scene != nil, !Layer.off(layersOff).contains(.rainWater) {
                    StormControls(note: noGrid ? "Rain water needs this place's ground grid: download Ground and bowls, 10 m, in Offline data." : rainMap.map { String(format: "%.2f in of rain · Waterline estimate, assumed runoff and drains", $0.rainIn) })
                }
                Text("USGS 3DEP bare ground, about 1 m, streamed live. Buildings and trees are removed. The slider is a bathtub level: it ignores levees, drains and where water can actually get in. Rain water (Layers) is Waterline's estimate of where rain stands. Tap a marker for its sheet.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { LayerMenu(only: [.rainWater, .rivers, .tide, .streetSensors, .floodZones, .levees, .pumps, .drains, .reports, .lowSpots, .higherGround]) }
        .sheet(item: $picked) { p in POIDetail(poi: p, report: report).presentationDetents([.medium, .large]) }
        .task { await load(); await refreshWater(); drawLayers() }
        .onChange(of: layersOff) { _, _ in Task { await refreshWater(); drawLayers() } }
        .onChange(of: storm) { _, _ in Task { await refreshWater(); drawLayers() } }
        .onChange(of: drainsWorking) { _, _ in Task { await refreshWater(); drawLayers() } }
        .onChange(of: levelFt) { _, v in water?.position.y = Float(v / Geo.ftPerM) }
    }

    private var frame: GeoFrame? { patch.map { GeoFrame(center: coordinate, halfM: Double($0.side) * $0.spacingM / 2) } }

    /// Ground height under a local x, z (metres east, south of the centre).
    private func ground(_ x: Float, _ z: Float) -> Float? {
        guard let p = patch else { return nil }
        let half = Float(Double(p.side) * p.spacingM / 2), sp = Float(p.spacingM)
        let c = Int((x + half) / sp), r = Int((z + half) / sp)
        guard r >= 0, c >= 0, r < p.side, c < p.side else { return nil }
        let v = p.z[r * p.side + c]
        return v.isNaN ? nil : v
    }

    private func refreshWater() async {
        guard !Layer.off(layersOff).contains(.rainWater) else { rainMap = nil; return }
        let c = coordinate, s = storm, w = drainsWorking
        let rain = await RainSeries.load(c)
        let hours = rain.hours(s)
        rainMap = await Task.detached(priority: .userInitiated) { DrainageField.near(c).map { DrainageMap.build($0, hours: hours, drainsWorking: w) } }.value
        noGrid = rainMap == nil
    }

    private func drawLayers() {
        guard let s = scene, let f = frame else { return }
        s.rootNode.childNodes.filter { $0.name == SceneLayers.rootName }.forEach { $0.removeFromParentNode() }
        let places = Places.covering(coordinate)
        s.rootNode.addChildNode(SceneLayers.build(frame: f, ground: ground, off: Layer.off(layersOff), pois: report?.pois ?? [], places: places, water: rainMap))
    }

    private var wetShare: String {
        guard !sorted.isEmpty else { return "" }
        let z = Float(levelFt / Geo.ftPerM)
        var lo = 0, hi = sorted.count
        while lo < hi { let m = (lo + hi) / 2; if sorted[m] < z { lo = m + 1 } else { hi = m } }
        return "\(Int((Double(lo) / Double(sorted.count) * 100).rounded()))% of ground under"
    }

    private func load() async {
        guard scene == nil else { return }
        guard let p = try? await TerrainPatch.load(coordinate) else { failed = true; return }
        let built = await Task.detached(priority: .userInitiated) { Self.build(p) }.value
        let g = built.sorted
        let lowFt = Double(g.first ?? 0) * Geo.ftPerM, midFt = Double(g[g.count / 2]) * Geo.ftPerM
        sorted = g
        range = (lowFt.rounded(.down) - 1)...max(midFt.rounded(.up) + 15, lowFt + 5)
        levelFt = lowFt.rounded(.down)
        built.water.position.y = Float(levelFt / Geo.ftPerM)
        water = built.water
        scene = built.scene
        patch = p
    }

    nonisolated private static func build(_ p: TerrainPatch) -> (scene: SCNScene, water: SCNNode, sorted: [Float]) {
        let g = p.groundValues.sorted()
        let fill = g[g.count / 2]
        let step = 2, n = p.side / step
        let d = Float(p.spacingM) * Float(step), half = d * Float(n) / 2
        func h(_ r: Int, _ c: Int) -> Float {
            let v = p.z[min(r * step, p.side - 1) * p.side + min(c * step, p.side - 1)]
            return v.isNaN ? fill : v
        }
        var verts = [SCNVector3](), normals = [SCNVector3](), colors = [Float](), idx = [Int32]()
        verts.reserveCapacity(n * n); normals.reserveCapacity(n * n); colors.reserveCapacity(n * n * 3)
        let lo = g[g.count / 50], hi = max(g[g.count * 49 / 50], lo + 1)
        for r in 0..<n {
            for c in 0..<n {
                let z = h(r, c)
                verts.append(SCNVector3(Float(c) * d - half, z, Float(r) * d - half))
                let dx = h(r, min(c + 1, n - 1)) - h(r, max(c - 1, 0)), dz = h(min(r + 1, n - 1), c) - h(max(r - 1, 0), c)
                normals.append(SCNVector3(-dx, 2 * d, -dz))
                let t = min(max((z - lo) / (hi - lo), 0), 1)
                colors += [0.45 + 0.4 * t, 0.42 + 0.33 * t, 0.34 + 0.2 * t]
            }
        }
        idx.reserveCapacity((n - 1) * (n - 1) * 6)
        for r in 0..<(n - 1) {
            for c in 0..<(n - 1) {
                let a = Int32(r * n + c), b = a + 1, e = a + Int32(n), f = e + 1
                idx += [a, e, b, b, e, f]
            }
        }
        let cData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let cSrc = SCNGeometrySource(data: cData, semantic: .color, vectorCount: verts.count, usesFloatComponents: true,
                                     componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals), cSrc],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        geo.firstMaterial?.lightingModel = .lambert
        geo.firstMaterial?.isDoubleSided = true
        let scn = SCNScene()
        scn.rootNode.addChildNode(SCNNode(geometry: geo))
        let side = CGFloat(half * 2)
        let plane = SCNPlane(width: side, height: side)
        plane.firstMaterial?.diffuse.contents = UIColor(red: 0.12, green: 0.55, blue: 0.95, alpha: 0.5)
        plane.firstMaterial?.isDoubleSided = true
        plane.firstMaterial?.lightingModel = .constant
        let water = SCNNode(geometry: plane)
        water.eulerAngles.x = -.pi / 2
        scn.rootNode.addChildNode(water)
        let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera?.zFar = 5000
        cam.position = SCNVector3(0, fill + half * 1.1, half * 1.5)
        cam.look(at: SCNVector3(0, fill, 0))
        scn.rootNode.addChildNode(cam)
        return (scn, water, g)
    }
}
