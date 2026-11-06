import Foundation
import CoreLocation

/// Provenance, per the repo rule: official = solid, derived = outlined, assumed = hatched.
enum Provenance {
    case official, derived, assumed
    var mark: String {
        switch self {
        case .official: return "●"
        case .derived: return "○"
        case .assumed: return "▨"
        }
    }
}

/// One water level to show in AR, relative to the ground at this spot.
struct WaterScenario: Identifiable, Hashable {
    let id: String
    let label: String
    let detail: String
    /// Water depth above the ground here, ft. nil = the water doesn't reach this spot.
    let depthFt: Double?
    let provenance: Provenance
    let isStressTest: Bool
}

/// Everything Waterline knows about one spot. Built by `SpotReport.build(at:)`.
struct SpotReport {
    enum Level { case low, watch, high }

    let coordinate: CLLocationCoordinate2D
    var placeLabel: String?
    var ground: GroundElevation.Result?
    var grid: SFGrid.Sample?
    var nearbyBowl: SFGrid.GridSpot?
    var tide: TideOutlook?
    var rain: RainOutlook?
    var drains: [(Places.Drain, Double)] = []
    var flood311Near = 0        // within 150 m (~500 ft)
    var lowSpot: (Places.LowSpot, Double)?
    /// Nearest dry ground for this month's highest tide + anomaly + a 2 ft storm (SF grid).
    var higherGround: SFGrid.GridSpot?
    var inZone = false
    var inSF = false
    var problems: [String] = []

    // MARK: derived numbers

    /// ft MLLW = ft NAVD88 + k. From the station's own datums; the SF value offline.
    var navdToMLLW: Double? { tide?.navd88ToMLLW ?? (inSF ? -0.06 : nil) }
    var groundMLLW: Double? { guard let g = ground, let k = navdToMLLW else { return nil }; return g.navd88Ft + k }
    var bowlFt: Double { grid?.bowlFt ?? 0 }
    /// The lowest Bay level that reaches this spot overland (SF grid); elsewhere we can only assume
    /// an open connection, which is the bathtub assumption and is labelled as such.
    var bayReachesMLLW: Double? { groundMLLW.map { $0 + bowlFt } }
    var connectivityKnown: Bool { grid != nil }
    var anomaly: Double { max(tide?.anomalyFt ?? 0, 0) }
    var worstWaterMLLW: Double? { tide?.highest.map { $0.ft + anomaly } }
    var coastalMarginFt: Double? {
        guard let b = bayReachesMLLW, let w = worstWaterMLLW else { return nil }
        return b - w
    }
    var rain72: Double { rain?.next72In ?? 0 }

    var level: Level {
        let m = coastalMarginFt ?? .infinity
        if m < 1 || (bowlFt >= 1 && (inZone || flood311Near >= 10)) { return .high }
        if m < 3 || bowlFt >= 0.5 || inZone || flood311Near >= 5 || (nearbyBowl?.valueFt ?? 0) >= 1.5 { return .watch }
        return .low
    }

    var title: String {
        switch level {
        case .high: return "Higher flood risk here"
        case .watch: return "Some flood risk here"
        case .low: return "Low flood risk here"
        }
    }

    // MARK: words

    /// One line per hazard, most important first.
    var findings: [String] {
        var out: [String] = []
        if let m = coastalMarginFt, let w = worstWaterMLLW, let top = tide?.highest {
            let when = Self.day.string(from: top.time)
            if m < 0 {
                out.append(String(format: "The highest tide this month (%@, %.1f ft with today's anomaly) would reach this spot%@.",
                                  when, w, connectivityKnown ? " overland" : ""))
            } else if m < 1 {
                out.append(String(format: "Within a foot of the highest tide this month (%@).", when))
            } else if m < 6 {
                out.append(String(format: "%.1f ft above the highest tide this month (%@). A strong storm surge adds about 2 ft.", m, when))
            } else {
                out.append(String(format: "%.0f ft above the highest tide this month: the Bay isn't a risk here.", m))
            }
            if connectivityKnown, bowlFt >= 0.5, let g = groundMLLW, w > g {
                out.append(String(format: "Your ground is below that tide, but higher ground around you keeps the Bay out until it reaches %.1f ft.", g + bowlFt))
            }
        } else if tide == nil, ground != nil {
            out.append("No tide gauge within 60 km, so coastal flooding isn't assessed here.")
        }
        if bowlFt >= 0.5 {
            out.append(String(format: "This spot sits in a bowl about %.1f ft deep: rain collects here before it can drain away.", bowlFt))
        } else if let b = nearbyBowl, b.valueFt >= 0.5 {
            out.append(String(format: "There's a %.1f ft deep bowl %@ to the %@.", b.valueFt, Geo.walk(b.metres),
                              Geo.compass(from: coordinate, to: b.coordinate)))
        }
        if let ls = lowSpot, ls.1 < 250 {
            out.append("You're at one of the city's 50 worst street low spots: \(ls.0.name) (#\(ls.0.rank)).")
        }
        if inZone { out.append("Inside SFPUC's 100-year storm flood zone.") }
        if flood311Near > 0 {
            out.append("\(flood311Near) flooding report\(flood311Near == 1 ? "" : "s") to 311 within 500 ft.")
        }
        if let r = rain {
            out.append(r.next72In >= 0.05
                ? String(format: "NWS forecast: %.2f in of rain in the next 3 days (%d%% chance in the next 24 h).", r.next72In, r.chance24Pct)
                : "NWS forecast: no meaningful rain in the next 3 days.")
        }
        return out
    }

    /// Things a person here can actually do.
    var actions: [String] {
        var out: [String] = []
        if let near = drains.first(where: { !$0.0.deep_pit }), near.1 < 200 {
            let (d, m) = near
            let lead = rain72 >= 0.25 ? "Before the rain, check" : "Know"
            out.append("\(lead) the storm drain \(Geo.walk(m)) \(Geo.compass(from: coordinate, to: d.coordinate)) (#\(d.rank) of 23,835 in the city). If leaves cover the grate and it's safe, clear them; report blockages to 311.")
        }
        if let pit = drains.first(where: { $0.0.deep_pit }), pit.1 < 200 {
            let (d, m) = pit
            out.append("The drain \(Geo.walk(m)) \(Geo.compass(from: coordinate, to: d.coordinate)) sits in a deep pit (underpass or stairwell). Don't climb in; report it to 311.")
        }
        if bowlFt >= 1 || (lowSpot?.1 ?? .infinity) < 250 { out.append("Don't park or store anything at the low point during heavy rain.") }
        if let hg = higherGround {
            out.append("Higher ground (dry even with a strong storm on this month's highest tide): \(Geo.walk(hg.metres)) \(Geo.compass(from: coordinate, to: hg.coordinate)). The arrow on the Water line tab points to it.")
        }
        if let m = coastalMarginFt, m < 2, let top = tide?.highest {
            out.append("Check the tide before walking or parking here around \(Self.day.string(from: top.time)).")
        }
        out.append(inSF ? "Official alerts: text your ZIP code to 888-777 (AlertSF)." : "Official warnings come from your local National Weather Service office.")
        return out
    }

    /// Water levels to see in AR, as depth above the ground here.
    var scenarios: [WaterScenario] {
        var out: [WaterScenario] = []
        if bowlFt >= 0.3 {
            out.append(.init(id: "bowl", label: "Rain fills the bowl", detail: String(format: "%.1f ft before it spills (lidar)", bowlFt),
                             depthFt: bowlFt, provenance: .derived, isStressTest: false))
        }
        guard let t = tide, let g = groundMLLW, let reach = bayReachesMLLW else { return out }
        func depth(_ level: Double) -> Double? { level >= reach ? level - g : nil }
        if let n = t.nextHigh {
            out.append(.init(id: "next", label: "Next high tide", detail: "\(Self.day.string(from: n.time)), NOAA \(t.stationName)",
                             depthFt: depth(n.ft), provenance: .official, isStressTest: false))
        }
        if let h = t.highest {
            out.append(.init(id: "top", label: "Highest tide this month", detail: Self.day.string(from: h.time),
                             depthFt: depth(h.ft), provenance: .official, isStressTest: false))
            if anomaly > 0.05 {
                out.append(.init(id: "top+a", label: "Highest + today's anomaly", detail: String(format: "+%.2f ft gauge anomaly, if it holds", anomaly),
                                 depthFt: depth(h.ft + anomaly), provenance: .derived, isStressTest: false))
            }
            out.append(.init(id: "storm", label: "+ a strong storm", detail: "+2 ft surge on top, assumed",
                             depthFt: depth(h.ft + anomaly + 2), provenance: .assumed, isStressTest: false))
            out.append(.init(id: "stress", label: "Stress test", detail: "+3.07 ft, the Feb 1998 peak storm residual at SF",
                             depthFt: depth(h.ft + 3.07), provenance: .assumed, isStressTest: true))
        }
        return out
    }

    static let day: DateFormatter = { let d = DateFormatter(); d.dateFormat = "EEE MMM d, h:mm a"; return d }()

    // MARK: building

    static func build(at c: CLLocationCoordinate2D) async -> SpotReport {
        var r = SpotReport(coordinate: c)
        r.inSF = Places.inSF(c)
        async let ground = GroundElevation.load(c)
        async let tide = try? TideOutlook.load(near: c)
        async let rain = try? RainOutlook.load(c)
        async let label = placeName(c)
        let inSF = r.inSF
        // the grid and city layers are local but heavy on first load: keep them off the main actor
        let local = await Task.detached(priority: .userInitiated) { () -> (SFGrid.Sample?, SFGrid.GridSpot?, [(Places.Drain, Double)], Int, (Places.LowSpot, Double)?, Bool) in
            guard inSF else { return (nil, nil, [], 0, nil, false) }
            let g = SFGrid.shared, p = Places.shared
            return (g?.sample(c), g?.deepestBowl(near: c), p?.drains(near: c, within: 400, limit: 3) ?? [],
                    p?.flood311Count(near: c, within: 150) ?? 0, p?.nearestLowSpot(to: c, within: 600), p?.inFloodZone(c) ?? false)
        }.value
        (r.grid, r.nearbyBowl, r.drains, r.flood311Near, r.lowSpot, r.inZone) = local
        r.ground = await ground
        r.tide = await tide
        r.rain = await rain
        r.placeLabel = await label
        if inSF, let m = r.coastalMarginFt, m < 3, let w = r.worstWaterMLLW, let k = r.navdToMLLW {
            let needNAVD = w + 2 - k
            if let g = r.ground?.navd88Ft, g < needNAVD {
                r.higherGround = await Task.detached(priority: .userInitiated) {
                    SFGrid.shared?.higherGround(near: c, aboveNAVD88Ft: needNAVD)
                }.value
            }
        }
        if r.ground == nil { r.problems.append("Ground elevation unavailable (no network, and outside the bundled SF lidar).") }
        if r.tide == nil, r.inSF { r.problems.append("NOAA tide data unavailable right now.") }
        if r.rain == nil { r.problems.append("NWS rain forecast unavailable right now.") }
        return r
    }

    private static func placeName(_ c: CLLocationCoordinate2D) async -> String? {
        let p = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)).first
        guard let p else { return nil }
        return [p.name, p.subLocality ?? p.locality].compactMap { $0 }.joined(separator: ", ")
    }
}
