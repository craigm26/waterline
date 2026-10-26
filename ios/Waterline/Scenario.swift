import Foundation

/// A water level in ft MLLW (NOAA CO-OPS 9414290, San Francisco).
/// `provenance` follows the repo rule: official is solid, derived is outlined, assumed is hatched.
struct Scenario: Identifiable, Hashable {
    enum Provenance: String { case official, derived, assumed }
    let id: String
    let label: String
    let levelFtMLLW: Double
    let provenance: Provenance
    let isStressTest: Bool

    /// Ferry Building scenarios from plan/compound-risk.md. Replace with site/data/forecast.json once it exists.
    static let ferryBuilding: [Scenario] = [
        .init(id: "king", label: "King tide · Dec 24", levelFtMLLW: 7.23, provenance: .official, isStressTest: false),
        .init(id: "elnino", label: "+ El Niño baseline", levelFtMLLW: 8.2, provenance: .derived, isStressTest: false),
        .init(id: "storm", label: "+ big storm", levelFtMLLW: 9.2, provenance: .assumed, isStressTest: false),
        .init(id: "stress", label: "Stress test", levelFtMLLW: 10.3, provenance: .assumed, isStressTest: true),
    ]
}
