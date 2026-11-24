import SwiftUI
import CoreLocation

/// Live verification camera wall: Caltrans CWWP2 highway, bridge, river, and
/// coastal cameras for visual ground-truth verification on iPhone and iPad.
struct LiveCamerasView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = CaltransCameraStore.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var selectedDistrict: CaltransDistrict = .d4
    @State private var filterWaterCorridors = false
    @State private var searchText = ""
    @State private var autoRefresh = true
    @State private var selectedCamera: CaltransCamera?

    private var origin: CLLocationCoordinate2D {
        model.target ?? selectedDistrict.center
    }

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var visibleCameras: [CaltransCamera] {
        let base = store.camerasByDistrict[selectedDistrict] ?? []
        let filtered = base.filter { cam in
            if filterWaterCorridors && !cam.isWaterCorridor { return false }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                let hay = "\(cam.name) \(cam.route) \(cam.county)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
        return Array(filtered.sorted { $0.distanceMeters(from: origin) < $1.distanceMeters(from: origin) }.prefix(36))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    controlBar
                    if let err = store.lastError {
                        Text(err).font(.caption).foregroundStyle(.orange)
                    }
                    if store.loadingDistricts.contains(selectedDistrict) && visibleCameras.isEmpty {
                        ProgressView("Loading live Caltrans cameras…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if visibleCameras.isEmpty {
                        ContentUnavailableView(
                            "No cameras match",
                            systemImage: "video.slash",
                            description: Text("Try clearing the search filter or switching Caltrans districts.")
                        )
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(visibleCameras) { cam in
                                Button {
                                    selectedCamera = cam
                                } label: {
                                    CameraTile(
                                        camera: cam,
                                        origin: origin,
                                        refreshTick: store.refreshTick
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Text("Live official snapshots from Caltrans CWWP2 (cwwp2.dot.ca.gov). Tap any camera to zoom, watch its live stream, or check Waterline flood screening at that exact spot.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                .padding()
            }
            .navigationTitle("Live Cameras")
            .searchable(text: $searchText, prompt: "Highway, bridge, river, or city")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        store.bumpSnapshots()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh camera frames")
                }
            }
            .task {
                if let target = model.target, let nearest = CaltransDistrict.nearest(to: target) {
                    selectedDistrict = nearest
                }
                await store.load(district: selectedDistrict)
            }
            .onChange(of: selectedDistrict) { _, next in
                Task { await store.load(district: next) }
            }
            .task(id: autoRefresh) {
                guard autoRefresh else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    store.bumpSnapshots()
                }
            }
            .sheet(item: $selectedCamera) { cam in
                CameraDetailSheet(camera: cam, origin: origin)
                    .environmentObject(model)
            }
        }
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CaltransDistrict.allCases) { dist in
                        Button {
                            selectedDistrict = dist
                        } label: {
                            Text(dist.shortLabel)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedDistrict == dist ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                                .foregroundStyle(selectedDistrict == dist ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 12) {
                Toggle("Water & bridges", isOn: $filterWaterCorridors)
                    .toggleStyle(.button)
                    .controlSize(.small)
                Toggle("Auto-refresh 60s", isOn: $autoRefresh)
                    .toggleStyle(.button)
                    .controlSize(.small)
                Spacer()
                Text("\(visibleCameras.count) live")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CameraTile: View {
    let camera: CaltransCamera
    let origin: CLLocationCoordinate2D
    let refreshTick: Int

    private var distanceMiles: String {
        let mi = camera.distanceMeters(from: origin) / 1609.34
        return mi < 10 ? String(format: "%.1f mi", mi) : String(format: "%.0f mi", mi)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: camera.imageURL(cacheBust: refreshTick)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        ZStack {
                            Color(.tertiarySystemFill)
                            Image(systemName: "video.slash").foregroundStyle(.secondary)
                        }
                    default:
                        ZStack {
                            Color(.tertiarySystemFill)
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .frame(height: 112)
                .frame(maxWidth: .infinity)
                .clipped()

                Text(distanceMiles)
                    .font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    if !camera.route.isEmpty {
                        Text(camera.route)
                            .font(.caption2.bold())
                            .foregroundStyle(.blue)
                    }
                    if !camera.direction.isEmpty {
                        Text(camera.direction)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if camera.streamURL != nil {
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4)))
    }
}

struct CameraDetailSheet: View {
    let camera: CaltransCamera
    let origin: CLLocationCoordinate2D
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = CaltransCameraStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AsyncImage(url: camera.imageURL(cacheBust: store.refreshTick)) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                        case .failure:
                            ContentUnavailableView("Snapshot unavailable", systemImage: "video.slash")
                                .frame(height: 220)
                        default:
                            ProgressView().frame(maxWidth: .infinity, minHeight: 220)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(camera.name).font(.title3.bold())
                        HStack(spacing: 10) {
                            if !camera.route.isEmpty { Label(camera.route, systemImage: "road.lanes") }
                            if !camera.county.isEmpty { Label(camera.county, systemImage: "mappin.and.ellipse") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            model.pin(camera.coordinate)
                            model.tab = .here
                            dismiss()
                        } label: {
                            Label("Check Waterline here", systemImage: "drop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            store.bumpSnapshots()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let stream = camera.streamURL {
                        Link(destination: stream) {
                            Label("Open live Caltrans video stream", systemImage: "play.rectangle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Text(String(format: "Coordinates: %.5f, %.5f · Source: Caltrans CWWP2 (Official)", camera.latitude, camera.longitude))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Live Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
