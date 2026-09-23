// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The reading of the Protomaps basemap schema (tiles version 4): the
/// `roads` layer's structure flags, the `buildings` layer's heights, the
/// names of `places`, `pois` and the water label points of `water`. A
/// source that spells its tags the same way can use it as it is.
///
/// Every other layer of the basemap (`earth`, `landcover`, `landuse`,
/// `boundaries`, `transit`, the water fills and the river lines) is none
/// of the things the facts describe: the style draws them from their
/// properties alone. A layer the basemap does not ship reads as nothing
/// too, so a future layer is opted in here rather than labelled by
/// accident.
public struct ProtomapsBasemapSchema: ImmersiveMapTileSchema {
    /// Bumped when the reading changes: every prepared tile is prepared
    /// again under the new reading.
    public var cacheFingerprint: UInt32 { 1 }

    public init() {}

    public func read(_ feature: ImmersiveMapFeature) -> ImmersiveMapFeatureFacts {
        let properties = feature.properties
        switch feature.layerName.lowercased() {
        case "roads":
            // The basemap ships roads as lines only. A polygon under the
            // layer name is not a road the engine can stitch or sort.
            guard feature.geometry != .polygon else {
                return .none
            }
            var road = road(properties)
            road.label = names(properties)
            return .road(road)
        case "buildings":
            // The address points (`kind=address`) of z15 carry a house
            // number and no footprint: nothing the engine raises or labels.
            guard feature.geometry != .point, properties.string("kind") != "address" else {
                return .none
            }
            return .building(building(properties))
        case "water":
            // A named body of water arrives twice: as its fill and, from
            // the zoom its area earns, as one point carrying the name. The
            // point is the label; the fill and the river lines are called
            // nothing, so the name is never laid twice.
            guard feature.geometry != .polygon, feature.geometry != .line,
                  var label = names(properties) else {
                return .none
            }
            label.namesWaterBody = true
            return .labelled(label)
        case "places", "pois":
            guard let label = names(properties) else {
                return .none
            }
            return .labelled(label)
        default:
            return .none
        }
    }
}
