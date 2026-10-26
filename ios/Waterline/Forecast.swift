import Foundation

/// NOAA CO-OPS 9414290 (San Francisco), fetched live. Same method as scripts/refresh_live.py
/// and the city page: 15-day high/low predictions, plus the 30-day mean of observed minus
/// predicted water level (the El Niño / Kelvin-wave anomaly).
struct Forecast {
    struct High: Hashable { let time: Date; let label: String; let ft: Double }
    let highs: [High]
    let anomalyFt: Double
    let fetched: Date

    static let station = "9414290"

    static func load() async throws -> Forecast {
        let now = Date()
        async let hilo = rows(product: "predictions", from: now, to: now.addingTimeInterval(15 * 86400), extra: "&interval=hilo", key: "predictions")
        async let obs = rows(product: "water_level", from: now.addingTimeInterval(-30 * 86400), to: now, extra: "", key: "data")
        async let pred = rows(product: "predictions", from: now.addingTimeInterval(-30 * 86400), to: now, extra: "&interval=6", key: "predictions")
        let (h, o, p) = try await (hilo, obs, pred)
        let predicted = Dictionary(p.compactMap { r in Double(r.v).map { (r.t, $0) } }, uniquingKeysWith: { a, _ in a })
        let residuals = o.compactMap { r -> Double? in
            guard let v = Double(r.v), let q = predicted[r.t] else { return nil }
            return v - q
        }
        guard !residuals.isEmpty else { throw URLError(.cannotParseResponse) }
        let anomaly = residuals.reduce(0, +) / Double(residuals.count)
        let highs = h.filter { $0.type == "H" || $0.type == "HH" }.compactMap { r -> High? in
            guard let ft = Double(r.v), let t = parse(r.t), t > now else { return nil }
            return High(time: t, label: shortLabel(t), ft: ft)
        }
        return Forecast(highs: highs, anomalyFt: anomaly, fetched: now)
    }

    // MARK: CO-OPS plumbing

    private struct Row: Decodable { let t: String; let v: String; let type: String? }
    private struct Page: Decodable { let predictions: [Row]?; let data: [Row]? }

    private static let pacific = TimeZone(identifier: "America/Los_Angeles")!
    private static func formatter(_ f: String) -> DateFormatter {
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.timeZone = pacific; d.dateFormat = f; return d
    }
    private static let coopsTime = formatter("yyyy-MM-dd HH:mm")
    private static let query = formatter("yyyyMMdd HH:mm")
    private static let label = formatter("EEE MMM d, h:mm a")
    static func parse(_ s: String) -> Date? { coopsTime.date(from: s) }
    static func shortLabel(_ d: Date) -> String { label.string(from: d) }

    private static func rows(product: String, from: Date, to: Date, extra: String, key: String) async throws -> [Row] {
        var c = URLComponents(string: "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter")!
        c.percentEncodedQuery = [
            "station=\(station)", "product=\(product)", "datum=MLLW", "units=english", "time_zone=lst_ldt",
            "format=json", "application=waterline-ios",
            "begin_date=\(query.string(from: from).replacingOccurrences(of: " ", with: "%20"))",
            "end_date=\(query.string(from: to).replacingOccurrences(of: " ", with: "%20"))",
        ].joined(separator: "&") + extra
        let (data, resp) = try await URLSession.shared.data(from: c.url!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let page = try JSONDecoder().decode(Page.self, from: data)
        return (key == "data" ? page.data : page.predictions) ?? []
    }
}
