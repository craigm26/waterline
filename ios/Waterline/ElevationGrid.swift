import Foundation
import CoreLocation

/// Offline ground + bowl grids: San Francisco at 5 m in the app bundle (scripts/build_ios_data.py),
/// and downloaded region packs at 10 m (scripts/build_regions.py: Sacramento, New Orleans, Miami, ...).
/// bowl = how far the ground sits below the lowest rim that encloses it: how deep water stands here
/// before it can spill out, and how far open water must rise above this ground to reach it overland.
/// Behind a levee the rim is the levee.
final class ElevationGrid {
    struct Header: Decodable {
        struct Part: Decodable { let bytes: Int }
        let rows: Int, cols: Int, x0: Double, y0: Double, res_m: Double, nodata_ground: Int
        let ground: Part, bowl: Part
        let zone: Int?, region: String?, name: String?
    }
    struct Sample {
        let groundNAVD88Ft: Double
        let bowlFt: Double
    }
    /// A grid cell found by a search: valueFt is bowl depth (deepestBowl) or ground ft NAVD88 (higherGround).
    struct GridSpot {
        let valueFt: Double
        let coordinate: CLLocationCoordinate2D
        let metres: Double
    }

    /// San Francisco, bundled.
    static let sf: ElevationGrid? = Bundle.main.url(forResource: "sfgrid", withExtension: "bin").flatMap { ElevationGrid(url: $0) }

    private static var regionCache: [String: ElevationGrid] = [:]
    private static let lock = NSLock()

    /// The grid that has data at this spot: SF first, then any downloaded region pack.
    static func covering(_ c: CLLocationCoordinate2D) -> ElevationGrid? {
        if let g = sf, g.sample(c) != nil { return g }
        let dir = PackStore.root
        guard let packs = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for id in packs where id.hasPrefix("region-") && PackStore.installedVersion(id) != nil {
            let name = String(id.dropFirst("region-".count)) + "_grid.bin"
            lock.lock()
            var g = regionCache[id]
            if g == nil, let u = PackStore.file(id, name) { g = ElevationGrid(url: u); regionCache[id] = g }
            lock.unlock()
            if let g, g.sample(c) != nil { return g }
        }
        return nil
    }
    static func reloadRegions() { lock.lock(); regionCache = [:]; lock.unlock() }

    var name: String { h.name ?? "San Francisco" }
    var resolutionM: Double { h.res_m }

    private let h: Header
    private let ground: [Int16]
    private let bowl: [UInt16]

    init?(url: URL) {
        guard let raw = try? Data(contentsOf: url, options: .mappedIfSafe),
              let nl = raw.firstIndex(of: 0x0A),
              let header = try? JSONDecoder().decode(Header.self, from: raw[raw.startIndex..<nl]) else { return nil }
        h = header
        let gStart = nl + 1, bStart = gStart + header.ground.bytes
        guard let g = ElevationGrid.inflate(raw[gStart..<bStart]), let b = ElevationGrid.inflate(raw[bStart..<(bStart + header.bowl.bytes)]) else { return nil }
        let n = header.rows * header.cols
        guard g.count == n * 2, b.count == n * 2 else { return nil }
        ground = g.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
        bowl = b.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }.map { UInt16(littleEndian: $0) }
    }

    /// Raw DEFLATE, which Foundation calls `.zlib`.
    private static func inflate(_ d: Data) -> Data? {
        try? (Data(d) as NSData).decompressed(using: .zlib) as Data
    }

    private func cell(_ c: CLLocationCoordinate2D) -> (r: Int, c: Int)? {
        let p = Geo.utm(lon: c.longitude, lat: c.latitude, zone: h.zone ?? 10)
        let col = Int(((p.x - h.x0) / h.res_m).rounded(.down)), row = Int(((h.y0 - p.y) / h.res_m).rounded(.down))
        guard row >= 0, row < h.rows, col >= 0, col < h.cols else { return nil }
        return (row, col)
    }

    /// nil outside the grid or over open water.
    func sample(_ c: CLLocationCoordinate2D) -> Sample? {
        guard let rc = cell(c) else { return nil }
        let i = rc.r * h.cols + rc.c
        guard Int(ground[i]) != h.nodata_ground else { return nil }
        return Sample(groundNAVD88Ft: Geo.feet(Double(ground[i]) / 100), bowlFt: Geo.feet(Double(bowl[i]) / 100))
    }

    /// Nearest cell whose ground is at or above `navd88Ft` and that isn't in a bowl: dry ground for
    /// that water level. Searched in growing rings out to `maxM`, so the first hit is the closest.
    func higherGround(near c: CLLocationCoordinate2D, aboveNAVD88Ft navd88Ft: Double, maxM: Double = 1500) -> GridSpot? {
        guard let rc = cell(c) else { return nil }
        let needCm = Int16(clamping: Int((navd88Ft / Geo.ftPerM * 100).rounded(.up)))
        let kMax = Int(maxM / h.res_m)
        for k in 1...max(1, kMax) {
            var best: (d2: Int, r: Int, c: Int)?
            func consider(_ r: Int, _ cc: Int) {
                guard r >= 0, r < h.rows, cc >= 0, cc < h.cols else { return }
                let i = r * h.cols + cc
                guard Int(ground[i]) != h.nodata_ground, ground[i] >= needCm, bowl[i] < 5 else { return }
                let dr = r - rc.r, dc = cc - rc.c, d2 = dr * dr + dc * dc
                if best == nil || d2 < best!.d2 { best = (d2, r, cc) }
            }
            for dc in -k...k { consider(rc.r - k, rc.c + dc); consider(rc.r + k, rc.c + dc) }   // top and bottom edges
            for dr in (-k + 1)..<k { consider(rc.r + dr, rc.c - k); consider(rc.r + dr, rc.c + k) }   // left and right
            if let b = best {
                let dy = Double(rc.r - b.r) * h.res_m, dx = Double(b.c - rc.c) * h.res_m
                let to = CLLocationCoordinate2D(latitude: c.latitude + dy / 111_132,
                                                longitude: c.longitude + dx / (111_320 * cos(c.latitude * .pi / 180)))
                return GridSpot(valueFt: Geo.feet(Double(ground[b.r * h.cols + b.c]) / 100), coordinate: to, metres: Geo.distance(c, to))
            }
        }
        return nil
    }

    /// Block-scale low spots around a point from the bowl grid, deepest first: the phone-only
    /// version of the list in a layers pack. Levee basins are skipped (the bowl row covers them).
    func lowSpots(near c: CLLocationCoordinate2D, radiusM: Double, limit: Int) -> [Places.LowSpot] {
        guard let rc = cell(c) else { return [] }
        let k = Int(radiusM / h.res_m)
        let r0 = max(0, rc.r - k), r1 = min(h.rows - 1, rc.r + k), c0 = max(0, rc.c - k), c1 = min(h.cols - 1, rc.c + k)
        let w = c1 - c0 + 1, ht = r1 - r0 + 1
        var seen = [Bool](repeating: false, count: w * ht)
        var out: [(depth: UInt16, cells: Int, r: Int, c: Int)] = []
        let maxCells = Int(200_000 / (h.res_m * h.res_m)), minCells = Int(1_500 / (h.res_m * h.res_m))
        for r in r0...r1 {
            for cc in c0...c1 where !seen[(r - r0) * w + cc - c0] && bowl[r * h.cols + cc] >= 46 {
                var stack = [(r, cc)], n = 0, top: (d: UInt16, r: Int, c: Int) = (0, r, cc)
                seen[(r - r0) * w + cc - c0] = true
                while let (a, b) = stack.popLast() {
                    n += 1
                    let v = bowl[a * h.cols + b]
                    if v > top.d { top = (v, a, b) }
                    for (x, y) in [(a - 1, b), (a + 1, b), (a, b - 1), (a, b + 1)] where x >= r0 && x <= r1 && y >= c0 && y <= c1 {
                        let i = (x - r0) * w + y - c0
                        if !seen[i], bowl[x * h.cols + y] >= 46 { seen[i] = true; stack.append((x, y)) }
                    }
                }
                if n >= minCells, n <= maxCells { out.append((top.d, n, top.r, top.c)) }
            }
        }
        out.sort { $0.depth > $1.depth }
        return out.prefix(limit).enumerated().map { i, s in
            let dy = Double(rc.r - s.r) * h.res_m, dx = Double(s.c - rc.c) * h.res_m
            return Places.LowSpot(rank: i + 1, name: "Low spot", lon: c.longitude + dx / (111_320 * cos(c.latitude * .pi / 180)),
                                  lat: c.latitude + dy / 111_132, max_depth_m: Double(s.depth) / 100,
                                  area_m2: Int(Double(s.cells) * h.res_m * h.res_m), flood311: 0, in_zone: false)
        }
    }

    /// Deepest bowl within `radius` metres (at least 0.5 ft deep), so "you're 60 ft from a 3 ft bowl"
    /// is visible even when GPS puts you on its rim.
    func deepestBowl(near c: CLLocationCoordinate2D, radius: Double = 60) -> GridSpot? {
        guard let rc = cell(c) else { return nil }
        let k = Int(radius / h.res_m)
        var best: (v: UInt16, r: Int, c: Int)?
        for r in max(0, rc.r - k)...min(h.rows - 1, rc.r + k) {
            for cc in max(0, rc.c - k)...min(h.cols - 1, rc.c + k) {
                let dr = r - rc.r, dc = cc - rc.c
                guard dr * dr + dc * dc <= k * k else { continue }
                let i = r * h.cols + cc
                if Int(ground[i]) != h.nodata_ground, bowl[i] > (best?.v ?? 15) { best = (bowl[i], r, cc) }
            }
        }
        guard let b = best else { return nil }
        // back to lon/lat by offsetting the query point; the grid is ~north-up so this is good to ~1 m
        let dy = Double(rc.r - b.r) * h.res_m, dx = Double(b.c - rc.c) * h.res_m
        let lat = c.latitude + dy / 111_132
        let lon = c.longitude + dx / (111_320 * cos(c.latitude * .pi / 180))
        let to = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        return GridSpot(valueFt: Geo.feet(Double(b.v) / 100), coordinate: to, metres: Geo.distance(c, to))
    }
}
