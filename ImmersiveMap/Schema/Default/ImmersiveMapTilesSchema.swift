// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The reading of the hosted tiles' schema, the layer and field contract of
/// `immersivemap.dev`: the OpenStreetMap-derived tags of the
/// `transportation` layer and the measured `streetscape` folded into it,
/// the `building` layer's heights, the `water_name` labels. A source in
/// another OpenStreetMap-derived schema can start from it.
public struct ImmersiveMapTilesSchema: ImmersiveMapTileSchema {
    /// Bumped when the reading changes: every prepared tile is prepared
    /// again under the new reading.
    public var cacheFingerprint: UInt32 { 1 }

    /// The hosted tiles ship the roads in `transportation`, the road names
    /// in `transportation_name`, and the streetscape as `streetscape`.
    public var roadLayerNames: Set<String> { ["transportation"] }
    public var streetscapeLayerName: String? { "streetscape" }
    public var houseNumberLayers: Set<String> { ["housenumber"] }

    public init() {}

    public func read(_ feature: ImmersiveMapFeature) -> ImmersiveMapFeatureFacts {
        switch feature.layerName.lowercased() {
        case "transportation", "streetscape", "transportation_name":
            return ImmersiveMapFeatureFacts(road: roadFacts(feature))
        case "building":
            return ImmersiveMapFeatureFacts(building: .openStreetMap(feature.properties))
        case "water_name":
            return ImmersiveMapFeatureFacts(namesWaterBody: true)
        default:
            return .none
        }
    }

    /// Every road feature carries where it sits and which street it is a
    /// piece of; a line also carries its stitching key, which a surface
    /// never needs. What kind of road thing it is comes from `marking` (a
    /// line of measured paint), `subclass` (a junction or carriageway
    /// surface, a parking lot) and `origin` (a surface reconstructed from
    /// the road graph rather than mapped by hand).
    private func roadFacts(_ feature: ImmersiveMapFeature) -> ImmersiveMapRoadFacts {
        let properties = feature.properties
        var road = ImmersiveMapRoadFacts.openStreetMap(properties)
        if feature.geometry == .polygon {
            road.stitchingKey = nil
        }
        if let marking = properties.string("marking")?.lowercased(), marking.isEmpty == false {
            road.kind = .paint
            return road
        }
        switch properties.string("subclass")?.lowercased() {
        case "junction_area":
            road.kind = .surface(reconstructed: properties.string("origin") == "graph")
        case "carriageway_area":
            road.kind = .surface(reconstructed: true)
        case "parking_area":
            road.kind = .parkingLot(baysParallel: properties.string("orientation") == "parallel")
        default:
            break
        }
        return road
    }
}
