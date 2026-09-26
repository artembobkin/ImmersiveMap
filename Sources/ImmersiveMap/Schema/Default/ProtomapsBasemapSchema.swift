// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The reading of the Protomaps basemap schema (tiles version 4): the
/// `roads` layer's structure flags, names and route references, the
/// `buildings` layer's heights and house numbers, the names of `places`,
/// `pois` and the water label points of `water`. A
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
    public var cacheFingerprint: UInt32 { 2 }

    public init() {}

    /// The basemap's feature id is the OSM element: the element type in the
    /// bits from 44 up (1 node, 2 way, 3 relation) and the OSM id below.
    /// A building and a point made from the same element share it.
    public func tileFeatureID(of element: ImmersiveMapOSMElement) -> UInt64? {
        let osmIDLimit: UInt64 = 1 << 44
        switch element {
        case .node(let id):
            return id < osmIDLimit ? 1 << 44 | id : nil
        case .way(let id):
            return id < osmIDLimit ? 2 << 44 | id : nil
        case .relation(let id):
            return id < osmIDLimit ? 3 << 44 | id : nil
        }
    }

    public func read(_ feature: ImmersiveMapFeature) -> ImmersiveMapFeatureFacts {
        let properties = feature.properties
        switch feature.layerName.lowercased() {
        case "roads":
            // The basemap ships roads as lines only. A polygon under the
            // layer name is not a road the engine can stitch or sort.
            guard feature.geometry != .polygon else {
                return .none
            }
            return .road(road(properties))
        case "buildings":
            // The address points (`kind=address`) of z15 carry a house
            // number and no footprint: a label with the number as its text.
            if feature.geometry == .point {
                return houseNumber(properties).map { .labelled($0) } ?? .none
            }
            guard properties.string("kind") != "address" else {
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
