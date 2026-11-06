import SwiftUI
import MapKit

/// Tap anywhere to check that spot. Shows the drains that matter, past 311 flooding reports,
/// the 50 worst street low spots and the SFPUC 100-year flood zone (outline).
struct CityMapView: View {
    @EnvironmentObject var model: AppModel
    @State private var camera: MapCameraPosition = .userLocation(fallback: .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12))))
    @State private var center = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    @State private var spanDeg = 0.12

    private var places: Places? { Places.shared }
    /// Detail layers only when zoomed in enough to read them.
    private var detail: Bool { spanDeg < 0.03 }
    private var nearDrains: [NearDrain] {
        guard detail, let p = places else { return [] }
        return p.drains(near: center, within: 1200, limit: 80).map { NearDrain(drain: $0.0, metres: $0.1) }
    }
    private var near311: [CLLocationCoordinate2D] {
        guard detail, let p = places else { return [] }
        return Array(p.flood311Points(near: center, within: 700).prefix(600))
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    if let rings = places?.zone_rings {
                        ForEach(rings.indices, id: \.self) { i in
                            MapPolyline(coordinates: rings[i].map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) })
                                .stroke(.blue.opacity(0.7), lineWidth: 1.5)
                        }
                    }
                    ForEach(near311.indices, id: \.self) { i in
                        MapCircle(center: near311[i], radius: 5).foregroundStyle(.purple.opacity(0.45))
                    }
                    ForEach(nearDrains) { n in
                        Annotation("", coordinate: n.drain.coordinate) {
                            Circle().fill(drainColor(n.drain)).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        }
                    }
                    ForEach(places?.hotspots ?? []) { s in
                        Marker("#\(s.rank) \(s.name)", systemImage: "drop.triangle.fill", coordinate: s.coordinate).tint(.orange)
                    }
                    if let p = model.pinned {
                        Marker("Checking here", systemImage: "mappin", coordinate: p).tint(.red)
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .onMapCameraChange(frequency: .onEnd) { ctx in
                    center = ctx.region.center
                    spanDeg = ctx.region.span.latitudeDelta
                }
                .onTapGesture(coordinateSpace: .local) { pt in
                    if let c = proxy.convert(pt, from: .local) { model.pin(c) }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomCard }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = model.report, model.usingPin {
                Text(r.placeLabel ?? "Pinned spot").font(.subheadline.bold())
                Text(r.title).font(.headline).foregroundStyle(r.level == .high ? .red : r.level == .watch ? .orange : .green)
                if let f = r.findings.first { Text(f).font(.caption).lineLimit(3) }
                HStack {
                    Button("Details") { model.tab = .here }.buttonStyle(.borderedProminent)
                    Button("Back to my location") { model.unpin() }
                }
            } else if model.loading {
                ProgressView("Checking that spot…")
            } else {
                Text("Tap anywhere to check that spot.").font(.subheadline)
                Text(detail ? "● drain (red = top 100 citywide) · purple = past 311 flooding report · blue line = SFPUC 100-yr flood zone"
                            : "Zoom in to see drains and past 311 flooding reports.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal).padding(.bottom, 6)
    }

    private func drainColor(_ d: Places.Drain) -> Color {
        if d.deep_pit { return .gray }
        return d.rank <= 100 ? .red : d.rank <= 300 ? .orange : .yellow
    }
}
