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
            TabView(selection: $model.tab) {
                HereView().tabItem { Label("Here", systemImage: "location.fill") }.tag(AppModel.Tab.here)
                CityMapView().tabItem { Label("Map", systemImage: "map") }.tag(AppModel.Tab.map)
                #if os(iOS)
                // Macs run the iPhone app without world tracking: they get Here and Map.
                if WaterlineApp.hasAR {
                    ARTab().tabItem { Label("Water line", systemImage: "camera.viewfinder") }.tag(AppModel.Tab.ar)
                }
                #elseif os(visionOS)
                RoomTab().tabItem { Label("In your room", systemImage: "visionpro") }.tag(AppModel.Tab.ar)
                #endif
            }
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
