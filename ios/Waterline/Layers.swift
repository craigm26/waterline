import SwiftUI

/// One set of layer switches for every view: the Map, the 3D ground and lidar scenes, and the
/// camera. Turning a layer off anywhere turns it off everywhere (stored under "layersOff").
enum Layer: String, CaseIterable, Identifiable {
    case rainWater = "Rain water", rivers = "Rivers", tide = "Tide", floodZones = "Flood zones", levees = "Levees", pumps = "Pumps"
    case drains = "Drains", reports = "Reports", lowSpots = "Low spots", streetSensors = "Street sensors", higherGround = "Higher ground", lidar = "Lidar"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .rainWater: return "drop.fill"
        case .rivers: return "water.waves"
        case .tide: return "arrow.up.and.down.and.sparkles"
        case .floodZones: return "square.dashed"
        case .levees: return "line.diagonal"
        case .pumps: return "drop.degreesign"
        case .drains: return "circle.grid.cross"
        case .reports: return "exclamationmark.bubble"
        case .lowSpots: return "drop.triangle.fill"
        case .streetSensors: return "sensor.fill"
        case .higherGround: return "figure.walk.motion"
        case .lidar: return "cube.transparent"
        }
    }

    /// What the layer shows, for the menu.
    var detail: String {
        switch self {
        case .rainWater: return "Where rain would stand, from the storm you pick"
        case .rivers: return "River gauges, stream and reservoir sensors"
        case .tide: return "The nearest tide station"
        case .floodZones: return "FEMA or city 100-year flood zone outlines"
        case .levees: return "Levees and floodwalls"
        case .pumps: return "Pump stations behind levees"
        case .drains: return "Storm drain inlets"
        case .reports: return "Past flooding reports and drain requests"
        case .lowSpots: return "Dips in the ground where water collects"
        case .streetSensors: return "Street flood sensors"
        case .higherGround: return "The nearest ground that stays dry"
        case .lidar: return "Lidar scenes on this phone"
        }
    }

    static let storageKey = "layersOff"
    /// Rain water is computed for the view, so it starts off.
    static let defaultOff = "Rain water"
    static func off(_ raw: String) -> Set<Layer> { Set(raw.split(separator: ",").compactMap { Layer(rawValue: String($0)) }) }
    static func raw(_ s: Set<Layer>) -> String { s.map(\.rawValue).sorted().joined(separator: ",") }
}

/// The switches, as a toolbar menu. `only` limits it to the layers a view can draw.
struct LayerMenu: View {
    @AppStorage(Layer.storageKey) private var offRaw = Layer.defaultOff
    var only: [Layer] = Layer.allCases
    var body: some View {
        Menu {
            ForEach(only) { l in
                Toggle(isOn: Binding(get: { !Layer.off(offRaw).contains(l) }, set: { on in
                    var s = Layer.off(offRaw)
                    if on { s.remove(l) } else { s.insert(l) }
                    offRaw = Layer.raw(s)
                })) { Label { Text(l.rawValue); Text(l.detail) } icon: { Image(systemName: l.icon) } }
            }
            Divider()
            Button("Show all") { offRaw = "" }
        } label: {
            Label("Layers", systemImage: "square.3.layers.3d")
        }
        .menuActionDismissBehavior(.disabled)
    }
}

extension View {
    /// Reads the shared switches.
    func layerIsOn(_ l: Layer, _ raw: String) -> Bool { !Layer.off(raw).contains(l) }
}
