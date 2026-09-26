// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A 3D model that takes the place of one of the map's own buildings: the
/// map stops extruding that building and draws the model where it stood.
///
/// The building is named by its OSM outline (`replacedBuilding`). The
/// outline is not extruded, and neither is any building part that stands
/// inside it, so a building mapped as an outline plus dozens of parts is
/// replaced by naming the outline alone. The footprint's flat ground fill
/// stays, under the model. Which tile feature the outline is, the map
/// style's schema answers (`ImmersiveMapTileSchema.tileFeatureID(of:)`). A
/// schema whose tiles carry no OSM ids replaces nothing and only adds the
/// model.
///
/// A landmark can hold back to a zoom (`minimumZoom`): below it the model is
/// not drawn and the map's own building stands in its place, so the model
/// shows only where it reads as more than a block. The swap is made per tile
/// zoom: from `minimumZoom` on the tiles leave the building out and the model
/// draws. A zoom deeper than the tileset's deepest tile zoom acts as that
/// zoom, since one deepest tile serves every camera zoom past it.
///
/// Landmarks are map configuration, set with `.landmarks(_:)` like the style:
/// a change to the set of replaced buildings prepares the tiles again, and
/// a change to a model alone applies in place. For models that move, animate
/// or answer taps, use `ImmersiveMapSceneModelsController`.
public struct ImmersiveMapLandmark: Identifiable, Equatable, Sendable {
    public var id: String
    /// The model: USDZ or OBJ, local file URL, Y-up meters with -Z north,
    /// like a scene model.
    public var model: ImmersiveMapSceneModel.Source
    /// Where the model's origin stands.
    public var coordinate: GeoCoordinate
    /// The map building the model replaces, by its OSM outline.
    public var replacedBuilding: ImmersiveMapOSMElement
    /// Rotation about the local up axis, clockwise from north, in degrees.
    public var headingDegrees: Double
    /// Multiplier over the asset's meters.
    public var scale: Double
    /// The camera zoom the model shows from, the map's building standing in
    /// below it. Zero shows it at every zoom that draws buildings.
    public var minimumZoom: Int

    public init(id: String,
                model: ImmersiveMapSceneModel.Source,
                coordinate: GeoCoordinate,
                replacedBuilding: ImmersiveMapOSMElement,
                headingDegrees: Double = 0,
                scale: Double = 1,
                minimumZoom: Int = 0) {
        self.id = id
        self.model = model
        self.coordinate = coordinate
        self.replacedBuilding = replacedBuilding
        self.headingDegrees = headingDegrees
        self.scale = scale
        self.minimumZoom = minimumZoom
    }

    /// The zoom the swap happens at for a tileset whose deepest tile zoom is
    /// `maximumTileZoom`: past it, one tile serves every camera zoom and
    /// cannot carry the building at one and leave it out at another.
    func effectiveMinimumZoom(maximumTileZoom: Int) -> Int {
        min(max(0, minimumZoom), maximumTileZoom)
    }
}
