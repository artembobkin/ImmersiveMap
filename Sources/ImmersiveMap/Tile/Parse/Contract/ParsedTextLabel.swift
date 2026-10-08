// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A point label as the parser read it from a feature: its text, its
/// anchor in tile units, the identity that keeps it stable across parses,
/// the priorities and style the label policy decided, and whether it stands
/// on the screen or lies on the map. A road's route signs are one of these
/// too: `routeShields` holds the signs, each number drawn on its plate.
struct ParsedTextLabel {
    let text: String
    let position: SIMD2<Int16>
    let key: UInt64
    let sortKey: Int
    let collisionPriority: Int
    let textStyle: LabelTextStyle
    let poiIcon: PoiSpriteIcon?
    /// Minimum camera zoom at which the label is visible (0 = always).
    let minCameraZoom: Float
    let placement: LabelPlacement
    /// The route signs the label draws instead of its text, nil for a
    /// plain label.
    let routeShields: RouteShieldStyle?
    /// Whether the label belongs to the building it stands in
    /// (`PointLabelStyle.standsOnRoof`): it takes the roof over its anchor,
    /// and rises to it when it names the building itself.
    let standsOnRoof: Bool
    /// The tile feature's id, nil for a feature without one. A building
    /// and a point made from the same OSM element share it, which is how
    /// a label is known to name the building it stands in.
    let featureId: UInt64?
    /// Local detail, shown only near the camera (`PointLabelStyle.isLocal`).
    let isLocal: Bool
    /// The roof the label draws on in tile units, the extrusion mesh's own
    /// height scale, set once the tile's buildings are resolved when it
    /// names the building (`liftsToRoof`). Zero for every other label,
    /// which draws on the ground.
    var roofHeight: Float = 0
    /// Whether the label draws on the roof over it: it names the building
    /// itself (the building's own OSM element), not something inside it.
    var liftsToRoof: Bool = false

    init(text: String,
         position: SIMD2<Int16>,
         tile: Tile,
         featureId: UInt64,
         hasFeatureId: Bool,
         layerName: String,
         sortKey: Int,
         collisionPriority: Int,
         textStyle: LabelTextStyle,
         poiIcon: PoiSpriteIcon? = nil,
         minCameraZoom: Float = 0,
         placement: LabelPlacement = .screen) {
        self.text = text
        self.position = position
        self.key = ParsedLabelKey.makePointLabelKey(text: text,
                                                   anchor: position,
                                                   featureId: featureId,
                                                   hasFeatureId: hasFeatureId,
                                                   layerName: layerName)
        self.sortKey = sortKey
        self.collisionPriority = collisionPriority
        self.textStyle = textStyle
        self.poiIcon = poiIcon
        self.minCameraZoom = minCameraZoom
        self.placement = placement
        self.routeShields = nil
        self.standsOnRoof = false
        self.featureId = hasFeatureId ? featureId : nil
        self.isLocal = false
    }

    init(text: String,
         position: SIMD2<Int16>,
         key: UInt64,
         sortKey: Int,
         collisionPriority: Int,
         textStyle: LabelTextStyle,
         poiIcon: PoiSpriteIcon? = nil,
         minCameraZoom: Float = 0,
         placement: LabelPlacement = .screen,
         routeShields: RouteShieldStyle? = nil,
         standsOnRoof: Bool = false,
         featureId: UInt64? = nil,
         isLocal: Bool = false) {
        self.text = text
        self.position = position
        self.key = key
        self.sortKey = sortKey
        self.collisionPriority = collisionPriority
        self.textStyle = textStyle
        self.poiIcon = poiIcon
        self.minCameraZoom = minCameraZoom
        self.placement = placement
        self.routeShields = routeShields
        self.standsOnRoof = standsOnRoof
        self.featureId = featureId
        self.isLocal = isLocal
    }
}
