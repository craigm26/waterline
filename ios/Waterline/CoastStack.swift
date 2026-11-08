import Foundation
import CoreLocation

/// What can stack on a high tide at one NOAA station, each piece from its own source:
///
/// - King tide: the highest tide NOAA predicts in the next 12 months (official).
/// - Sea running high: the station's measured water against its prediction over the last 30
///   days (derived). On the Pacific coast El Niño raises it for months: warm water and the
///   coastally trapped Kelvin waves it sends north lift the whole sea surface.
/// - El Niño winters on record: the station's monthly mean sea level with its long-term rise and
///   its normal seasonal cycle taken out (derived from NOAA's monthly means).
/// - The record storm push: the station's highest measured water minus the tide predicted for
///   that hour, minus that month's sea level anomaly, so the El Niño part isn't counted twice.
/// - Sea level rise by 2050 and 2100 comes from `SeaLevelRise` (NOAA 2022 report).
struct CoastStack: Hashable {
    struct Month: Hashable { let year: Int; let month: Int; let ft: Double
        var label: String { DateFormatter().shortMonthSymbols[month - 1] + " \(year)" }
    }
    struct Record: Hashable {
        let ftMLLW: Double          // NOAA's highest observed, from the station datums
        let date: Date
        var pushFt: Double?         // measured minus predicted at the peak hour, less that month's anomaly
        var year: Int { Calendar.current.component(.year, from: date) }
    }
    let stationID: String
    var king: TideOutlook.High?
    /// The latest month's anomaly, and the station's highest month on record.
    var monthNow: Month?
    var monthTop: [Month] = []
    var firstYear: Int?
    var firstYearLabel: String { firstYear.map(String.init) ?? "records began" }
    var record: Record?
    var pacific: Bool

    static let monthlyPage = URL(string: "https://tidesandcurrents.noaa.gov/sltrends/")!

    static func load(_ t: TideOutlook) async -> CoastStack {
        var s = CoastStack(stationID: t.stationID, pacific: t.stationCoordinate.longitude < -115)
        async let king = kingTide(t.stationID)
        async let months = anomalies(t.stationID)
        let m = await months
        s.king = await king
        s.monthNow = m.last
        s.firstYear = m.first?.year
        // Highest months, one per winter, so 1983's Jan, Feb and Mar don't fill the list.
        var seen = Set<Int>()
        s.monthTop = m.sorted { $0.ft > $1.ft }.filter { x in
            let winter = x.month >= 7 ? x.year : x.year - 1
            return seen.insert(winter).inserted
        }.prefix(3).map { $0 }
        s.record = await record(t.stationID, months: m)
        return s
    }

    /// What `ft` the sea runs high by in the worst El Niño month on record here.
    var elNinoTop: Month? { monthTop.first }

    // MARK: sources

    private struct Pred: Decodable { struct R: Decodable { let t: String; let v: String; let type: String? }; let predictions: [R]?; let data: [R]? }
    private static func coops(_ q: String) -> URL {
        URL(string: "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?units=english&format=json&application=waterline-ios&" + q)!
    }
    private static let ymd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    static func kingTide(_ id: String) async -> TideOutlook.High? {
        let now = Date()
        let u = coops("product=predictions&station=\(id)&datum=MLLW&time_zone=gmt&interval=hilo&begin_date=\(ymd.string(from: now))&range=8760")
        guard let p: Pred = try? await Net.cachedJSON(u, cacheName: "king-\(id).json", maxAge: 7 * 86400) else { return nil }
        return (p.predictions ?? []).compactMap { r -> TideOutlook.High? in
            guard let v = Double(r.v), let t = stamp.date(from: r.t), t > now else { return nil }
            return .init(time: t, ft: v)
        }.max { $0.ft < $1.ft }
    }

    private struct Monthly: Decodable { struct R: Decodable { let year: String; let month: String; let MSL: String? }; let data: [R]? }

    /// Monthly mean sea level minus its straight-line trend and its average for that calendar month.
    static func anomalies(_ id: String) async -> [Month] {
        let end = ymd.string(from: Date())
        let u = coops("product=monthly_mean&station=\(id)&datum=MSL&time_zone=lst&begin_date=19000101&end_date=\(end)")
        guard let m: Monthly = try? await Net.cachedJSON(u, cacheName: "monthly-\(id).json", maxAge: 7 * 86400) else { return [] }
        let rows = (m.data ?? []).compactMap { r -> (t: Double, y: Int, mo: Int, v: Double)? in
            guard let y = Int(r.year), let mo = Int(r.month), let v = r.MSL.flatMap(Double.init) else { return nil }
            return (Double(y) + (Double(mo) - 0.5) / 12, y, mo, v)
        }
        guard rows.count >= 120 else { return [] }
        let n = Double(rows.count)
        let mt = rows.reduce(0) { $0 + $1.t } / n, my = rows.reduce(0) { $0 + $1.v } / n
        let b = rows.reduce(0) { $0 + ($1.t - mt) * ($1.v - my) } / rows.reduce(0) { $0 + ($1.t - mt) * ($1.t - mt) }
        let res = rows.map { (y: $0.y, mo: $0.mo, r: $0.v - (my + b * ($0.t - mt))) }
        var season = [Int: Double]()
        for mo in 1...12 {
            let xs = res.filter { $0.mo == mo }.map(\.r)
            season[mo] = xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
        }
        return res.map { Month(year: $0.y, month: $0.mo, ft: $0.r - (season[$0.mo] ?? 0)) }
    }

    private struct Datums: Decodable {
        struct D: Decodable { let name: String; let value: Double? }
        let datums: [D]?; let max: Double?; let maxdate: String?
    }

    /// NOAA's highest observed water here, and how much of it was the storm.
    static func record(_ id: String, months: [Month]) async -> Record? {
        let du = URL(string: "\(TideOutlook.mdapi)/stations/\(id)/datums.json?units=english")!
        guard let d: Datums = try? await Net.cachedJSON(du, cacheName: "datums-\(id).json", maxAge: 30 * 86400),
              let top = d.max, let day = d.maxdate, let date = ymd.date(from: day),
              let mllw = d.datums?.first(where: { $0.name == "MLLW" })?.value else { return nil }
        var rec = Record(ftMLLW: top - mllw, date: date, pushFt: nil)
        // The record's time of day isn't labelled with a zone, so find the peak hour in the
        // hourly heights around that day and compare it with the prediction for the same hour.
        let from = ymd.string(from: date.addingTimeInterval(-86400)), to = ymd.string(from: date.addingTimeInterval(86400))
        async let obs: Pred? = try? Net.cachedJSON(coops("product=hourly_height&station=\(id)&datum=MLLW&time_zone=gmt&begin_date=\(from)&end_date=\(to)"),
                                                     cacheName: "rec-obs-\(id).json", maxAge: 365 * 86400)
        async let pred: Pred? = try? Net.cachedJSON(coops("product=predictions&station=\(id)&datum=MLLW&time_zone=gmt&interval=h&begin_date=\(from)&end_date=\(to)"),
                                                      cacheName: "rec-pred-\(id).json", maxAge: 365 * 86400)
        guard let o = await obs?.data, let p = await pred?.predictions,
              let peak = o.compactMap({ r in Double(r.v).map { (r.t, $0) } }).max(by: { $0.1 < $1.1 }),
              let tide = p.first(where: { $0.t == peak.0 }).flatMap({ Double($0.v) }) else { return rec }
        let cal = Calendar(identifier: .gregorian)
        let y = cal.component(.year, from: date), mo = cal.component(.month, from: date)
        let monthAnomaly = months.first { $0.year == y && $0.month == mo }?.ft ?? 0
        rec.pushFt = max(0, peak.1 - tide - max(0, monthAnomaly))
        return rec
    }
}

/// NOAA CPC's Oceanic Niño Index: the latest 3-month sea surface temperature anomaly in the
/// central Pacific. +0.5 °C or more is El Niño, +1.5 strong; -0.5 or less is La Niña.
struct ENSO: Hashable {
    let season: String     // "ASO 2026"
    let oni: Double
    static let page = URL(string: "https://www.cpc.ncep.noaa.gov/products/analysis_monitoring/ensostuff/ONI_v5.php")!
    private static let source = URL(string: "https://www.cpc.ncep.noaa.gov/data/indices/oni.ascii.txt")!

    var phase: String {
        switch oni {
        case 1.5...: return "a strong El Niño"
        case 0.5..<1.5: return "an El Niño"
        case ...(-0.5): return "a La Niña"
        default: return "neither El Niño nor La Niña"
        }
    }
    var isElNino: Bool { oni >= 0.5 }

    static func load() async -> ENSO? {
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("oni.txt")
        var text: String?
        if let a = try? FileManager.default.attributesOfItem(atPath: file.path), let d = a[.modificationDate] as? Date,
           Date().timeIntervalSince(d) < 86400 * 3 { text = try? String(contentsOf: file, encoding: .utf8) }
        if text == nil {
            var r = URLRequest(url: source, timeoutInterval: 20)
            r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
            if let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 {
                text = String(data: d, encoding: .utf8); try? d.write(to: file)
            }
        }
        guard let last = text?.split(separator: "\n").last?.split(separator: " ", omittingEmptySubsequences: true),
              last.count >= 4, let v = Double(last[3]) else { return nil }
        return ENSO(season: "\(last[0]) \(last[1])", oni: v)
    }
}
