import SwiftUI

/// Native SwiftUI Under-Street vs. Over-Street vertical cross-section card:
/// fuses USGS bare-earth LiDAR elevation, street bowl depth, NOAA tide-lock
/// outfall head (< 3 ft blocks gravity drainage), and the nearest live gauge.
struct VerticalSliceCard: View {
    let report: SpotReport
    let nearestCamera: CaltransCamera?
    var onTapCamera: ((CaltransCamera) -> Void)? = nil

    private var groundFt: Double? {
        report.groundMLLW ?? report.ground?.navd88Ft
    }

    private var peakTideFt: Double? {
        guard let t = report.tide, let h = t.highest else { return nil }
        return h.ft + (t.anomalyFt ?? 0)
    }

    private var tideHeadFt: Double? {
        guard let g = report.groundMLLW, let p = peakTideFt else { return nil }
        return g - p
    }

    private var tideLocked: Bool {
        if let h = tideHeadFt { return h < 3.0 }
        return false
    }

    private var isDeepPit: Bool {
        report.bowlFt > 6.5
    }

    private var statusLabel: String {
        if tideLocked { return "TIDE-LOCKED UNDER-STREET" }
        if isDeepPit { return "UNDER-STREET PIT / UNDERPASS" }
        if report.bowlFt >= 1.5 { return "OVER-STREET BOWL" }
        return "GRAVITY DRAINING"
    }

    private var statusColor: Color {
        if tideLocked || isDeepPit { return .red }
        if report.bowlFt >= 1.5 { return .orange }
        return .teal
    }

    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Under-Street & Over-Street Slice")
                        .font(.headline)
                    Text("LiDAR ground · outfall tide-lock · live gauge")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusLabel)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(statusColor)
            }

            CrossSectionCanvas(
                groundFt: groundFt,
                bowlFt: report.bowlFt,
                peakTideFt: peakTideFt,
                tideHeadFt: tideHeadFt,
                tideLocked: tideLocked
            )
            .frame(height: 185)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4)))

            HStack(spacing: 10) {
                metricPill(
                    title: "LiDAR Ground",
                    value: groundFt.map { String(format: "%.1f ft", $0) } ?? "—",
                    tint: .blue
                )
                metricPill(
                    title: "Outfall Head",
                    value: tideHeadFt.map { String(format: "%+.1f ft", $0) } ?? "—",
                    tint: tideLocked ? .red : .teal
                )
                metricPill(
                    title: "LiDAR Bowl",
                    value: String(format: "%.1f ft", report.bowlFt),
                    tint: report.bowlFt >= 1.5 ? .orange : .secondary
                )
            }

            if let cam = nearestCamera {
                Button {
                    onTapCamera?(cam)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "video.fill")
                            .foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Verify visually: \(cam.name)")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text("\(cam.source.rawValue) · \(String(format: "%.1f mi", cam.distanceMeters(from: report.coordinate) / 1609.34)) · Face blur on")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func metricPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold().monospacedDigit()).foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CrossSectionCanvas: View {
    let groundFt: Double?
    let bowlFt: Double
    let peakTideFt: Double?
    let tideHeadFt: Double?
    let tideLocked: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let streetY = h * 0.54

            // Sky (over-street) & soil (under-street)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: streetY)), with: .color(Color(red: 0.05, green: 0.11, blue: 0.18)))
            ctx.fill(Path(CGRect(x: 0, y: streetY, width: w, height: h - streetY)), with: .color(Color(red: 0.08, green: 0.11, blue: 0.15)))

            // Building + curb on left
            ctx.fill(Path(CGRect(x: 10, y: streetY - 62, width: 52, height: 62)), with: .color(Color(red: 0.12, green: 0.20, blue: 0.30)))
            ctx.fill(Path(CGRect(x: 62, y: streetY - 8, width: 24, height: 8)), with: .color(Color(red: 0.20, green: 0.29, blue: 0.40)))

            // 5'9" human scale marker
            let px: CGFloat = 74
            ctx.fill(Path(ellipseIn: CGRect(x: px - 4, y: streetY - 40, width: 8, height: 8)), with: .color(.white.opacity(0.85)))
            var bodyPath = Path()
            bodyPath.move(to: CGPoint(x: px, y: streetY - 32))
            bodyPath.addLine(to: CGPoint(x: px, y: streetY - 16))
            bodyPath.move(to: CGPoint(x: px, y: streetY - 16))
            bodyPath.addLine(to: CGPoint(x: px - 4, y: streetY - 8))
            bodyPath.move(to: CGPoint(x: px, y: streetY - 16))
            bodyPath.addLine(to: CGPoint(x: px + 4, y: streetY - 8))
            ctx.stroke(bodyPath, with: .color(.white.opacity(0.85)), lineWidth: 2)

            // Over-street LiDAR bowl ponding
            if bowlFt >= 0.3 {
                let pondH = min(streetY - 22, max(12, CGFloat(bowlFt) * 9))
                let pondRect = CGRect(x: 86, y: streetY - pondH, width: w * 0.48, height: pondH)
                ctx.fill(Path(pondRect), with: .color(.blue.opacity(0.38)))
                ctx.stroke(Path(pondRect), with: .color(.cyan.opacity(0.8)), lineWidth: 1.2)
            }

            // Street surface line
            var streetLine = Path()
            streetLine.move(to: CGPoint(x: 0, y: streetY))
            streetLine.addLine(to: CGPoint(x: w, y: streetY))
            ctx.stroke(streetLine, with: .color(.white.opacity(0.85)), lineWidth: 2)

            // Storm drain grate + catch basin + under-street outfall pipe
            let pipeColor: Color = tideLocked ? .red : .teal
            let grateX = w * 0.44
            ctx.fill(Path(CGRect(x: grateX - 12, y: streetY - 2, width: 24, height: 4)), with: .color(.yellow))
            let basin = CGRect(x: grateX - 7, y: streetY + 2, width: 14, height: 36)
            ctx.fill(Path(basin), with: .color(Color(red: 0.11, green: 0.16, blue: 0.24)))
            ctx.stroke(Path(basin), with: .color(pipeColor), lineWidth: 1.8)

            let outfallX = w * 0.74
            let pipe = CGRect(x: grateX + 7, y: streetY + 24, width: outfallX - (grateX + 7), height: 14)
            ctx.fill(Path(pipe), with: .color(Color(red: 0.11, green: 0.16, blue: 0.24)))
            ctx.stroke(Path(pipe), with: .color(pipeColor), lineWidth: 1.8)

            // Outfall tide water on right
            let tideY: CGFloat = {
                guard let head = tideHeadFt else { return h * 0.80 }
                return max(streetY - 6, min(h - 14, streetY + 12 + CGFloat(head) * 5))
            }()
            let tideRect = CGRect(x: outfallX, y: tideY, width: w - outfallX, height: h - tideY)
            ctx.fill(Path(tideRect), with: .color(pipeColor.opacity(0.32)))
            var tideTop = Path()
            tideTop.move(to: CGPoint(x: outfallX, y: tideY))
            tideTop.addLine(to: CGPoint(x: w, y: tideY))
            ctx.stroke(tideTop, with: .color(pipeColor), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))

            // Crisp annotations
            ctx.draw(Text("OVER-STREET").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.cyan), at: CGPoint(x: 46, y: 12))
            ctx.draw(Text("UNDER-STREET").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.gray), at: CGPoint(x: 49, y: streetY + 14))
            if let g = groundFt {
                ctx.draw(Text(String(format: "Street %.1f ft", g)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.white), at: CGPoint(x: w - 54, y: streetY - 10))
            }
            if let pt = peakTideFt {
                ctx.draw(Text(String(format: "Tide %.1f ft", pt)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(pipeColor), at: CGPoint(x: outfallX + (w - outfallX) / 2, y: max(streetY + 14, tideY - 8)))
            }
        }
    }
}
