import Foundation
import CoreLocation

/// California's megastorms, for the rain model: 30 days of rain at the city nearest a spot.
///
/// - ARkStorm 2.0 (Huang & Swain 2022): a modelled storm sequence "capable of producing a
///   California megaflood", hourly on a 3 km grid, in today's climate and in a warmer late-century
///   one. Not a forecast, and not the 1862 storm itself; 1862 is the flood it's measured against.
/// - 1861-62 as measured: NOAA's daily rain gauge readings at San Francisco and Sacramento,
///   the wettest 30 days of the Great Flood winter. Days are spread evenly over their hours ▨.
///
/// `Resources/arkstorm.json` is built by scripts/build_arkstorm.py.
enum Megastorm {
    struct City: Decodable { let lat: Double; let lon: Double; let km: Double; let hist: [Double]; let ftr: [Double] }
    struct Gauge: Decodable { let station: String; let start: String; let daily_in: [Double] }
    struct File: Decodable { let cities: [String: City]; let `1862`: [String: Gauge]? }
    struct Storm { let name: String; let detail: String; let hours: [Double]; let prov: Provenance }

    static let page = URL(string: "https://doi.org/10.17603/ds2-mzgn-cy51")!
    static let maxKm = 40.0

    private static let file: File? = Bundle.main.url(forResource: "arkstorm", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(File.self, from: $0) }

    /// The storms that reach this spot: ARkStorm at the nearest listed city within 40 km, and the
    /// 1862 gauge readings near San Francisco or Sacramento.
    static func near(_ c: CLLocationCoordinate2D) -> [Storm] {
        guard let f = file else { return [] }
        var out: [Storm] = []
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        func km(_ lat: Double, _ lon: Double) -> Double { here.distance(from: CLLocation(latitude: lat, longitude: lon)) / 1000 }
        if let (name, city) = f.cities.min(by: { km($0.value.lat, $0.value.lon) < km($1.value.lat, $1.value.lon) }),
           km(city.lat, city.lon) <= maxKm {
            let cell = String(format: "the 3 km model cell nearest %@ (%.0f km from the city centre)", name, city.km)
            out.append(Storm(name: "ARkStorm megastorm",
                             detail: String(format: "ARkStorm 2.0 (Huang & Swain 2022): a modelled 30-day California megastorm in today's climate, %.1f in at %@. A what-if, not a forecast.", city.hist.reduce(0, +), cell),
                             hours: city.hist, prov: .official))
            out.append(Storm(name: "ARkStorm, warmer climate",
                             detail: String(format: "ARkStorm 2.0's late-century version, in a climate about 3 °C warmer: %.1f in at %@. A what-if, not a forecast.", city.ftr.reduce(0, +), cell),
                             hours: city.ftr, prov: .official))
        }
        for (name, g) in f.`1862` ?? [:] {
            let at = name == "Sacramento" ? (38.5816, -121.4944) : (37.7749, -122.4194)
            guard km(at.0, at.1) <= maxKm else { continue }
            out.append(Storm(name: "1862, as measured",
                             detail: String(format: "The wettest 30 days of the 1861-62 Great Flood winter, measured at %@ from %@: %.1f in (NOAA). The gauge read once a day, so each day is spread evenly over its hours ▨: spread that thin, working drains keep up, and real storms come in bursts, so this understates the water.", g.station.capitalized, g.start, g.daily_in.reduce(0, +)),
                             hours: g.daily_in.flatMap { Array(repeating: $0 / 24, count: 24) }, prov: .official))
        }
        return out
    }
}
