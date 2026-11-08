import Foundation
import CoreLocation
import simd

/// Water spread over the real ground around a spot, for the camera's "On the street" view.
///
/// The level comes from the scenario: the computed depth at this spot, on top of the ground here.
/// It fills only the 2 m cells of USGS 1 m ground that are lower than that level and joined to
/// this spot through other cells that are, so water doesn't jump a ridge into a basin it couldn't
/// reach. It's a flat sheet at one level, which is how standing water sits.
struct GeoWaterField: Equatable {
    let center: CLLocationCoordinate2D
    let cellM: Float
    /// Cell centres, metres east (x) and south (z) of `center`.
    let cells: [SIMD2<Float>]
    /// The water's height above the ground at `center`, m.
    let levelM: Float
    var key: String { String(format: "%.5f,%.5f,%.2f,%d", center.latitude, center.longitude, levelM, cells.count) }
    static func == (a: GeoWaterField, b: GeoWaterField) -> Bool { a.key == b.key }

    static let radiusM: Float = 100

    /// `depthFt` above the ground at the patch's centre, spread over connected lower ground.
    static func build(_ p: TerrainPatch, center: CLLocationCoordinate2D, depthFt: Double) -> GeoWaterField? {
        guard depthFt > 0.02 else { return nil }
        let step = max(1, Int((2.0 / p.spacingM).rounded()))          // about 2 m cells
        let n = p.side / step, cell = Float(p.spacingM) * Float(step)
        let half = Float(p.side) * Float(p.spacingM) / 2
        func g(_ r: Int, _ c: Int) -> Float? {
            let v = p.z[min(r * step, p.side - 1) * p.side + min(c * step, p.side - 1)]
            return v.isNaN ? nil : v
        }
        let c0 = n / 2
        guard let here = g(c0, c0) else { return nil }
        let level = here + Float(depthFt / Geo.ftPerM)
        let reach = Int(radiusM / cell)
        var seen = Set<Int>([c0 * n + c0]), queue = [c0 * n + c0], out: [SIMD2<Float>] = []
        while let i = queue.popLast() {
            let r = i / n, c = i % n
            out.append(SIMD2<Float>(Float(c) * cell + cell / 2 - half, Float(r) * cell + cell / 2 - half))
            for (dr, dc) in [(0, 1), (1, 0), (0, -1), (-1, 0)] {
                let rr = r + dr, cc = c + dc
                guard rr >= 0, cc >= 0, rr < n, cc < n, abs(rr - c0) <= reach, abs(cc - c0) <= reach else { continue }
                let j = rr * n + cc
                guard !seen.contains(j), let gj = g(rr, cc), gj < level else { continue }
                seen.insert(j); queue.append(j)
            }
            if out.count > 12_000 { break }
        }
        return GeoWaterField(center: center, cellM: cell, cells: out, levelM: level - here)
    }
}
