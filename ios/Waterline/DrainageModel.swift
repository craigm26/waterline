import Foundation

/// Where rain goes on the ground, and how deep it stands. A screening estimate, not a drainage
/// model: it knows the surface from lidar and nothing about pipe sizes.
///
/// Every cell's water runs downhill to a depression (the grid's `bowl` layer) or off the window.
/// Rain that the drains can't take fills each depression level, lowest ground first; anything over
/// the rim spills to the next depression downhill. All water here comes from computed volumes.
struct DrainageModel {
    struct Pond { let id: Int; let row: Int; let col: Int; let maxDepthM: Double; let cells: Int; let catchmentCells: Int; let volumeM3: Double }
    struct Result {
        let depthM: [Float]
        let ponds: [Pond]
        let inflowM3: Double, storedM3: Double, lostM3: Double
    }

    let rows: Int, cols: Int, resM: Double
    let ground: [Float]         // m, NaN where there's no data
    private let filled: [Float]
    private let pond: [Int32]   // pond index, -1 outside one
    private let rcv: [Int32]    // the next cell downhill, -1 at a dead end
    private let order: [Int32]  // highest first
    private var members: [[Int32]] = []
    private var level: [Float] = []
    private var capacity: [Double] = []   // m3
    private var catchment: [Int] = []
    private var spillTo: [Int32] = []
    let accumulation: [Int32]   // cells draining through each cell

    private static let anyBowlM: Float = 0.01
    /// Pits shallower or smaller than this are noise in the surface (curbs, parked cars smoothed into
    /// the DEM). Water runs on through them, or they'd swallow what belongs to the real basins.
    private static let minPondDepthM: Float = 0.15
    private static let minPondCells = 4

    init(rows: Int, cols: Int, resM: Double, ground: [Float], bowl: [Float]) {
        self.rows = rows; self.cols = cols; self.resM = resM; self.ground = ground
        let n = rows * cols
        var f = [Float](repeating: .nan, count: n)
        for i in 0..<n where !ground[i].isNaN { f[i] = ground[i] + bowl[i] }

        // Depressions: touching cells that share one water level.
        var label = [Int32](repeating: -1, count: n)
        var lists: [[Int32]] = []
        var stack: [Int32] = []
        for s in 0..<n where label[s] < 0 && !ground[s].isNaN && bowl[s] >= Self.anyBowlM {
            let id = Int32(lists.count)
            var cells: [Int32] = []
            label[s] = id; stack = [Int32(s)]
            while let c = stack.popLast() {
                cells.append(c)
                Self.neighbors(Int(c), rows, cols) { j in
                    if label[j] < 0, !ground[j].isNaN, bowl[j] >= Self.anyBowlM, abs(f[j] - f[Int(c)]) < 0.004 { label[j] = id; stack.append(Int32(j)) }
                }
            }
            lists.append(cells)
        }

        // Steepest descent. A depression's cells have no receiver: their water stays in it.
        var r = [Int32](repeating: -1, count: n)
        for i in 0..<n where !ground[i].isNaN && label[i] < 0 {
            var best = Float(0), to: Int32 = -1
            let ci = i % cols, ri = i / cols
            Self.neighbors(i, rows, cols) { j in
                guard !f[j].isNaN else { return }
                let dist: Float = (j % cols != ci && j / cols != ri) ? 1.414 : 1
                let s = (f[i] - f[j]) / dist
                if s > best { best = s; to = Int32(j) }
            }
            r[i] = to
        }

        // Dissolve the noise pits: their cells drain to the pit's outlet.
        var keep = [Int32](repeating: -1, count: lists.count)
        var kept: [[Int32]] = []
        for (id, cells) in lists.enumerated() {
            let deep = cells.contains { bowl[Int($0)] >= Self.minPondDepthM }
            if deep, cells.count >= Self.minPondCells {
                keep[id] = Int32(kept.count); kept.append(cells); continue
            }
            var low = Float.infinity, out: Int32 = -1
            for c in cells {
                Self.neighbors(Int(c), rows, cols) { j in
                    if label[j] != Int32(id), !f[j].isNaN, f[j] < low { low = f[j]; out = Int32(j) }
                }
            }
            for c in cells { r[Int(c)] = out }
        }
        for i in 0..<n where label[i] >= 0 { label[i] = keep[Int(label[i])] }
        lists = kept

        // Flats have no downhill neighbor: hand them on to a neighbor that already leads somewhere.
        var flats = (0..<n).filter { !f[$0].isNaN && label[$0] < 0 && r[$0] < 0 }
        var moved = true
        while moved, !flats.isEmpty {
            moved = false
            flats = flats.filter { i in
                var to: Int32 = -1
                Self.neighbors(i, rows, cols) { j in
                    if to < 0, !f[j].isNaN, abs(f[j] - f[i]) < 0.004, label[j] >= 0 || r[j] >= 0, r[j] != Int32(i) { to = Int32(j) }
                }
                if to >= 0 { r[i] = to; moved = true; return false }
                return true
            }
        }

        // The channel network, walked from its heads so noise pits and flats pass water along.
        var feeders = [Int32](repeating: 0, count: n)
        for i in 0..<n where r[i] >= 0 && label[i] < 0 { feeders[Int(r[i])] += 1 }

        let idx = (0..<n).filter { !f[$0].isNaN }.sorted { f[$0] > f[$1] }.map { Int32($0) }
        var acc = [Int32](repeating: 1, count: n)
        var inflow = [Int](repeating: 0, count: lists.count)
        var ready = (0..<n).filter { !f[$0].isNaN && feeders[$0] == 0 }
        while let i = ready.popLast() {
            if label[i] >= 0 { inflow[Int(label[i])] += Int(acc[i]); continue }
            let to = Int(r[i])
            guard to >= 0 else { continue }
            acc[to] += acc[i]
            feeders[to] -= 1
            if feeders[to] == 0 { ready.append(to) }
        }

        filled = f; pond = label; rcv = r; order = idx; accumulation = acc
        members = lists; catchment = inflow
        let cellArea = resM * resM
        level = lists.map { f[Int($0[0])] }
        capacity = lists.map { cells in cells.reduce(0.0) { $0 + Double(bowl[Int($1)]) } * cellArea }

        // Where each depression overflows: its lowest outside neighbor, followed downhill.
        var spill = [Int32](repeating: -1, count: lists.count)
        for (id, cells) in lists.enumerated() {
            var low = Float.infinity, out = -1
            for c in cells {
                Self.neighbors(Int(c), rows, cols) { j in
                    if label[j] != Int32(id), !f[j].isNaN, f[j] < low { low = f[j]; out = j }
                }
            }
            var at = out, steps = 0
            while at >= 0, label[at] < 0, steps < n { at = Int(r[at]); steps += 1 }
            if at >= 0, label[at] >= 0, f[at] < level[id] - 0.004 { spill[id] = label[at] }
        }
        spillTo = spill
    }

    private static func neighbors(_ i: Int, _ rows: Int, _ cols: Int, _ body: (Int) -> Void) {
        let r = i / cols, c = i % cols
        for dr in -1...1 { for dc in -1...1 where dr != 0 || dc != 0 {
            let a = r + dr, b = c + dc
            if a >= 0, a < rows, b >= 0, b < cols { body(a * cols + b) }
        } }
    }

    /// Water standing after `runoffM` of rain the drains couldn't take has run off every cell.
    func run(runoffM: Double) -> Result {
        let cellArea = resM * resM
        var depth = [Float](repeating: 0, count: rows * cols)
        guard runoffM > 0, !members.isEmpty else {
            return Result(depthM: depth, ponds: [], inflowM3: 0, storedM3: 0, lostM3: 0)
        }
        var volume = catchment.map { Double($0) * cellArea * runoffM }
        let rain = volume.reduce(0, +)
        var stored = 0.0, lost = 0.0
        var ponds: [Pond] = []
        // Upstream first, so a pond gets everything spilled into it before it's filled.
        var feeders = [Int](repeating: 0, count: members.count)
        for t in spillTo where t >= 0 { feeders[Int(t)] += 1 }
        var ready = members.indices.filter { feeders[$0] == 0 }
        while let id = ready.popLast() {
            defer {
                if spillTo[id] >= 0 {
                    let t = Int(spillTo[id])
                    feeders[t] -= 1
                    if feeders[t] == 0 { ready.append(t) }
                }
            }
            var v = volume[id]
            if v > capacity[id] {
                let over = v - capacity[id]
                if spillTo[id] >= 0 { volume[Int(spillTo[id])] += over } else { lost += over }
                v = capacity[id]
            }
            guard v > 0 else { continue }
            stored += v
            let cells = members[id].sorted { ground[Int($0)] < ground[Int($1)] }
            // Raise a level over the lowest k cells until it holds this volume.
            var sum = 0.0, h = Double(ground[Int(cells[0])])
            for k in cells.indices {
                let g = Double(ground[Int(cells[k])])
                if Double(k) * g - sum >= v / cellArea { break }
                sum += g
                h = (v / cellArea + sum) / Double(k + 1)
            }
            var wet = 0, top = 0.0, at = Int(cells[0])
            for c in cells {
                let d = h - Double(ground[Int(c)])
                guard d > 0 else { break }
                depth[Int(c)] = Float(d); wet += 1
                if d > top { top = d; at = Int(c) }
            }
            ponds.append(Pond(id: id, row: at / cols, col: at % cols, maxDepthM: top, cells: wet, catchmentCells: catchment[id], volumeM3: v))
        }
        return Result(depthM: depth, ponds: ponds.sorted { $0.volumeM3 > $1.volumeM3 }, inflowM3: rain, storedM3: stored, lostM3: lost)
    }

    /// Main flow paths as cell runs, from where a channel starts to where it ends.
    func flowPaths(minCells: Int32, limit: Int) -> [[Int]] {
        var hasFeeder = [Bool](repeating: false, count: rows * cols)
        for c in order where accumulation[Int(c)] >= minCells {
            if rcv[Int(c)] >= 0 { hasFeeder[Int(rcv[Int(c)])] = true }
        }
        var seen = [Bool](repeating: false, count: rows * cols)
        var out: [(Int32, [Int])] = []
        for c in order where accumulation[Int(c)] >= minCells && !hasFeeder[Int(c)] && pond[Int(c)] < 0 {
            var path: [Int] = [], at = Int(c)
            while at >= 0 {
                path.append(at)
                if seen[at] || pond[at] >= 0 { break }
                seen[at] = true
                at = Int(rcv[at])
            }
            if path.count > 2 { out.append((accumulation[path[path.count - 1]], path)) }
        }
        return out.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }
}
