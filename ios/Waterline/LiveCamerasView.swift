import SwiftUI
import CoreLocation

/// Live verification camera wall across USGS HIVIS (nationwide river gauges),
/// all 12 Caltrans Districts (CA), and NYC DOT (NYC), with automatic on-device
/// Vision face blurring on every snapshot.
struct LiveCamerasView: View {
    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "All nearby"
        case usgs = "USGS Rivers"
        case caltrans = "Caltrans CA"
        case alertCA = "AlertCA"
        case nyc = "NYC DOT"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = CaltransCameraStore.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var sourceFilter: SourceFilter = .all
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
        let base: [CaltransCamera]
        switch sourceFilter {
        case .all:
            base = store.allLoadedCameras
        case .usgs:
            base = store.usgsCameras
        case .caltrans:
            base = store.camerasByDistrict[selectedDistrict] ?? []
        case .alertCA:
            base = store.alertCACameras
        case .nyc:
            base = store.nycCameras
        }

        let filtered = base.filter { cam in
            if filterWaterCorridors && !cam.isWaterCorridor { return false }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                let hay = "\(cam.name) \(cam.route) \(cam.county) \(cam.source.rawValue)".lowercased()
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
                    if visibleCameras.isEmpty && (store.loadingUSGS || store.loadingNYC || !store.loadingDistricts.isEmpty) {
                        ProgressView("Loading live public cameras…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if visibleCameras.isEmpty {
                        ContentUnavailableView(
                            "No cameras match",
                            systemImage: "video.slash",
                            description: Text("Try clearing the search filter or choosing another feed.")
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
                    Label("Automatic on-device face blur is active on every snapshot (Apple Vision). Sources: USGS HIVIS (nationwide rivers), Caltrans CWWP2 (all 12 CA districts), and NYC DOT.", systemImage: "eye.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                .padding()
            }
            .navigationTitle("Live Cameras")
            .searchable(text: $searchText, prompt: "River, bridge, highway, or city")
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
                await store.ensureLoaded(near: origin)
            }
            .onChange(of: sourceFilter) { _, next in
                Task {
                    switch next {
                    case .all: await store.ensureLoaded(near: origin)
                    case .usgs: await store.loadUSGS()
                    case .caltrans: await store.load(district: selectedDistrict)
                    case .alertCA: await store.loadAlertCA()
                    case .nyc: await store.loadNYCDOT()
                    }
                }
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
                    ForEach(SourceFilter.allCases) { f in
                        Button {
                            sourceFilter = f
                        } label: {
                            Text(f.rawValue)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(sourceFilter == f ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                                .foregroundStyle(sourceFilter == f ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if sourceFilter == .caltrans {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(CaltransDistrict.allCases) { dist in
                            Button {
                                selectedDistrict = dist
                            } label: {
                                Text(dist.shortLabel)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(selectedDistrict == dist ? Color.blue.opacity(0.2) : Color(.secondarySystemFill), in: Capsule())
                                    .foregroundStyle(selectedDistrict == dist ? .blue : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Toggle("Water & bridges", isOn: $filterWaterCorridors)
                    .toggleStyle(.button)
                    .controlSize(.small)
                Toggle("Auto 60s", isOn: $autoRefresh)
                    .toggleStyle(.button)
                    .controlSize(.small)
                Spacer()
                Label("Face blur on", systemImage: "eye.slash")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
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
                PrivacyBlurredCameraImage(url: camera.imageURL(cacheBust: refreshTick), contentMode: .fill)
                    .frame(height: 112)
                    .frame(maxWidth: .infinity)
                    .clipped()

                HStack(spacing: 4) {
                    Text(camera.source.rawValue)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(camera.source == .usgs ? Color.teal.opacity(0.85) : Color.blue.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                    Spacer()
                    Text(distanceMiles)
                        .font(.caption2.monospacedDigit().bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                }
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
                    PrivacyBlurredCameraImage(url: camera.imageURL(cacheBust: store.refreshTick), contentMode: .fit)
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(camera.name).font(.title3.bold())
                        HStack(spacing: 10) {
                            Label(camera.source.rawValue, systemImage: "video.fill")
                            if !camera.route.isEmpty { Label(camera.route, systemImage: "road.lanes") }
                            if !camera.county.isEmpty { Label(camera.county, systemImage: "mappin.and.ellipse") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Label("On-device face blurring applied automatically via Apple Vision", systemImage: "eye.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
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
                            Label(camera.source == .usgs ? "Open USGS HIVIS camera page" : "Open live video stream", systemImage: "play.rectangle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Text(String(format: "Coordinates: %.5f, %.5f · Source: %@ (Official)", camera.latitude, camera.longitude, camera.source.rawValue))
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
