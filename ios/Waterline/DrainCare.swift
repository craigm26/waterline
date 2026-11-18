import Foundation
import CoreLocation

/// Helping keep drains clear: which grates you've cleared (on this phone only, never sent), where to
/// report a blocked one, and the inlet type names. Reporting links open the city's own 311 page.
enum DrainCare {
    private static let key = "drainsCleared"

    /// When you last marked this drain cleared.
    static func cleared(_ id: String) -> Date? {
        guard let t = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[id] else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func markCleared(_ id: String, _ on: Bool) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        d[id] = on ? Date().timeIntervalSince1970 : nil
        UserDefaults.standard.set(d, forKey: key)
    }

    static func ago(_ d: Date) -> String {
        let h = Date().timeIntervalSince(d) / 3600
        if h < 1 { return "just now" }
        if h < 24 { return "\(Int(h)) h ago" }
        return "\(Int(h / 24)) d ago"
    }

    struct Report { let name: String; let url: URL; let detail: String }

    /// Where a blocked grate gets reported, by place. Checked Nov 18, 2026.
    static func report(at c: CLLocationCoordinate2D) -> Report? {
        if Places.inSF(c) {
            return .init(name: "SF311: report a blocked storm drain", url: URL(string: "https://sf311.org")!,
                         detail: "Or call 311. Say \"clogged catch basin\" and the cross streets.")
        }
        // Sacramento County: the County drain layer covers the unincorporated area (Carmichael, Fair Oaks, Arden Arcade...)
        if (38.02...38.74).contains(c.latitude) && (-121.87...(-121.02)).contains(c.longitude) {
            return .init(name: "Sacramento County 311", url: URL(string: "https://311.saccounty.gov")!,
                         detail: "Outside the County's area, report to your city (Sacramento city: call 311).")
        }
        return nil
    }

    /// Auto-detect: the forecast rain, run over the ground with drains blocked, leaves water
    /// standing within 25 m of this grate. That's the grate to check before the rain.
    static func pondNear(_ c: CLLocationCoordinate2D, _ r: SpotReport?) -> (pond: DrainageMap.Pond, metres: Double, rainIn: Double)? {
        guard let e = r?.rainEstimate else { return nil }
        let best = e.ponds.filter { $0.maxFt >= 0.1 }.map { ($0, Geo.distance(c, $0.coordinate)) }.filter { $0.1 <= 25 }.min { $0.1 < $1.1 }
        return best.map { ($0.0, $0.1, e.forecastIn) }
    }

    enum Problem: String, CaseIterable, Identifiable {
        case leaves = "Leaves or trash covering the grate"
        case pooling = "Water pooling and not draining"
        case blocked = "Blocked or damaged under the grate"
        var id: String { rawValue }
    }

    /// The text of a 311 report, for the person to read, change and send themselves.
    static func draft(_ poi: POI, problem: Problem, near place: String?, cleared: Bool) -> String {
        let id = poi.facts.first { $0.label == "Asset ID" }?.value
        let when = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        var t = "Clogged storm drain: \(problem.rawValue.lowercased())."
        t += cleared ? " I cleared the top of the grate but it still isn't draining." : ""
        t += "\nLocation: \(String(format: "%.6f, %.6f", poi.coordinate.latitude, poi.coordinate.longitude))"
        if let place { t += " (near \(place))" }
        if let id { t += "\nSFPUC inlet asset ID: \(id)" }
        t += "\nSeen: \(when)"
        return t
    }

    static func typeName(_ code: String) -> String {
        switch code {
        case "cb": return "catch basin"
        case "in": return "storm water inlet"
        case "di": return "drop inlet"
        case "ad": return "area drain"
        case "tr": return "trench drain"
        case "tk": return "track drain"
        case "ci": return "curb inlet"
        default: return "storm drain inlet"
        }
    }
}

/// Adopt a Drain SF's live map: which grates a neighbour has adopted. Read from the program's own
/// public map endpoint (the one its web map calls), a 2 km box at a time, kept for 6 hours, never
/// copied off the phone. Only the adopted/open state is used: never the adopter's name or account.
enum AdoptADrainSF {
    enum State: String, Codable { case adopted, open }
    private struct Point: Codable { let lat: Double, lon: Double, adopted: Bool }
    private static var cells: [String: [Point]] = [:]
    private static let lock = NSLock()
    private static let cell = 0.02
    private static let maxAge: TimeInterval = 6 * 3600

    private static func key(_ c: CLLocationCoordinate2D) -> String {
        "aad-\(Int((c.latitude / cell).rounded(.down)))_\(Int((c.longitude / cell).rounded(.down))).json"
    }
    private static func file(_ k: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(k)
    }

    /// The program's state for the grate at this point (its points sit on SFPUC's to the centimetre).
    static func state(at c: CLLocationCoordinate2D) -> State? {
        let k = key(c)
        lock.lock(); var pts = cells[k]; lock.unlock()
        if pts == nil, let d = try? Data(contentsOf: file(k)), let v = try? JSONDecoder().decode([Point].self, from: d) {
            pts = v; lock.lock(); cells[k] = v; lock.unlock()
        }
        guard let pts else { return nil }
        let dLat = 3.0 / 111_132, dLon = 3.0 / (111_320 * cos(c.latitude * .pi / 180))
        guard let p = pts.first(where: { abs($0.lat - c.latitude) <= dLat && abs($0.lon - c.longitude) <= dLon }) else { return nil }
        return p.adopted ? .adopted : .open
    }

    /// Fetch this spot's box unless a fresh copy is on the phone. Quietly does nothing offline.
    static func load(near c: CLLocationCoordinate2D) async {
        guard Places.inSF(c) else { return }
        let k = key(c), url = file(k)
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path), let d = a[.modificationDate] as? Date,
           Date().timeIntervalSince(d) < maxAge { return }
        let lat0 = (c.latitude / cell).rounded(.down) * cell, lon0 = (c.longitude / cell).rounded(.down) * cell, m = 0.004
        var q = URLRequest(url: URL(string: "https://adoptadrain.sfwater.org/getDrainsPoints")!, timeoutInterval: 30)
        q.httpMethod = "POST"
        q.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        q.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        let f = { (v: Double) in String(format: "%.5f", v) }
        q.httpBody = "north=\(f(lat0 + cell + m))&east=\(f(lon0 + cell + m))&south=\(f(lat0 - m))&west=\(f(lon0 - m))".data(using: .utf8)
        guard let (d, r) = try? await URLSession.shared.data(for: q), (r as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], (o["ErrorCode"] as? Int) == 0,
              let rows = o["Records"] as? [[String: Any]] else { return }
        let pts: [Point] = rows.compactMap { row in
            guard let la = Double("\(row["lat"] ?? "")"), let lo = Double("\(row["lng"] ?? "")") else { return nil }
            let owner = (row["owner"] as? Int) ?? Int("\(row["owner"] ?? "0")") ?? 0
            return Point(lat: la, lon: lo, adopted: owner != 0)
        }
        guard !pts.isEmpty else { return }
        if let e = try? JSONEncoder().encode(pts) { try? e.write(to: url) }
        lock.lock(); cells[k] = pts; lock.unlock()
    }
}
