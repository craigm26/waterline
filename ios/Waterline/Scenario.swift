import Foundation

/// A water level in ft MLLW (NOAA CO-OPS 9414290, San Francisco).
/// `provenance` follows the repo rule: official is solid, derived is outlined, assumed is hatched.
struct Scenario: Identifiable, Hashable {
    enum Provenance: String { case official, derived, assumed }
    let id: String
    let label: String
    let detail: String
    let levelFtMLLW: Double
    let provenance: Provenance
    let isStressTest: Bool

    /// NOAA flood thresholds for 9414290, ft MLLW.
    static let thresholds: [(String, Double)] = [("NWS minor", 7.04), ("NOS minor", 7.71), ("NOS moderate", 8.64), ("NOS major", 9.91)]
    /// Ferry Building plaza grade from USGS 3DEP lidar (derived), ft MLLW.
    static let plazaFt = 10.16

    static func thresholdNote(_ ft: Double) -> String {
        guard let t = thresholds.last(where: { ft >= $0.1 }) else { return "below NWS minor (7.04)" }
        return "at or above \(t.0) (\(String(format: "%.2f", t.1)))"
    }

    /// Christmas Eve king tide, 10:37 AM (NOAA prediction) and what stacks on it.
    static func christmasEve(anomalyFt: Double, anomalyIsLive: Bool) -> [Scenario] {
        let king = 7.23
        let a = anomalyIsLive ? "today's 30-day gauge anomaly" : "the October gauge anomaly"
        return [
            .init(id: "king", label: "Dec 24 king tide", detail: "NOAA prediction, 10:37 AM", levelFtMLLW: king, provenance: .official, isStressTest: false),
            .init(id: "king+a", label: "Dec 24 + anomaly", detail: String(format: "+%.2f ft, %@, if it holds", anomalyFt, a), levelFtMLLW: king + anomalyFt, provenance: .derived, isStressTest: false),
            .init(id: "storm", label: "Dec 24 + anomaly + storm", detail: "+2.0 ft surge, an assumed storm", levelFtMLLW: king + anomalyFt + 2.0, provenance: .assumed, isStressTest: false),
            .init(id: "stress", label: "Stress test", detail: "Dec 24 tide + the Feb 1998 peak storm residual (+3.07 ft)", levelFtMLLW: king + 3.07, provenance: .assumed, isStressTest: true),
        ]
    }

    /// The next high tide and the highest in 15 days, from the live forecast.
    static func live(_ f: Forecast) -> [Scenario] {
        var out: [Scenario] = []
        if let next = f.highs.first {
            out.append(.init(id: "next", label: "Next high tide", detail: "NOAA prediction, \(next.label)", levelFtMLLW: next.ft, provenance: .official, isStressTest: false))
            out.append(.init(id: "next+a", label: "Next high + anomaly", detail: String(format: "%@, +%.2f ft gauge anomaly", next.label, f.anomalyFt), levelFtMLLW: next.ft + f.anomalyFt, provenance: .derived, isStressTest: false))
        }
        if let top = f.highs.max(by: { $0.ft < $1.ft }) {
            out.append(.init(id: "top+a", label: "Highest in 15 days + anomaly", detail: top.label, levelFtMLLW: top.ft + f.anomalyFt, provenance: .derived, isStressTest: false))
        }
        return out
    }
}
