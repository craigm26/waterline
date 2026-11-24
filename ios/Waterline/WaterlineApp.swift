import SwiftUI
#if os(iOS)
import ARKit
#endif

@main
struct WaterlineApp: App {
    @StateObject private var model = AppModel()
    #if os(iOS)
    static let hasAR = ARWorldTrackingConfiguration.isSupported
    #else
    static let hasAR = false
    #endif
    /// A place to see the water at full size: the iPhone camera, or the room on Vision Pro.
    static var hasWaterView: Bool {
        #if os(visionOS)
        return true
        #else
        return hasAR
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootShellView()
                .environmentObject(model)
                .task { model.start() }
        }
        #if os(visionOS)
        ImmersiveSpace(id: RoomFlood.spaceID) {
            RoomFlood().environmentObject(model)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        #endif
    }
}

/// Adaptive root shell: native NavigationSplitView sidebar on iPad / regular
/// width, and a clean 4-tab bar on iPhone.
private struct RootShellView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        #if os(iOS)
        if sizeClass == .regular {
            NavigationSplitView {
                List(selection: Binding<AppModel.Tab?>(
                    get: { model.tab },
                    set: { if let v = $0 { model.tab = v } }
                )) {
                    Section("Views") {
                        Label("Dashboard", systemImage: "gauge.with.dots.needle.33percent").tag(AppModel.Tab.here)
                        Label("Map", systemImage: "map").tag(AppModel.Tab.map)
                        Label("Live Cameras", systemImage: "video.fill").tag(AppModel.Tab.cameras)
                        if WaterlineApp.hasAR {
                            Label("Water line (AR)", systemImage: "camera.viewfinder").tag(AppModel.Tab.ar)
                        }
                    }
                    Section("Quick spots") {
                        Button {
                            model.unpin()
                        } label: {
                            Label("My location", systemImage: "location.fill")
                        }
                        ForEach(AppModel.quickPlaces) { place in
                            Button {
                                model.pin(place.coordinate)
                            } label: {
                                Label(place.name, systemImage: "mappin.circle")
                            }
                        }
                    }
                }
                .navigationTitle("Waterline")
            } detail: {
                switch model.tab {
                case .here: HereView()
                case .map: CityMapView()
                case .cameras: LiveCamerasView()
                case .ar:
                    if WaterlineApp.hasAR { ARTab() } else { HereView() }
                }
            }
        } else {
            compactTabs
        }
        #else
        compactTabs
        #endif
    }

    private var compactTabs: some View {
        TabView(selection: $model.tab) {
            HereView().tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.33percent") }.tag(AppModel.Tab.here)
            CityMapView().tabItem { Label("Map", systemImage: "map") }.tag(AppModel.Tab.map)
            LiveCamerasView().tabItem { Label("Cameras", systemImage: "video.fill") }.tag(AppModel.Tab.cameras)
            #if os(iOS)
            if WaterlineApp.hasAR {
                ARTab().tabItem { Label("Water line", systemImage: "camera.viewfinder") }.tag(AppModel.Tab.ar)
            }
            #elseif os(visionOS)
            RoomTab().tabItem { Label("In your room", systemImage: "visionpro") }.tag(AppModel.Tab.ar)
            #endif
        }
    }
}
