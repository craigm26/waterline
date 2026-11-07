import SwiftUI
import MapKit

/// Tap anywhere to check that spot. Shows whatever this place has: drains, past 311 flooding
/// reports, low spots, the flood zone outline, levees, floodwalls and pump stations. SF's layers
/// are bundled; elsewhere they come from a downloaded pack or live from FEMA and USACE.
struct CityMapView: View {
    @EnvironmentObject var model: AppModel
    @State private var camera: MapCameraPosition = .userLocation(fallback: .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12))))
    @State private var center = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    @State private var spanDeg = 0.12

    @State private var places: Places? = Places.shared
    /// Rings and levees in view, capped so a coastal city's thousands of polygons don't stall the map.
    private var visibleRings: [[[Double]]] {
        guard let p = places else { return [] }
        if p.isSF { return p.zone_rings }
        guard spanDeg < 0.5 else { return [] }
        return Array(p.zone_rings.filter { $0.contains(where: inView) }.prefix(250))
    }
    private var visibleLevees: [Places.Line] {
        guard spanDeg < 0.8 else { return [] }
        return Array((places?.levees ?? []).filter { $0.path.contains(where: inView) }.prefix(250))
    }
    private func inView(_ p: [Double]) -> Bool {
        abs(p[1] - center.latitude) < spanDeg && abs(p[0] - center.longitude) < spanDeg * 1.5
    }
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
                    let rings = visibleRings
                    ForEach(rings.indices, id: \.self) { i in
                        MapPolyline(coordinates: rings[i].map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) })
                            .stroke(.blue.opacity(0.7), lineWidth: 1.5)
                    }
                    let lines = visibleLevees
                    ForEach(lines.indices, id: \.self) { i in
                        MapPolyline(coordinates: lines[i].path.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) })
                            .stroke(lines[i].kind == "floodwall" ? .red : .brown, lineWidth: lines[i].kind == "floodwall" ? 3 : 2.5)
                    }
                    ForEach((places?.pumps ?? []).indices, id: \.self) { i in
                        Marker(places!.pumps![i].name, systemImage: "drop.degreesign", coordinate: places!.pumps![i].coordinate).tint(.teal)
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
                    Task { await refreshLayers() }
                }
                .onTapGesture(coordinateSpace: .local) { pt in
                    if let c = proxy.convert(pt, from: .local) { model.pin(c) }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomCard }
            .task { await refreshLayers() }
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
                Text(legend)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal).padding(.bottom, 6)
    }

    /// Only names what this place actually has.
    private var legend: String {
        guard let p = places else { return "Move the map to load this area's flood layers." }
        if p.isSF, !detail { return "Zoom in to see drains and past 311 flooding reports." }
        var parts: [String] = []
        if detail, !p.drains.isEmpty { parts.append(p.isSF ? "● drain (red = top 100 citywide)" : "● storm drain") }
        if detail, p.flood311_total > 0 { parts.append("purple = \(p.reportsLabel.lowercased())") }
        if !p.zone_rings.isEmpty { parts.append("blue line = \(p.zoneLabel)") }
        if !(p.levees ?? []).isEmpty { parts.append("brown = levee, red = floodwall") }
        return parts.joined(separator: " · ")
    }

    /// Layers for the map's centre: a pack if there is one, otherwise a live fetch at city zoom.
    private func refreshLayers() async {
        let c = center
        var p = await Task.detached(priority: .utility) { Places.covering(c) }.value
        if p == nil || p?.region == "live", spanDeg < 0.5 { p = await LiveLayers.load(near: c) ?? p }
        if detail, !Places.inSF(c), let base = p {     // city feeds are street-level, so only when zoomed in
            await LiveLayers.loadCity(near: c)
            p = LiveLayers.withCity(base, near: c)
        }
        places = p
    }

    private func drainColor(_ d: Places.Drain) -> Color {
        if !d.ranked { return .cyan }
        if d.deep_pit { return .gray }
        return d.rank <= 100 ? .red : d.rank <= 300 ? .orange : .yellow
    }
}
