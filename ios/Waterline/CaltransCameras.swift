import Foundation
import CoreLocation
import SwiftUI

/// Official Caltrans CWWP2 live CCTV camera feed (public domain, no API key).
/// Docs: https://cwwp2.dot.ca.gov/documentation/cctv/cctv.htm
struct CaltransCamera: Identifiable, Hashable {
    let id: String
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
        let s = (name + " " + route).lowercased()
        let tokens = [
            "bridge", "river", "creek", "bay", "causeway", "coast", "beach",
            "embarcadero", "marina", "harbor", "pier", "slough", "delta",
            "levee", "channel", "pocket", "natomas", "dumbarton", "san mateo",
            "golden gate", "bayshore", "tunnel", "underpass", "101", "80", "5"
        ]
        return tokens.contains(where: { s.contains($0) })
    }

    func imageURL(cacheBust: Int) -> URL {
        var comps = URLComponents(url: imageURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "t", value: String(cacheBust))]
        return comps?.url ?? imageURL
    }

    func distanceMeters(from origin: CLLocationCoordinate2D) -> Double {
        Geo.distance(origin, coordinate)
    }
}

enum CaltransDistrict: Int, CaseIterable, Identifiable {
    case d4 = 4   // SF Bay Area
    case d3 = 3   // Sacramento / Valley / Sierra
    case d5 = 5   // Central Coast
    case d7 = 7   // Los Angeles
    case d12 = 12 // Orange County
    case d11 = 11 // San Diego

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .d4: return "SF Bay Area (D4)"
        case .d3: return "Sacramento & Rivers (D3)"
        case .d5: return "Central Coast (D5)"
        case .d7: return "Los Angeles (D7)"
        case .d12: return "Orange County (D12)"
        case .d11: return "San Diego (D11)"
        }
    }

    var shortLabel: String {
        switch self {
        case .d4: return "SF Bay"
        case .d3: return "Sacramento"
        case .d5: return "Central Coast"
        case .d7: return "LA"
        case .d12: return "OC"
        case .d11: return "San Diego"
        }
    }

    var center: CLLocationCoordinate2D {
        switch self {
        case .d4: return CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        case .d3: return CLLocationCoordinate2D(latitude: 38.5816, longitude: -121.4944)
        case .d5: return CLLocationCoordinate2D(latitude: 36.6002, longitude: -121.8947)
        case .d7: return CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        case .d12: return CLLocationCoordinate2D(latitude: 33.7175, longitude: -117.8311)
        case .d11: return CLLocationCoordinate2D(latitude: 32.7157, longitude: -117.1611)
        }
    }

    var feedURL: URL {
        let code = String(format: "D%02d", rawValue)
        return URL(string: "https://cwwp2.dot.ca.gov/data/d\(rawValue)/cctv/cctvStatus\(code).json")!
    }

    /// Nearest district if inside California (~160 km), else nil.
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
    @Published var loadingDistricts: Set<CaltransDistrict> = []
    @Published var lastError: String?
    @Published var refreshTick: Int = Int(Date().timeIntervalSince1970)

    private var fetchedAt: [CaltransDistrict: Date] = [:]

    func bumpSnapshots() {
        refreshTick = Int(Date().timeIntervalSince1970)
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

    /// Nearest cameras across already-loaded districts (or the nearest district).
    func nearestCameras(to coord: CLLocationCoordinate2D, limit: Int = 24) -> [CaltransCamera] {
        let all = camerasByDistrict.values.flatMap { $0 }
        return Array(all.sorted { $0.distanceMeters(from: coord) < $1.distanceMeters(from: coord) }.prefix(limit))
    }

    func ensureLoaded(near coord: CLLocationCoordinate2D) async {
        let dist = CaltransDistrict.nearest(to: coord) ?? .d4
        await load(district: dist)
    }
}

// MARK: - Caltrans CWWP2 JSON schema

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
