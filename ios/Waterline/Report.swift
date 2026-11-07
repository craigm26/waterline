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
    var grid: ElevationGrid.Sample?
    var nearbyBowl: ElevationGrid.GridSpot?
    var tide: TideOutlook?
    var rain: RainOutlook?
    var rainEstimate: RainEstimate?
    var drains: [(Places.Drain, Double)] = []
    var flood311Near = 0        // within 150 m (~500 ft)
    var lowSpot: (Places.LowSpot, Double)?
    /// Nearest dry ground for this month's highest tide + anomaly + a 2 ft storm (SF grid).
    var higherGround: ElevationGrid.GridSpot?
    var inZone = false
    var inSF = false
    /// This place's layers (bundled, pack or live), and the tags built from them.
    var layers: Places?
    var layerPOIs: [POI] = []
    /// River gauges within 60 km (NWS), nearest first; the AR view tags them.
    var gauges: [RiverGauge] = []
    /// The nearest gauge within 15 km whose flood stages convert to elevations.
    var river: RiverFloodLevels?
    var fema: FEMAZone?
    var gridName: String?
    var problems: [String] = []

    // MARK: derived numbers

    /// Only SF's 311 feed is flooding reports. Other cities' feeds mostly log drain service
    /// requests, so they're shown but don't move the risk level.
    var floodReports: Int { inSF ? flood311Near : 0 }

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
    /// How far the river at major flood stage would stand above this ground (NAVD88 both sides).
    var riverMajorAboveGroundFt: Double? {
        guard let rv = river, let g = ground?.navd88Ft else { return nil }
        return rv.majorNAVD88 - g
    }

    var level: Level {
        let m = coastalMarginFt ?? .infinity
        let riverNow = gauges.first.map { $0.severity >= 2 && Geo.distance(coordinate, $0.coordinate) < 15_000 } ?? false
        if m < 1 || (bowlFt >= 1 && (inZone || floodReports >= 10)) || riverNow || ["V", "VE"].contains(fema?.zone ?? "") { return .high }
        if m < 3 || bowlFt >= 0.5 || inZone || floodReports >= 5 || (nearbyBowl?.valueFt ?? 0) >= 1.5
            || (fema?.inSFHA ?? false) || (riverMajorAboveGroundFt ?? -1) > 0 || (fema?.subtype ?? "").uppercased().contains("LEVEE") { return .watch }
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
        if let rv = river, let d = riverMajorAboveGroundFt {
            let name = rv.gauge.name
            if d > 0 {
                out.append(String(format: "At major flood stage, the %@ stands %.1f ft (NAVD88) at the gauge %.0f km away: %.1f ft above the ground here. Levees and banks keep it out; if one failed nearby, water could approach that depth. The river surface rises upstream, so treat this as a floor.", name, rv.majorNAVD88, rv.km, d))
            } else {
                out.append(String(format: "You're %.1f ft above the %@ at major flood stage, measured at the gauge %.0f km away (the river runs higher upstream).", -d, name, rv.km))
            }
        }
        if let g = gauges.first(where: { $0.severity >= 1 }) {
            out.append("\(g.name) is at \(g.categoryLabel.lowercased()) now (\(g.observed.map { String(format: "%.1f ft", $0) } ?? "no reading")).")
        }
        if let f = fema { out.append("FEMA: \(f.plain).") }
        if bowlFt >= 0.5 {
            out.append(String(format: "This spot sits %.1f ft below the lowest rim around it%@: rain collects here before it can drain away, and a flood that tops the rim fills it.", bowlFt, gridName.map { " (\($0) lidar)" } ?? ""))
        } else if let b = nearbyBowl, b.valueFt >= 0.5 {
            out.append(String(format: "There's a %.1f ft deep bowl %@ to the %@.", b.valueFt, Geo.walk(b.metres),
                              Geo.compass(from: coordinate, to: b.coordinate)))
        }
        if let ls = lowSpot, ls.1 < 250 {
            out.append(inSF ? "You're at one of the city's 50 worst street low spots: \(ls.0.name) (#\(ls.0.rank))."
                             : "You're near a mapped low spot in the ground: \(ls.0.name). This comes from elevation, not flood records.")
        }
        if inZone { out.append("Inside SFPUC's 100-year storm flood zone.") }
        if flood311Near > 0 {
            out.append(inSF ? "\(flood311Near) flooding report\(flood311Near == 1 ? "" : "s") to 311 within 500 ft."
                            : "\(layers?.reportsLabel ?? "City requests") within 500 ft: \(flood311Near).")
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
            out.append("\(lead) the storm drain \(Geo.walk(m)) \(Geo.compass(from: coordinate, to: d.coordinate)) \(d.ranked ? "(#\(d.rank) of 23,835 in the city)" : ""). If leaves cover the grate and it's safe, clear them; report blockages to 311.")
        }
        if let pit = drains.first(where: { $0.0.deep_pit }), pit.1 < 200 {
            let (d, m) = pit
            out.append("The drain \(Geo.walk(m)) \(Geo.compass(from: coordinate, to: d.coordinate)) sits in a deep pit (underpass or stairwell). Don't climb in; report it to 311.")
        }
        if bowlFt >= 1 || (lowSpot?.1 ?? .infinity) < 250 { out.append("Don't park or store anything at the low point during heavy rain.") }
        if let hg = higherGround {
            out.append("Higher ground (dry above this month's highest water and a major river flood): \(Geo.walk(hg.metres)) \(Geo.compass(from: coordinate, to: hg.coordinate)). The arrow on the Water line tab points to it.")
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
        if let e = rainEstimate {
            func d(_ ft: Double) -> Double? { ft >= 0.05 ? ft : nil }
            let rain = String(format: "%.2f in forecast", e.forecastIn)
            out.append(.init(id: "rain-work", label: "Next 24 h rain, drains working", detail: "\(rain) · Waterline estimate, drains assumed to take 0.5 in/h",
                             depthFt: d(e.workingFt), provenance: .derived, isStressTest: false))
            out.append(.init(id: "rain-block", label: "Next 24 h rain, drains blocked", detail: "\(rain) · Waterline estimate",
                             depthFt: d(e.blockedFt), provenance: .assumed, isStressTest: false))
            out.append(.init(id: "rain-stress", label: "2 in in an hour, drains blocked", detail: "Waterline estimate",
                             depthFt: d(e.stressFt), provenance: .assumed, isStressTest: true))
        }
        if bowlFt >= 0.3 {
            out.append(.init(id: "bowl", label: "Rain fills the bowl", detail: String(format: "%.1f ft before it spills (lidar)", bowlFt),
                             depthFt: bowlFt, provenance: .derived, isStressTest: false))
        }
        if let rv = river, let gNAVD = ground?.navd88Ft {
            if let now = rv.observedNAVD88, now > gNAVD {
                out.append(.init(id: "river-now", label: "River now", detail: rv.gauge.name, depthFt: now - gNAVD, provenance: .official, isStressTest: false))
            }
            out.append(.init(id: "river-major", label: "River at major flood stage", detail: "If a levee failed nearby · \(rv.gauge.name)",
                             depthFt: rv.majorNAVD88 > gNAVD ? rv.majorNAVD88 - gNAVD : nil, provenance: .assumed, isStressTest: false))
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
        async let gauges = (try? RiverGauge.near(c)) ?? []
        async let fema = FEMAZone.load(c)
        await LiveLayers.prepare(near: c)
        // the grids and city layers are local but heavy on first load: keep them off the main actor
        let local = await Task.detached(priority: .userInitiated) { () -> (ElevationGrid.Sample?, ElevationGrid.GridSpot?, String?, [(Places.Drain, Double)], Int, (Places.LowSpot, Double)?, Bool, Places?, [POI]) in
            let g = ElevationGrid.covering(c)
            guard let p = Places.covering(c) else { return (g?.sample(c), g?.deepestBowl(near: c), g?.name, [], 0, nil, false, nil, []) }
            return (g?.sample(c), g?.deepestBowl(near: c), g?.name, p.drains(near: c, within: 400, limit: 3),
                    p.flood311Count(near: c, within: 150), p.nearestLowSpot(to: c, within: 600), p.inFloodZone(c), p, SpotReport.layerPOIs(p, at: c))
        }.value
        (r.grid, r.nearbyBowl, r.gridName, r.drains, r.flood311Near, r.lowSpot, r.inZone, r.layers, r.layerPOIs) = local
        r.ground = await ground
        r.tide = await tide
        r.rain = await rain
        if let hours = r.rain?.hourlyNext24In {
            r.rainEstimate = await Task.detached(priority: .userInitiated) { RainEstimate.make(c, forecast: hours) }.value
        }
        r.placeLabel = await label
        r.gauges = await gauges
        r.fema = await fema
        r.river = await RiverFloodLevels.load(r.gauges, near: c)
        // Higher ground: dry for this month's highest tide + anomaly + a 2 ft storm, and above the
        // nearby river at major flood stage, whichever is higher.
        var needNAVD: Double?
        if let m = r.coastalMarginFt, m < 3, let w = r.worstWaterMLLW, let k = r.navdToMLLW { needNAVD = w + 2 - k }
        if let rv = r.river, (r.riverMajorAboveGroundFt ?? -1) > 0 { needNAVD = max(needNAVD ?? -.infinity, rv.majorNAVD88 + 1) }
        if let need = needNAVD, let g = r.ground?.navd88Ft, g < need {
            r.higherGround = await Task.detached(priority: .userInitiated) {
                ElevationGrid.covering(c)?.higherGround(near: c, aboveNAVD88Ft: need, maxM: 3000)
            }.value
        }
        if r.ground == nil { r.problems.append("Ground elevation unavailable (no network, and no offline grid here: download this region's pack).") }
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
