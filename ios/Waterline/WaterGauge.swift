import SwiftUI
import Charts

/// The water at this spot over time, like a river gauge for the street: rain by the hour on top,
/// the depth it leaves here below, from 6 hours ago to 3 days out, beside a person for scale.
struct WaterGauge: View {
    /// The forecast first, then any what-if storms.
    let timelines: [WaterTimeline]
    var station: String?
    /// Open the camera on this timeline's scenario; nil when there's no camera view.
    var onWatch: ((String) -> Void)?
    @State private var pick = 0

    private var timeline: WaterTimeline { timelines[min(pick, timelines.count - 1)] }
    private var megaIndex: Int { timelines.filter { $0.points.count > 200 }.firstIndex(of: timeline) ?? 0 }
    private var long: Bool { timeline.points.count > 200 }
    private var scenarioID: String {
        switch timeline.whatIf {
        case nil: return "forecast"
        case "100-year day": return "rain-day100"
        case "100-year day on the king tide": return "rain-day100-king"
        case "1000-year day": return "rain-day1000"
        default: return "mega-\(max(0, megaIndex))"
        }
    }

    private var now: WaterTimeline.Point? { timeline.current }
    private var peak: WaterTimeline.Point? { timeline.peak }
    private var topFt: Double { max(0.5, (timeline.points.map(\.ft).max() ?? 0) * 1.2) }
    private var topIn: Double { max(0.1, timeline.points.map(\.rainIn).max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if timelines.count > 1 {
                if timelines.count <= 4 {
                    Picker("Rain", selection: $pick) {
                        ForEach(timelines.indices, id: \.self) { i in Text(Self.short(timelines[i].whatIf)).tag(i) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Picker("Rain", selection: $pick) {
                        ForEach(timelines.indices, id: \.self) { i in Text(timelines[i].whatIf ?? "Forecast, next 3 days").tag(i) }
                    }
                    .pickerStyle(.menu)
                }
            }
            if let w = timeline.whatIf {
                Text("WHAT-IF · \(w.uppercased()) · NOT A FORECAST").font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.red.opacity(0.85), in: Capsule()).foregroundStyle(.white)
            }
            HStack(alignment: .top, spacing: 16) {
                if timeline.whatIf == nil { stat(depth(now?.ft ?? 0), "here now") }
                if let p = peak {
                    stat(depth(p.ft), "deepest, " + timeline.when(p))
                } else {
                    stat("Dry", timeline.whatIf == nil ? "for the next 3 days" : "all storm")
                }
                stat(String(format: "%.1f in", timeline.measuredIn + timeline.forecastIn), timeline.whatIf == nil ? "of rain" : long ? "in 30 days" : "in 24 h")
            }
            HStack(alignment: .bottom, spacing: 10) {
                PersonGauge(ft: peak?.ft ?? now?.ft ?? 0)
                    .frame(width: 72, height: 150)
                VStack(spacing: 2) {
                    rainChart.frame(height: 44)
                    waterChart.frame(height: 104)
                }
            }
            if let onWatch {
                Button { onWatch(scenarioID) } label: {
                    Label(Self.watchLabel, systemImage: "camera.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Color(red: 0.42, green: 0.37, blue: 0.27))
            }
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    #if os(visionOS)
    static let watchLabel = "See the water in your room"
    #else
    static let watchLabel = "Watch the water rise in the camera"
    #endif

    static func short(_ w: String?) -> String {
        switch w {
        case nil: return "Forecast"
        case "100-year day": return "100-yr"
        case "100-year day on the king tide": return "+ king tide"
        case "1000-year day": return "1000-yr"
        default: return w ?? ""
        }
    }

    private func depth(_ ft: Double) -> String { ft < 0.05 ? "Dry" : String(format: "%.1f ft", ft) }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var rainChart: some View {
        Chart(timeline.points) { p in
            BarMark(x: .value("Hour", p.date, unit: .hour), y: .value("Rain", p.rainIn))
                .foregroundStyle(p.measured ? Color.indigo : Color.indigo.opacity(0.45))
        }
        .chartYScale(domain: 0...topIn)
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading, values: [topIn]) { v in AxisValueLabel { Text(String(format: "%.2f in", v.as(Double.self) ?? 0)).font(.system(size: 9)) } } }
        .accessibilityLabel(String(format: "Rain: %.2f inches measured in the last 6 hours, %.2f forecast", timeline.measuredIn, timeline.forecastIn))
    }

    private var waterChart: some View {
        Chart {
            ForEach(timeline.points.filter(\.tideLocked)) { p in
                RectangleMark(xStart: .value("From", p.date), xEnd: .value("To", p.date.addingTimeInterval(3600)), yStart: .value("Bottom", 0), yEnd: .value("Top", topFt))
                    .foregroundStyle(Color.gray.opacity(0.18))
            }
            ForEach(timeline.points) { p in
                AreaMark(x: .value("Hour", p.date), y: .value("Water", p.ft))
                    .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.7), .blue.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Hour", p.date), y: .value("Water", p.ft))
                    .foregroundStyle(.blue).interpolationMethod(.monotone)
            }
            if timeline.whatIf == nil {
                RuleMark(x: .value("Now", timeline.now))
                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) { Text("now").font(.system(size: 9)).foregroundStyle(.secondary) }
            }
        }
        .chartYScale(domain: 0...topFt)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
            AxisGridLine()
            AxisValueLabel { Text(String(format: "%.1f ft", v.as(Double.self) ?? 0)).font(.system(size: 9)) }
        } }
        .chartXAxis {
            if timeline.whatIf == nil {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: false).font(.system(size: 9))
                }
            } else if long {
                AxisMarks(values: .stride(by: .day, count: 5)) { v in
                    AxisGridLine()
                    AxisValueLabel { Text("day \(Int(((v.as(Date.self) ?? timeline.now).timeIntervalSince(timeline.now) / 86400).rounded()) + 1)").font(.system(size: 9)) }
                }
            } else {
                AxisMarks(values: .stride(by: .hour, count: 12)) { v in
                    AxisGridLine()
                    AxisValueLabel { Text("\(Int(((v.as(Date.self) ?? timeline.now).timeIntervalSince(timeline.now) / 3600).rounded())) h").font(.system(size: 9)) }
                }
            }
        }
        .accessibilityLabel(peak.map { String(format: "Water here peaks at %.1f feet", $0.ft) } ?? "No standing water here in the next 3 days")
    }

    private var lockNote: String {
        timeline.lockedHours == 0 ? "" : String(format: " Grey hours: the tide stands within %.0f ft of this ground, so drains here are assumed ▨ not to empty.", TideLock.pipeFt)
    }

    private var caption: String {
        if let d = timeline.detail {
            return d + " Water ○: Waterline's estimate on the lidar ground here. Assumed ▨: 80% of rain runs off and working drains take 0.5 in an hour, also after the rain eases."
        }
        if let w = timeline.whatIf {
            return "Rain ●: NOAA Atlas 14's \(w) storm for this spot, hour by hour, starting now\(w.contains("king") ? ", its heaviest hour on this year's king tide" : ""), then a dry day. Water ○: Waterline's estimate on the lidar ground here. Assumed ▨: 80% of rain runs off and working drains take 0.5 in an hour, also after the rain eases.\(lockNote)"
        }
        let measured = station.map { "the last 6 hours as measured at \($0) (dark bars)" } ?? "no NWS station nearby reported the last 6 hours, so they show as dry"
        return "Rain ●: \(measured), then the NWS forecast. Water ○: Waterline's estimate on the lidar ground here. Assumed ▨: 80% of rain runs off and working drains take 0.5 in an hour, also after the rain eases.\(lockNote)"
    }
}

/// A person 5 ft 9 in tall beside a 6 ft scale, with the water filled in to the depth, so a
/// number like 1.5 ft reads as "over the knees".
struct PersonGauge: View {
    let ft: Double
    private let scaleFt = 6.0
    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .bottom) {
                Image(systemName: "figure.stand")
                    .resizable().scaledToFit()
                    .frame(height: h * 5.75 / scaleFt)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color(red: 0.42, green: 0.37, blue: 0.27).opacity(0.6))
                    .frame(height: h * min(ft, scaleFt) / scaleFt)
                ForEach(1..<Int(scaleFt) + 1, id: \.self) { f in
                    Rectangle().fill(.secondary.opacity(0.5)).frame(width: 6, height: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(y: -h * Double(f) / scaleFt)
                }
            }
            .frame(width: g.size.width, height: h, alignment: .bottom)
        }
        .accessibilityLabel(String(format: "%.1f feet of water beside a 5 foot 9 person", ft))
    }
}

/// The coastal layers as a staircase: each bar is the water level once that layer is added, in ft
/// above MLLW at the tide station, against the level that reaches this spot.
struct CoastStackChart: View {
    let stages: [WaterScenario.Stage]
    let reachFt: Double

    private func short(_ s: WaterScenario.Stage) -> String {
        if s.label.hasPrefix("King") || s.label.hasPrefix("Highest") { return "Tide" }
        if s.label.contains("running high") { return "+ sea high" }
        if s.label.contains("storm") { return "+ storm" }
        if let y = ["2050", "2100"].first(where: { s.label.contains($0) }) { return y }
        return s.label
    }

    var body: some View {
        let top = max(reachFt, stages.map(\.levelFt).max() ?? 0) + 1
        Chart {
            ForEach(stages, id: \.self) { s in
                BarMark(x: .value("Layer", short(s)), y: .value("Level", s.levelFt))
                    .foregroundStyle(s.depthFt != nil ? Color.orange : Color(red: 0.25, green: 0.5, blue: 0.85))
                    .annotation(position: .top) { Text(String(format: "%.1f", s.levelFt)).font(.system(size: 9).monospacedDigit()) }
            }
            RuleMark(y: .value("Reaches here", reachFt))
                .foregroundStyle(.red).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) { Text(String(format: "reaches your spot at %.1f ft", reachFt)).font(.system(size: 9)).foregroundStyle(.red) }
        }
        .chartYScale(domain: 0...top)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
            AxisGridLine(); AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0)) ft").font(.system(size: 9)) }
        } }
        .frame(height: 150)
        .accessibilityLabel("Tide, sea anomaly, storm and sea level rise stacked, against the level that reaches this spot")
    }
}
