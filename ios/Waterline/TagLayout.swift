import CoreGraphics

/// Puts AR tags on screen without overlaps. Items come most important first, so they keep the spot
/// closest to their true bearing. A tag that can't fit nearby shrinks to a dot; a dot that can't
/// fit is left to the list. Foundation-free so it can be tested without a phone.
enum TagLayout {
    static let tagSize = CGSize(width: 224, height: 44)
    static let dotSize: CGFloat = 34
    static let gap: CGFloat = 4

    /// Grid steps around a dot's true point, nearest first. Wide enough to clear a column of tags.
    private static let dotOffsets: [(Int, Int)] = {
        var out: [(Int, Int)] = []
        for dx in -6...6 { for dy in -4...4 { out.append((dx, dy)) } }
        return out.sorted { $0.0 * $0.0 + $0.1 * $0.1 < $1.0 * $1.0 + $1.1 * $1.1 }
    }()

    struct Spot { let id: String; let anchor: CGPoint; let point: CGPoint; let compact: Bool }

    static func place(_ items: [(id: String, at: CGPoint)], in band: CGRect, maxRows: Int = 4) -> (spots: [Spot], hidden: Int) {
        guard band.width >= dotSize, band.height >= dotSize else { return ([], items.count) }
        let tagFits = band.width >= tagSize.width && band.height >= tagSize.height
        var taken: [CGRect] = []
        var spots: [Spot] = []
        var hidden = 0
        func box(_ p: CGPoint, _ s: CGSize) -> CGRect {
            CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height)
        }
        func clamp(_ p: CGPoint, _ s: CGSize) -> CGPoint {
            CGPoint(x: min(max(p.x, band.minX + s.width / 2), band.maxX - s.width / 2),
                    y: min(max(p.y, band.minY + s.height / 2), band.maxY - s.height / 2))
        }
        func free(_ r: CGRect) -> Bool { !taken.contains { $0.intersects(r) } }

        for item in items {
            var done = false
            let rowH = tagSize.height + gap
            for k in 0...(2 * maxRows) where tagFits {
                let row = k == 0 ? 0 : (k % 2 == 1 ? -(k + 1) / 2 : k / 2)       // 0, up 1, down 1, up 2, ...
                let p = clamp(CGPoint(x: item.at.x, y: item.at.y + CGFloat(row) * rowH), tagSize)
                let r = box(p, tagSize)
                if free(r) {
                    taken.append(r)
                    spots.append(Spot(id: item.id, anchor: item.at, point: p, compact: false))
                    done = true
                    break
                }
            }
            if done { continue }
            let step = dotSize + gap, size = CGSize(width: dotSize, height: dotSize)
            for (dx, dy) in dotOffsets {
                let p = clamp(CGPoint(x: item.at.x + CGFloat(dx) * step, y: item.at.y + CGFloat(dy) * step), size)
                let r = box(p, size)
                if free(r) {
                    taken.append(r)
                    spots.append(Spot(id: item.id, anchor: item.at, point: p, compact: true))
                    done = true
                    break
                }
            }
            if !done { hidden += 1 }
        }
        return (spots, hidden)
    }
}
