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
    @State private var mode: Mode = .rain

    /// Two ways to look at water on this ground: rain from a storm settling into the dips, or one
    /// flat level across the whole block (a bathtub view, for a river or tide height).
    enum Mode: String, CaseIterable, Identifiable { case rain = "Rain", level = "Flat level"; var id: String { rawValue } }

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
            .background(Color(red: 0.12, green: 0.15, blue: 0.2))
            panel.padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { LayerMenu(only: [.rainWater, .rivers, .tide, .streetSensors, .floodZones, .levees, .pumps, .drains, .reports, .lowSpots, .higherGround]) }
        .sheet(item: $picked) { p in POIDetail(poi: p, report: report).presentationDetents([.medium, .large]) }
        .task {
            if mode == .rain { showRainLayer() }
            await load(); await refreshWater(); drawLayers()
        }
        .onChange(of: mode) { _, m in
            water?.isHidden = m == .rain
            if m == .rain { showRainLayer() }
            drawLayers()
        }
        .onChange(of: layersOff) { _, _ in Task { await refreshWater(); drawLayers() } }
        .onChange(of: storm) { _, _ in Task { await refreshWater(); drawLayers() } }
        .onChange(of: drainsWorking) { _, _ in Task { await refreshWater(); drawLayers() } }
        .onChange(of: levelFt) { _, v in water?.position.y = Float(v / Geo.ftPerM) }
    }

    private func showRainLayer() {
        var off = Layer.off(layersOff)
        if off.contains(.rainWater) { off.remove(.rainWater); layersOff = Layer.raw(off) }
    }

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("View", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if mode == .rain { rainPanel } else { levelPanel }
        }
    }

    @ViewBuilder private var rainPanel: some View {
        HStack {
            Picker("Storm", selection: $storm) { ForEach(StormCase.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.menu).labelsHidden().fixedSize().padding(.leading, -10)
            Spacer(minLength: 8)
            Text("Drains work").font(.subheadline).lineLimit(1)
            Toggle("Drains work", isOn: $drainsWorking).labelsHidden()
        }
        if Layer.off(layersOff).contains(.rainWater) {
            Button("Show rain water") { showRainLayer() }.font(.subheadline)
        } else if noGrid {
            Text("Rain water needs this place's ground grid. Download Ground and bowls, 10 m, in Offline data.")
                .font(.subheadline).foregroundStyle(.secondary)
        } else if let m = rainMap {
            let here = m.depthFt(coordinate), top = deepestFt(m)
            HStack(spacing: 18) {
                stat(here < 0.05 ? "Dry" : String(format: "%.1f ft", here), "at your spot")
                stat(top < 0.05 ? "Dry" : String(format: "%.1f ft", top), "deepest on this block")
                stat(String(format: "%.1f in", m.rainIn), "of rain")
            }
            if top >= 0.05 { depthKey } else if [.last6, .next24, .next72].contains(storm) {
                Button { storm = .day100 } label: { Label("No standing water from this rain. See a 100-year day", systemImage: "cloud.heavyrain") }
                    .font(.subheadline)
            }
            Text("\(storm.rainSource.0.prefix(1).uppercased() + storm.rainSource.0.dropFirst()) \(storm.rainSource.1.mark). Water depth is Waterline's estimate ○: 80% of rain runs off\(drainsWorking ? ", drains take 0.5 in an hour" : ", drains blocked") ▨.")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            HStack { ProgressView(); Text("Running the rain over this block…").font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var levelPanel: some View {
        HStack {
            Text(String(format: "Water at %.1f ft", levelFt)).font(.headline.monospacedDigit())
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
        Text("Heights in ft NAVD88. One flat level across the block: it ignores levees, drains and where water can actually get in.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var depthKey: some View {
        HStack(spacing: 10) {
            ForEach([("under 0.5 ft", Color(red: 0.35, green: 0.65, blue: 1)), ("0.5 to 1.5", Color(red: 0.15, green: 0.45, blue: 0.95)), ("over 1.5", Color(red: 0.05, green: 0.25, blue: 0.8))], id: \.0) { k in
                HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(k.1).frame(width: 14, height: 10); Text(k.0) }
            }
            Spacer()
            HStack(spacing: 4) { Circle().fill(.white).overlay(Circle().stroke(.blue, lineWidth: 2)).frame(width: 10, height: 10); Text("you") }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    /// The deepest computed water inside the square the 3D view shows.
    private func deepestFt(_ m: DrainageMap) -> Double {
        guard let f = frame else { return 0 }
        let w = m.field.window
        var best: Float = 0
        for i in 0..<m.result.depthM.count where m.result.depthM[i] > best {
            if f.contains(w.coordinate(row: Double(i / w.cols) + 0.5, col: Double(i % w.cols) + 0.5)) { best = m.result.depthM[i] }
        }
        return Double(best) * Geo.ftPerM
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
        rainMap = nil
        let rain = await RainSeries.load(c)
        let hours = rain.hours(s)
        rainMap = await Task.detached(priority: .userInitiated) { DrainageField.near(c).map { DrainageMap.build($0, hours: hours, drainsWorking: w) } }.value
        noGrid = rainMap == nil
    }

    private func drawLayers() {
        guard let s = scene, let f = frame else { return }
        s.rootNode.childNodes.filter { $0.name == SceneLayers.rootName }.forEach { $0.removeFromParentNode() }
        let places = Places.covering(coordinate)
        let root = SceneLayers.build(frame: f, ground: ground, off: Layer.off(layersOff), pois: report?.pois ?? [], places: places, water: mode == .rain ? rainMap : nil)
        if let g = ground(0, 0) { root.addChildNode(SceneLayers.you(at: SCNVector3(0, g, 0))) }
        s.rootNode.addChildNode(root)
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
        built.water.isHidden = mode == .rain
        water = built.water
        scene = built.scene
        patch = p
    }

    nonisolated private static var sky: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 256)).image { ctx in
            let colors = [UIColor(red: 0.42, green: 0.55, blue: 0.68, alpha: 1).cgColor, UIColor(red: 0.12, green: 0.15, blue: 0.2, alpha: 1).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(g, start: CGPoint(x: 0, y: 256), end: .zero, options: [])
        }
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
        cam.camera?.fieldOfView = 50
        cam.position = SCNVector3(0, fill + half * 0.95, half * 1.05)
        cam.look(at: SCNVector3(0, fill, -half * 0.1))
        scn.background.contents = Self.sky
        scn.rootNode.addChildNode(cam)
        return (scn, water, g)
    }
}
