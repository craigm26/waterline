import SwiftUI

@main
struct WaterlineApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            TabView(selection: $model.tab) {
                HereView().tabItem { Label("Here", systemImage: "location.fill") }.tag(AppModel.Tab.here)
                CityMapView().tabItem { Label("Map", systemImage: "map") }.tag(AppModel.Tab.map)
                ARTab().tabItem { Label("Water line", systemImage: "camera.viewfinder") }.tag(AppModel.Tab.ar)
            }
            .environmentObject(model)
            .task { model.start() }
        }
    }
}
