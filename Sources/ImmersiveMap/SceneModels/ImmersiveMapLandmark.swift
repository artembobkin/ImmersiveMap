// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A 3D model that takes the place of one of the map's own buildings: the
/// map leaves that building out and draws the model where it stood.
///
/// The building is named by its OSM elements (`replacedBuildings`): the
/// outline, and each `building:part` the map draws inside it. The map
/// leaves out exactly the elements named, so a part not listed stays
/// standing inside the model. The footprint's flat ground fill stays,
/// under the model. Which tile feature an element is, the map style's
/// schema answers (`ImmersiveMapTileSchema.tileFeatureID(of:)`). A schema
/// whose tiles carry no OSM ids replaces nothing and only adds the model.
///
/// The swap is made in the frame that draws the model: until the model is
/// loaded, the map's own building stands, and it comes back if the model
/// goes away. There is never a frame with neither.
///
/// A landmark can hold back to a zoom (`minimumZoom`): below it the model is
/// not drawn and the map's own building stands in its place, so the model
/// shows only where it reads as more than a block. The zoom compared is
/// the tile zoom the frame draws. A zoom deeper than the tileset's deepest
/// tile zoom acts as that zoom.
///
/// Landmarks are map configuration, set with `.landmarks(_:)`, and a change
/// to them applies in place. They suit a handful of models an app ships.
/// A city's worth of models comes from a model archive instead, loaded and
/// released by map tile (`.modelArchive(_:headers:)`). For models that
/// move, animate or answer taps, use `ImmersiveMapSceneModelsController`.
public struct ImmersiveMapLandmark: Identifiable, Equatable, Sendable {
    public var id: String
    /// The model: USDZ or OBJ, local file URL, Y-up meters with -Z north,
    /// like a scene model.
    public var model: ImmersiveMapSceneModel.Source
    /// Where the model's origin stands.
    public var coordinate: GeoCoordinate
    /// The map buildings the model replaces, by their OSM elements: the
    /// outline and each of its parts. Empty for a model that stands where
    /// the map has no building of its own (a bridge, a monument): it
    /// replaces nothing and only adds the model, still from `minimumZoom`.
    public var replacedBuildings: [ImmersiveMapOSMElement]
    /// Rotation about the local up axis, clockwise from north, in degrees.
    public var headingDegrees: Double
    /// Multiplier over the asset's meters.
    public var scale: Double
    /// Offset of the model's origin above the map surface, in meters.
    /// Negative sinks the model: a building that is partly underground is
    /// modelled from its lowest floor and sunk by the depth of that floor,
    /// together with `cutsIntoGround`.
    public var altitudeMeters: Double
    /// Whether the model cuts into the ground where it stands, as
    /// `ImmersiveMapSceneModel.cutsIntoGround`: the part below the surface
    /// shows only through the model's own outline on the ground.
    public var cutsIntoGround: Bool
    /// The camera zoom the model shows from, the map's building standing in
    /// below it. Zero shows it at every zoom that draws buildings.
    public var minimumZoom: Int

    public init(id: String,
                model: ImmersiveMapSceneModel.Source,
                coordinate: GeoCoordinate,
                replacedBuildings: [ImmersiveMapOSMElement],
                headingDegrees: Double = 0,
                scale: Double = 1,
                altitudeMeters: Double = 0,
                cutsIntoGround: Bool = false,
                minimumZoom: Int = 0) {
        self.id = id
        self.model = model
        self.coordinate = coordinate
        self.replacedBuildings = replacedBuildings
        self.headingDegrees = headingDegrees
        self.scale = scale
        self.altitudeMeters = altitudeMeters
        self.cutsIntoGround = cutsIntoGround
        self.minimumZoom = minimumZoom
    }

    /// The zoom the swap happens at for a tileset whose deepest tile zoom is
    /// `maximumTileZoom`: past it, one tile serves every camera zoom and
    /// cannot carry the building at one and leave it out at another.
    func effectiveMinimumZoom(maximumTileZoom: Int) -> Int {
        min(max(0, minimumZoom), maximumTileZoom)
    }
}
