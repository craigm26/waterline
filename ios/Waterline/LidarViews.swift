import SwiftUI
import SceneKit
import CoreLocation

/// A downloaded point-cloud scene (sf-lidar-scenes pack): 14 bytes per point, float32 x,y,z in
/// metres around a local origin (z NAVD88), uint8 ASPRS class, uint8 intensity.
struct LidarScene: Identifiable, Hashable {
    let id: String          // file stem, e.g. hs02_folsom or sacramento_ls01
    let pack: String
    let title: String
    let coordinate: CLLocationCoordinate2D?
    /// SF's viewer works in ft MLLW at the Fort Point gauge; everywhere else in ft NAVD88.
    var isSF: Bool { pack == "sf-lidar-scenes" }
    var groundFt: ClosedRange<Double>? = nil
    var survey: String? = nil

    static func == (a: LidarScene, b: LidarScene) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    private struct Meta: Decodable { let title: String; let lon: Double; let lat: Double; let ground_p5_m: Double; let ground_p50_m: Double; let survey: String? }
    private static var cache: [LidarScene]?
    private static let lock = NSLock()
    static func reload() { lock.lock(); cache = nil; lock.unlock() }

    /// Every scene on the phone. SF's are located from the city layers (hotspot rank in the file
    /// name); other cities' carry their place and title in the scene's JSON.
    static var installed: [LidarScene] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        var out: [LidarScene] = []
        let fm = FileManager.default
        for pack in ((try? fm.contentsOfDirectory(atPath: PackStore.root.path)) ?? []).filter({ $0.hasSuffix("-scenes") }).sorted()
        where PackStore.installedVersion(pack) != nil {
            let dir = PackStore.folder(pack)
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for f in names.filter({ $0.hasSuffix(".bin") }).sorted() {
                let stem = String(f.dropLast(4))
                if pack == "sf-lidar-scenes" {
                    if stem.hasPrefix("coast") {
                        out.append(LidarScene(id: stem, pack: pack, title: "Ferry Building & Embarcadero seawall",
                                              coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3935)))
                    } else {
                        let rank = Int(stem.dropFirst(2).prefix(2)) ?? 0
                        let spot = Places.shared?.hotspots.first { $0.rank == rank }
                        out.append(LidarScene(id: stem, pack: pack, title: spot.map { "Low spot #\($0.rank): \($0.name)" } ?? stem, coordinate: spot?.coordinate))
                    }
                } else if let d = try? Data(contentsOf: dir.appendingPathComponent(stem + ".json")), let m = try? JSONDecoder().decode(Meta.self, from: d) {
                    let lo = (m.ground_p5_m * Geo.ftPerM).rounded(.down) - 2, mid = (m.ground_p50_m * Geo.ftPerM).rounded(.up)
                    out.append(LidarScene(id: stem, pack: pack, title: m.title, coordinate: .init(latitude: m.lat, longitude: m.lon),
                                          groundFt: lo...max(mid + 15, lo + 5), survey: m.survey))
                }
            }
        }
        cache = out
        return out
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
    @State private var levelFt = 7.71            // NOS minor flood, ft MLLW at 9414290 (SF); set on load elsewhere
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
                    Text(String(format: "Water %.1f ft \(scene.isSF ? "MLLW" : "NAVD88")", levelFt)).font(.headline.monospacedDigit())
                    Spacer()
                    if let l = loaded { Text(wetShare(l)).font(.subheadline.monospacedDigit()) }
                }
                Slider(value: $levelFt, in: scene.isSF ? 4...16 : (scene.groundFt ?? 0...20), step: 0.1)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        let all = presets + (scene.isSF ? Self.thresholds : [])
                        ForEach(all.indices, id: \.self) { i in
                            Button(all[i].0) { levelFt = all[i].1 }.buttonStyle(.bordered).font(.caption)
                        }
                    }
                }
                Text("USGS 3DEP lidar\(scene.isSF ? ", 2023" : scene.survey.map { " (\($0))" } ?? ""). Points: tan = ground, blue = water, grey = buildings and everything else. A bathtub view of this block: it ignores where water can actually get in. The Here tab has the overland answer.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(scene.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: levelFt) { _, v in
            if let w = loaded?.water { w.position.y = Float((v + datumFt) / Geo.ftPerM) }   // to m NAVD88
        }
    }

    static let thresholds: [(String, Double)] = [("NWS minor 7.0", 7.04), ("NOS minor 7.7", 7.71), ("NOS moderate 8.6", 8.64), ("NOS major 9.9", 9.91)]

    /// ft MLLW + 0.06 = ft NAVD88 in SF; other cities' levels are already NAVD88.
    private var datumFt: Double { scene.isSF ? 0.06 : 0 }

    private func wetShare(_ l: Loaded) -> String {
        let z = Float((levelFt + datumFt) / Geo.ftPerM)
        let wet = l.groundZ.reduce(0) { $1 < z ? $0 + 1 : $0 }
        return "\(Int((Double(wet) / Double(max(l.groundZ.count, 1)) * 100).rounded()))% of ground under"
    }

    private func load() async {
        guard loaded == nil, let url = PackStore.file(scene.pack, scene.id + ".bin") else { failed = true; return }
        if !scene.isSF, let r = scene.groundFt { levelFt = r.lowerBound }
        let level = levelFt + datumFt
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
            water.position = SCNVector3((minX + maxX) / 2, Float(level / Geo.ftPerM), -(minY + maxY) / 2)
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

/// Settings › Offline data: one collapsed group per place, nearest first, with everything for that place.
struct DataPacksView: View {
    @StateObject private var store = PackStore.shared
    @EnvironmentObject var model: AppModel
    @State private var open: Set<String> = []

    /// Places nearest to the spot being checked first; the one you're in starts open.
    private var groups: [PackStore.Group] {
        let all = store.manifest?.groups ?? []
        guard let c = model.report?.coordinate else { return all }
        return all.sorted { Geo.distance(c, $0.center) < Geo.distance(c, $1.center) }
    }
    private var ungrouped: [PackStore.Pack] {
        let ids = Set((store.manifest?.groups ?? []).map(\.id))
        return store.manifest?.packs.filter { !ids.contains($0.group ?? "") } ?? []
    }

    var body: some View {
        List {
            Section {
                Text("Download lidar and maps to use Waterline without a connection, look at the point clouds, or open the raw files in other apps (Files › On My iPhone › Waterline).")
                    .font(.subheadline)
            }
            if store.manifest != nil {
                ForEach(groups) { g in groupSection(g) }
                if !ungrouped.isEmpty { Section { ForEach(ungrouped) { p in packRow(p) } } }
            } else if let e = store.manifestError {
                Text(e).foregroundStyle(.orange)
                Button("Try again") { Task { await store.load() } }
            } else {
                ProgressView()
            }
            Section {
                Text("Data: USGS 3DEP lidar (public domain), FEMA, USACE and city open data. Downloads come from github.com/craigm26/waterline releases and are checked against SHA-256 before they're used.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Offline data")
        .task {
            await store.load()
            if let c = model.report?.coordinate, let g = store.manifest?.groups?.first(where: { $0.contains(c) }) { open.insert(g.id) }
        }
    }

    private func groupSection(_ g: PackStore.Group) -> some View {
        let packs = store.packs(in: g.id)
        let have = packs.filter { store.states[$0.id] == .installed }.count
        let missing = packs.filter { store.states[$0.id] == .notInstalled || store.states[$0.id] == nil }
        let scenes = LidarScene.installed.filter { packs.map(\.id).contains($0.pack) }
        return Section {
            DisclosureGroup(isExpanded: Binding(get: { open.contains(g.id) }, set: { if $0 { open.insert(g.id) } else { open.remove(g.id) } })) {
                if let w = g.why { Text(w).font(.caption).foregroundStyle(.secondary) }
                if let c = g.caveat { Text(c).font(.caption).foregroundStyle(.orange) }
                if !missing.isEmpty {
                    Button("Download everything (\(size(missing.reduce(0) { $0 + $1.total_bytes })))") { store.downloadAll(in: g.id) }
                        .buttonStyle(.bordered)
                }
                ForEach(packs) { p in packRow(p) }
                ForEach(scenes) { s in
                    NavigationLink(s.title) { LidarSceneView(scene: s, presets: s.isSF ? presets : []) }
                }
                if let u = g.usgs_1m {
                    Link("All \(u.tiles) USGS 1 m tiles (\(size(u.bytes))) at The National Map", destination: u.url).font(.caption)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(g.name), \(g.state)").font(.headline)
                    Text("\(have) of \(packs.count) on this phone · \(size(packs.reduce(0) { $0 + $1.total_bytes }))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

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
                Text(p.shortTitle).font(.subheadline.bold())
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
