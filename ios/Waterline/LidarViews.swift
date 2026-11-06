import SwiftUI
import SceneKit
import CoreLocation

/// A downloaded point-cloud scene (sf-lidar-scenes pack): 14 bytes per point, float32 x,y,z in
/// metres around a local origin (z NAVD88), uint8 ASPRS class, uint8 intensity.
struct LidarScene: Identifiable, Hashable {
    let id: String          // file stem, e.g. hs02_folsom
    let title: String
    let coordinate: CLLocationCoordinate2D?

    static func == (a: LidarScene, b: LidarScene) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Scenes in the pack, located from the city layers (hotspot rank in the file name).
    static var installed: [LidarScene] {
        guard PackStore.installedVersion("sf-lidar-scenes") != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: PackStore.folder("sf-lidar-scenes").path) else { return [] }
        return names.filter { $0.hasSuffix(".bin") }.sorted().map { f -> LidarScene in
            let stem = String(f.dropLast(4))
            if stem.hasPrefix("coast") {
                return LidarScene(id: stem, title: "Ferry Building & Embarcadero seawall",
                                  coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3935))
            }
            let rank = Int(stem.dropFirst(2).prefix(2)) ?? 0
            let spot = Places.shared?.hotspots.first { $0.rank == rank }
            return LidarScene(id: stem, title: spot.map { "Low spot #\($0.rank): \($0.name)" } ?? stem, coordinate: spot?.coordinate)
        }
    }

    static func nearest(to c: CLLocationCoordinate2D, within m: Double = 400) -> LidarScene? {
        installed.compactMap { s in s.coordinate.map { (s, Geo.distance(c, $0)) } }.filter { $0.1 <= m }.min { $0.1 < $1.1 }?.0
    }
}

/// Orbit the point cloud and raise the water. Ground points under the water are counted, so the
/// slider reads as "how much of this block is wet", not just a picture.
struct LidarSceneView: View {
    let scene: LidarScene
    var presets: [(String, Double)] = []
    @State private var levelFt = 7.71            // NOS minor flood, ft MLLW at 9414290
    @State private var loaded: Loaded?
    @State private var failed = false

    struct Loaded { let scn: SCNScene; let water: SCNNode; let groundZ: [Float] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let l = loaded {
                    SceneView(scene: l.scn, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                } else if failed {
                    Text("Couldn't read this scene.").foregroundStyle(.secondary)
                } else {
                    ProgressView("Loading points…")
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.black)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(String(format: "Water %.1f ft MLLW", levelFt)).font(.headline.monospacedDigit())
                    Spacer()
                    if let l = loaded { Text(wetShare(l)).font(.subheadline.monospacedDigit()) }
                }
                Slider(value: $levelFt, in: 4...16, step: 0.1)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        let all = presets + Self.thresholds
                        ForEach(all.indices, id: \.self) { i in
                            Button(all[i].0) { levelFt = all[i].1 }.buttonStyle(.bordered).font(.caption)
                        }
                    }
                }
                Text("USGS 3DEP lidar, 2023. Points: tan = ground, blue = water, grey = buildings and everything else. A bathtub view of this block: it ignores where water can actually get in. The Here tab has the overland answer.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(scene.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: levelFt) { _, v in
            if let w = loaded?.water { w.position.y = Float((v + 0.06) / Geo.ftPerM) }   // ft MLLW -> m NAVD88
        }
    }

    static let thresholds: [(String, Double)] = [("NWS minor 7.0", 7.04), ("NOS minor 7.7", 7.71), ("NOS moderate 8.6", 8.64), ("NOS major 9.9", 9.91)]

    private func wetShare(_ l: Loaded) -> String {
        let z = Float((levelFt + 0.06) / Geo.ftPerM)
        let wet = l.groundZ.reduce(0) { $1 < z ? $0 + 1 : $0 }
        return "\(Int((Double(wet) / Double(max(l.groundZ.count, 1)) * 100).rounded()))% of ground under"
    }

    private func load() async {
        guard loaded == nil, let url = PackStore.file("sf-lidar-scenes", scene.id + ".bin") else { failed = true; return }
        let level = levelFt
        let result = await Task.detached(priority: .userInitiated) { () -> Loaded? in
            guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count % 14 == 0 else { return nil }
            let n = d.count / 14
            var verts = [SCNVector3](), colors = [Float](), ground = [Float]()
            verts.reserveCapacity(n); colors.reserveCapacity(n * 3)
            var minX = Float.infinity, maxX = -Float.infinity, minY = Float.infinity, maxY = -Float.infinity, minZ = Float.infinity
            d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for i in 0..<n {
                    let o = i * 14
                    let x = b.loadUnaligned(fromByteOffset: o, as: Float.self)
                    let y = b.loadUnaligned(fromByteOffset: o + 4, as: Float.self)
                    let z = b.loadUnaligned(fromByteOffset: o + 8, as: Float.self)
                    let cls = b[o + 12]
                    if cls == 7 || cls == 18 { continue }        // noise
                    verts.append(SCNVector3(x, z, -y))           // SceneKit is y-up
                    let rgb: (Float, Float, Float)
                    switch cls {
                    case 2: rgb = (0.78, 0.66, 0.48); ground.append(z)
                    case 9: rgb = (0.20, 0.45, 0.85)
                    default:
                        let g = 0.35 + 0.5 * Float(b[o + 13]) / 255
                        rgb = (g, g, g)
                    }
                    colors += [rgb.0, rgb.1, rgb.2]
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); minZ = min(minZ, z)
                }
            }
            let count = verts.count
            let vSrc = SCNGeometrySource(vertices: verts)
            let cData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            let cSrc = SCNGeometrySource(data: cData, semantic: .color, vectorCount: count, usesFloatComponents: true,
                                         componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            let idx = (0..<Int32(count)).map { $0 }
            let elem = SCNGeometryElement(indices: idx, primitiveType: .point)
            elem.pointSize = 2
            elem.minimumPointScreenSpaceRadius = 1
            elem.maximumPointScreenSpaceRadius = 3
            let geo = SCNGeometry(sources: [vSrc, cSrc], elements: [elem])
            geo.firstMaterial?.lightingModel = .constant
            let scn = SCNScene()
            scn.rootNode.addChildNode(SCNNode(geometry: geo))

            let w = CGFloat(maxX - minX), h = CGFloat(maxY - minY)
            let plane = SCNPlane(width: w, height: h)
            plane.firstMaterial?.diffuse.contents = UIColor(red: 0.12, green: 0.55, blue: 0.95, alpha: 0.45)
            plane.firstMaterial?.isDoubleSided = true
            plane.firstMaterial?.lightingModel = .constant
            let water = SCNNode(geometry: plane)
            water.eulerAngles.x = -.pi / 2
            water.position = SCNVector3((minX + maxX) / 2, Float((level + 0.06) / Geo.ftPerM), -(minY + maxY) / 2)
            scn.rootNode.addChildNode(water)

            let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera?.zFar = 5000
            let span = max(maxX - minX, maxY - minY)
            cam.position = SCNVector3((minX + maxX) / 2, minZ + span * 0.6, -(minY + maxY) / 2 + span * 0.9)
            cam.look(at: SCNVector3((minX + maxX) / 2, minZ, -(minY + maxY) / 2))
            scn.rootNode.addChildNode(cam)
            return Loaded(scn: scn, water: water, groundZ: ground)
        }.value
        if let r = result { loaded = r } else { failed = true }
    }
}

/// Settings › Offline data: download, open and remove packs.
struct DataPacksView: View {
    @StateObject private var store = PackStore.shared
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                Text("Download lidar and maps to use Waterline without a connection, look at the point clouds, or open the raw files in other apps (Files › On My iPhone › Waterline).")
                    .font(.subheadline)
            }
            if let m = store.manifest {
                ForEach(m.packs) { p in packRow(p) }
            } else if let e = store.manifestError {
                Text(e).foregroundStyle(.orange)
                Button("Try again") { Task { await store.load() } }
            } else {
                ProgressView()
            }
            if !LidarScene.installed.isEmpty {
                Section("Point clouds on this phone") {
                    ForEach(LidarScene.installed) { s in
                        NavigationLink(s.title) { LidarSceneView(scene: s, presets: presets) }
                    }
                }
            }
            Section {
                Text("Data: USGS 3DEP lidar (public domain). Downloads come from github.com/craigm26/waterline releases and are checked against SHA-256 before they're used.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Offline data")
        .task { await store.load() }
    }

    /// Scenario levels from the current report, so the viewer's buttons match the Here tab.
    private var presets: [(String, Double)] {
        guard let t = model.report?.tide else { return [] }
        var out: [(String, Double)] = []
        if let h = t.highest { out.append((String(format: "Highest this month %.1f", h.ft), h.ft)) }
        if let h = t.highest, let a = t.anomalyFt, a > 0.05 { out.append((String(format: "+ anomaly %.1f", h.ft + a), h.ft + a)) }
        return out
    }

    @ViewBuilder private func packRow(_ p: PackStore.Pack) -> some View {
        let state = store.states[p.id] ?? .notInstalled
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(p.title).font(.headline)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: p.total_bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
            Text(p.summary).font(.caption).foregroundStyle(.secondary)
            switch state {
            case .notInstalled:
                Button("Download") { store.download(p) }.buttonStyle(.borderedProminent)
            case .downloading(let f):
                HStack { ProgressView(value: f); Button("Cancel") { store.cancel(p.id) }.font(.caption) }
            case .verifying:
                ProgressView("Checking…").font(.caption)
            case .installed:
                HStack {
                    Label("On this phone", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Spacer()
                    Button("Remove", role: .destructive) { store.remove(p.id) }.font(.caption)
                }
            case .failed(let why):
                Text(why).font(.caption).foregroundStyle(.red)
                Button("Retry") { store.download(p) }.buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
