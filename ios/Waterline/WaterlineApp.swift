import SwiftUI
import ARKit

@main
struct WaterlineApp: App {
    @StateObject private var model = AppModel()
    static let hasAR = ARWorldTrackingConfiguration.isSupported

    var body: some Scene {
        WindowGroup {
            TabView(selection: $model.tab) {
                HereView().tabItem { Label("Here", systemImage: "location.fill") }.tag(AppModel.Tab.here)
                CityMapView().tabItem { Label("Map", systemImage: "map") }.tag(AppModel.Tab.map)
                // Vision Pro and Macs run the iPhone app without world tracking: they get Here and Map.
                if WaterlineApp.hasAR {
                    ARTab().tabItem { Label("Water line", systemImage: "camera.viewfinder") }.tag(AppModel.Tab.ar)
                }
            }
            .environmentObject(model)
            .task { model.start() }
        }
    }
}
