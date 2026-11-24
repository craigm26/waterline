import Foundation
import CoreLocation
import SwiftUI

enum CameraSource: String, CaseIterable, Identifiable, Hashable {
    case usgs = "USGS River"
    case caltrans = "Caltrans"
    case nycDot = "NYC DOT"

    var id: String { rawValue }
}

/// Unified public flood/river/highway camera across USGS HIVIS (nationwide),
/// all 12 Caltrans Districts (CA), and NYC DOT (NYC).
struct CaltransCamera: Identifiable, Hashable {
    let id: String
    let source: CameraSource
    let district: Int
    let name: String
    let route: String
    let direction: String
    let county: String
    let latitude: Double
    let longitude: Double
    let imageURL: URL
    let streamURL: URL?
    let inService: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isWaterCorridor: Bool {
        if source == .usgs { return true }
        let s = (name + " " + route).lowercased()
        let tokens = [
            "bridge", "river", "creek", "bay", "causeway", "coast", "beach",
            "embarcadero", "marina", "harbor", "pier", "slough", "delta",
            "levee", "channel", "pocket", "natomas", "dumbarton", "san mateo",
            "golden gate", "bayshore", "tunnel", "underpass", "fdr", "west side",
            "brooklyn", "manhattan", "hudson", "east river", "101", "80", "5"
        ]
        return tokens.contains(where: { s.contains($0) })
    }

    func imageURL(cacheBust: Int) -> URL {
        var comps = URLComponents(url: imageURL, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.removeAll { $0.name == "t" }
        items.append(URLQueryItem(name: "t", value: String(cacheBust)))
        comps?.queryItems = items
        return comps?.url ?? imageURL
    }

    func distanceMeters(from origin: CLLocationCoordinate2D) -> Double {
        Geo.distance(origin, coordinate)
    }
}

/// All 12 official California Caltrans districts (cwwp2.dot.ca.gov).
enum CaltransDistrict: Int, CaseIterable, Identifiable {
    case d4 = 4   // SF Bay Area
    case d3 = 3   // Sacramento / Valley / Sierra
    case d1 = 1   // North Coast (Eureka / Russian & Eel Rivers)
    case d2 = 2   // Redding / Shasta
    case d5 = 5   // Central Coast (Pajaro / Salinas)
    case d6 = 6   // Fresno / San Joaquin Valley
    case d7 = 7   // Los Angeles
    case d8 = 8   // San Bernardino / Riverside
    case d9 = 9   // Eastern Sierra
    case d10 = 10 // Stockton / Delta
    case d11 = 11 // San Diego
    case d12 = 12 // Orange County

    var id: Int { rawValue }

    var shortLabel: String {
        switch self {
        case .d1: return "North Coast (D1)"
        case .d2: return "Redding (D2)"
        case .d3: return "Sacramento (D3)"
        case .d4: return "SF Bay (D4)"
        case .d5: return "Central Coast (D5)"
        case .d6: return "Fresno (D6)"
        case .d7: return "LA (D7)"
        case .d8: return "Inland (D8)"
        case .d9: return "E. Sierra (D9)"
        case .d10: return "Delta/Stockton (D10)"
        case .d11: return "San Diego (D11)"
        case .d12: return "OC (D12)"
        }
    }

    var center: CLLocationCoordinate2D {
        switch self {
        case .d1: return CLLocationCoordinate2D(latitude: 40.8021, longitude: -124.1637)
        case .d2: return CLLocationCoordinate2D(latitude: 40.5865, longitude: -122.3917)
        case .d3: return CLLocationCoordinate2D(latitude: 38.5816, longitude: -121.4944)
        case .d4: return CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        case .d5: return CLLocationCoordinate2D(latitude: 36.6002, longitude: -121.8947)
        case .d6: return CLLocationCoordinate2D(latitude: 36.7378, longitude: -119.7871)
        case .d7: return CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        case .d8: return CLLocationCoordinate2D(latitude: 34.1083, longitude: -117.2898)
        case .d9: return CLLocationCoordinate2D(latitude: 37.3614, longitude: -118.3997)
        case .d10: return CLLocationCoordinate2D(latitude: 37.9577, longitude: -121.2908)
        case .d11: return CLLocationCoordinate2D(latitude: 32.7157, longitude: -117.1611)
        case .d12: return CLLocationCoordinate2D(latitude: 33.7175, longitude: -117.8311)
        }
    }

    var feedURL: URL {
        let code = String(format: "D%02d", rawValue)
        return URL(string: "https://cwwp2.dot.ca.gov/data/d\(rawValue)/cctv/cctvStatus\(code).json")!
    }

    static func nearest(to coord: CLLocationCoordinate2D) -> CaltransDistrict? {
        guard coord.latitude > 32.0, coord.latitude < 42.5,
              coord.longitude > -125.0, coord.longitude < -113.5 else { return nil }
        return allCases.min(by: { Geo.distance(coord, $0.center) < Geo.distance(coord, $1.center) })
    }
}

@MainActor
final class CaltransCameraStore: ObservableObject {
    static let shared = CaltransCameraStore()

    @Published var camerasByDistrict: [CaltransDistrict: [CaltransCamera]] = [:]
    @Published var usgsCameras: [CaltransCamera] = []
    @Published var nycCameras: [CaltransCamera] = []
    @Published var loadingDistricts: Set<CaltransDistrict> = []
    @Published var loadingUSGS = false
    @Published var loadingNYC = false
    @Published var lastError: String?
    @Published var refreshTick: Int = Int(Date().timeIntervalSince1970)

    private var fetchedAt: [CaltransDistrict: Date] = [:]
    private var usgsFetchedAt: Date?
    private var nycFetchedAt: Date?

    func bumpSnapshots() {
        refreshTick = Int(Date().timeIntervalSince1970)
    }

    var allLoadedCameras: [CaltransCamera] {
        usgsCameras + nycCameras + camerasByDistrict.values.flatMap { $0 }
    }

    func loadUSGS(force: Bool = false) async {
        if !force, let ts = usgsFetchedAt, Date().timeIntervalSince(ts) < 900, !usgsCameras.isEmpty { return }
        guard !loadingUSGS else { return }
        loadingUSGS = true
        defer { loadingUSGS = false }

        do {
            var req = URLRequest(url: URL(string: "https://api.waterdata.usgs.gov/nims/v0/cameras")!)
            req.timeoutInterval = 18
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let rows = try JSONDecoder().decode([USGSMediaCamera].self, from: data)
            usgsCameras = rows.compactMap { row in
                guard row.hideCam != true,
                      let camId = row.camId, !camId.isEmpty,
                      let lat = Double(row.lat ?? ""), let lon = Double(row.lng ?? ""),
                      let dir = row.smallDir ?? row.thumbDir, !dir.isEmpty,
                      let imgURL = URL(string: dir + camId + "_newest.jpg") else { return nil }
                return CaltransCamera(
                    id: "usgs-\(camId)",
                    source: .usgs,
                    district: 0,
                    name: row.camName ?? camId,
                    route: row.nwisId.map { "USGS \($0)" } ?? "USGS Gauge",
                    direction: row.stateAbrv ?? "",
                    county: row.stateAbrv ?? "",
                    latitude: lat,
                    longitude: lon,
                    imageURL: imgURL,
                    streamURL: URL(string: "https://apps.usgs.gov/hivis/camera/\(camId)"),
                    inService: true
                )
            }
            usgsFetchedAt = Date()
        } catch {
            // Non-fatal: other camera feeds remain available.
        }
    }

    func loadNYCDOT(force: Bool = false) async {
        if !force, let ts = nycFetchedAt, Date().timeIntervalSince(ts) < 600, !nycCameras.isEmpty { return }
        guard !loadingNYC else { return }
        loadingNYC = true
        defer { loadingNYC = false }

        do {
            var req = URLRequest(url: URL(string: "https://webcams.nyctmc.org/api/cameras")!)
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let rows = try JSONDecoder().decode([NYCDOTCameraRow].self, from: data)
            nycCameras = rows.compactMap { row in
                guard row.isOnline?.lowercased() == "true",
                      let lat = row.latitude, let lon = row.longitude,
                      let imgStr = row.imageUrl, let imgURL = URL(string: imgStr) else { return nil }
                return CaltransCamera(
                    id: "nyc-\(row.id)",
                    source: .nycDot,
                    district: 0,
                    name: row.name ?? "NYC Camera",
                    route: "NYC DOT",
                    direction: "",
                    county: row.area ?? "NYC",
                    latitude: lat,
                    longitude: lon,
                    imageURL: imgURL,
                    streamURL: nil,
                    inService: true
                )
            }
            nycFetchedAt = Date()
        } catch {
            // Non-fatal
        }
    }

    func load(district: CaltransDistrict, force: Bool = false) async {
        if !force, let ts = fetchedAt[district], Date().timeIntervalSince(ts) < 600,
           !(camerasByDistrict[district]?.isEmpty ?? true) {
            return
        }
        guard !loadingDistricts.contains(district) else { return }
        loadingDistricts.insert(district)
        lastError = nil
        defer { loadingDistricts.remove(district) }

        do {
            var req = URLRequest(url: district.feedURL)
            req.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                lastError = "Caltrans \(district.shortLabel) feed returned HTTP \(http.statusCode)."
                return
            }
            let decoded = try JSONDecoder().decode(CaltransFeedEnvelope.self, from: data)
            let parsed: [CaltransCamera] = decoded.data.compactMap { row in
                let c = row.cctv
                guard c.inService?.lowercased() == "true",
                      let lat = Double(c.location.latitude ?? ""),
                      let lon = Double(c.location.longitude ?? ""),
                      let imgStr = c.imageData?.staticData?.currentImageURL,
                      !imgStr.isEmpty,
                      let imgURL = URL(string: imgStr) else { return nil }
                let streamURL = c.imageData?.streamingVideoURL.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                let index = c.index ?? "\(lat),\(lon)"
                return CaltransCamera(
                    id: "d\(district.rawValue)-\(index)",
                    source: .caltrans,
                    district: district.rawValue,
                    name: c.location.locationName ?? "Caltrans Camera",
                    route: c.location.route ?? "",
                    direction: c.location.direction ?? "",
                    county: c.location.county ?? "",
                    latitude: lat,
                    longitude: lon,
                    imageURL: imgURL,
                    streamURL: streamURL,
                    inService: true
                )
            }
            camerasByDistrict[district] = parsed
            fetchedAt[district] = Date()
            bumpSnapshots()
        } catch {
            lastError = "Could not load Caltrans \(district.shortLabel) cameras."
        }
    }

    /// Nearest cameras across all loaded public feeds (USGS nationwide + Caltrans + NYC DOT).
    func nearestCameras(to coord: CLLocationCoordinate2D, limit: Int = 24) -> [CaltransCamera] {
        return Array(allLoadedCameras.sorted { $0.distanceMeters(from: coord) < $1.distanceMeters(from: coord) }.prefix(limit))
    }

    func ensureLoaded(near coord: CLLocationCoordinate2D) async {
        async let u: Void = loadUSGS()
        if let dist = CaltransDistrict.nearest(to: coord) {
            async let c: Void = load(district: dist)
            _ = await (u, c)
        } else if coord.latitude > 40.4 && coord.latitude < 41.0 && coord.longitude > -74.4 && coord.longitude < -73.6 {
            async let n: Void = loadNYCDOT()
            _ = await (u, n)
        } else {
            _ = await u
        }
    }
}

// MARK: - Feed JSON schemas

private struct USGSMediaCamera: Decodable {
    let camId: String?
    let nwisId: String?
    let camName: String?
    let lat: String?
    let lng: String?
    let stateAbrv: String?
    let hideCam: Bool?
    let smallDir: String?
    let thumbDir: String?
}

private struct NYCDOTCameraRow: Decodable {
    let id: String
    let name: String?
    let latitude: Double?
    let longitude: Double?
    let area: String?
    let isOnline: String?
    let imageUrl: String?
}

private struct CaltransFeedEnvelope: Decodable {
    let data: [CaltransFeedRow]
}

private struct CaltransFeedRow: Decodable {
    let cctv: CaltransFeedItem
}

private struct CaltransFeedItem: Decodable {
    let index: String?
    let inService: String?
    let location: CaltransFeedLocation
    let imageData: CaltransFeedImageData?
}

private struct CaltransFeedLocation: Decodable {
    let locationName: String?
    let route: String?
    let direction: String?
    let county: String?
    let latitude: String?
    let longitude: String?
}

private struct CaltransFeedImageData: Decodable {
    let streamingVideoURL: String?
    let staticData: CaltransFeedStatic?

    enum CodingKeys: String, CodingKey {
        case streamingVideoURL
        case staticData = "static"
    }
}

private struct CaltransFeedStatic: Decodable {
    let currentImageURL: String?
}
