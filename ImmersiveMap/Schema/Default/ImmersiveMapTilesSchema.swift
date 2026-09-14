// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The reading of the hosted tiles' schema, the layer and field contract of
/// `immersivemap.dev`: the OpenStreetMap-derived tags of the
/// `transportation` layer and the measured `streetscape` that merges into
/// it, the `building` layer's heights, the names of `place`, `poi`,
/// `water_name` and the rest, the `housenumber` layer's numbers. A source
/// in another OpenStreetMap-derived schema can start from it.
public struct ImmersiveMapTilesSchema: ImmersiveMapTileSchema {
    /// Bumped when the reading changes: every prepared tile is prepared
    /// again under the new reading.
    public var cacheFingerprint: UInt32 { 2 }

    public init() {}

    public func read(_ feature: ImmersiveMapFeature) -> ImmersiveMapFeatureFacts {
        let properties = feature.properties
        switch feature.layerName.lowercased() {
        case "transportation", "streetscape":
            var road = roadFacts(feature)
            road.label = .openStreetMap(properties)
            return .road(road)
        case "building":
            return .building(.openStreetMap(properties))
        case "water_name":
            var label = ImmersiveMapLabelFacts.openStreetMap(properties) ?? ImmersiveMapLabelFacts()
            label.namesWaterBody = true
            return .labelled(label)
        case "housenumber":
            guard let number = properties.string("house_num"), number.isEmpty == false else {
                return .none
            }
            return .labelled(ImmersiveMapLabelFacts(houseNumber: number))
        default:
            // Anything else is labelled by its name where it has one: the
            // places, the POIs, the peaks and airports, the road names.
            guard let label = ImmersiveMapLabelFacts.openStreetMap(properties) else {
                return .none
            }
            return .labelled(label)
        }
    }

    /// The measured paint: `marking` says what it marks, `paint` its colour
    /// and `style` whether it is dashed.
    private func paint(marking: String, _ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapRoadPaint {
        let kind: ImmersiveMapRoadPaint.Kind
        switch marking {
        case "crossing_marked": kind = .crossing(marked: true)
        case "crossing_unmarked": kind = .crossing(marked: false)
        case "dividing": kind = .dividingLine
        case "lane_separator": kind = .laneSeparator
        case "edge": kind = .edgeLine
        case "bus_lane": kind = .busLane
        case "bus_stop_zigzag": kind = .busStopKerb
        default: kind = .other(marking)
        }
        let dashed: Bool?
        switch properties.string("style")?.lowercased() {
        case "solid": dashed = false
        case "dashed": dashed = true
        default: dashed = nil
        }
        return ImmersiveMapRoadPaint(kind: kind,
                                     isYellow: properties.string("paint")?.lowercased() == "yellow",
                                     isDashed: dashed)
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
            road.kind = .paint(paint(marking: marking, properties))
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
