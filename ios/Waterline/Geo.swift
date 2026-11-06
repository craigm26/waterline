import Foundation
import CoreLocation

/// Small, dependency-free geometry: UTM forward projection (for the lidar grid), great-circle
/// distance and bearing, and point-in-polygon. Checked against pyproj in scripts/check_geo.py.
enum Geo {
    static let ftPerM = 3.28084

    /// WGS84 lon/lat -> UTM easting/northing (Snyder 1987, eq. 8-9..8-10). Sub-metre accuracy
    /// within a zone, which is far below the 5 m grid cell. NAD83 vs WGS84 (~1 m) is ignored.
    static func utm(lon: Double, lat: Double, zone: Int = 10) -> (x: Double, y: Double) {
        let a = 6378137.0, f = 1 / 298.257223563, k0 = 0.9996
        let e2 = f * (2 - f), e4 = e2 * e2, e6 = e4 * e2, ep2 = e2 / (1 - e2)
        let phi = lat * .pi / 180
        let lam0 = Double(zone * 6 - 183) * .pi / 180
        let sinP = sin(phi), cosP = cos(phi), tanP = tan(phi)
        let n = a / sqrt(1 - e2 * sinP * sinP)
        let t = tanP * tanP, c = ep2 * cosP * cosP
        let A = (lon * .pi / 180 - lam0) * cosP
        let m = a * ((1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi
                     - (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * sin(2 * phi)
                     + (15 * e4 / 256 + 45 * e6 / 1024) * sin(4 * phi)
                     - (35 * e6 / 3072) * sin(6 * phi))
        let x = k0 * n * (A + (1 - t + c) * pow(A, 3) / 6 + (5 - 18 * t + t * t + 72 * c - 58 * ep2) * pow(A, 5) / 120) + 500000
        let y = k0 * (m + n * tanP * (A * A / 2 + (5 - t + 9 * c + 4 * c * c) * pow(A, 4) / 24
                                      + (61 - 58 * t + t * t + 600 * c - 330 * ep2) * pow(A, 6) / 720))
        return (x, y)
    }

    /// Great-circle distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6371000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from a to b, degrees clockwise from true north.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(p2), x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Initial bearing from a to b as an 8-point compass word ("north", "southeast", ...).
    static func compass(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> String {
        let deg = bearing(from: a, to: b)
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        return names[Int((deg + 22.5) / 45) % 8]
    }

    /// Even-odd ray cast over every ring, so holes subtract. Rings are [[lon, lat]].
    static func contains(_ rings: [[[Double]]], lon: Double, lat: Double) -> Bool {
        var inside = false
        for ring in rings where ring.count > 2 {
            var j = ring.count - 1
            for i in 0..<ring.count {
                let xi = ring[i][0], yi = ring[i][1], xj = ring[j][0], yj = ring[j][1]
                if (yi > lat) != (yj > lat), lon < (xj - xi) * (lat - yi) / (yj - yi) + xi { inside.toggle() }
                j = i
            }
        }
        return inside
    }

    static func feet(_ m: Double) -> Double { m * ftPerM }

    /// "120 ft" under 1,000 ft, else "0.4 mi".
    static func walk(_ metres: Double) -> String {
        let ft = metres * ftPerM
        return ft < 1000 ? "\(Int((ft / 10).rounded() * 10)) ft" : String(format: "%.1f mi", metres / 1609.34)
    }
}
