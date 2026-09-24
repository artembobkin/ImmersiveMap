// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A point label as the parser read it from a feature: its text, its
/// anchor in tile units, the identity that keeps it stable across parses,
/// the priorities and style the label policy decided, and whether it stands
/// on the screen or lies on the map.
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
    }

    init(text: String,
         position: SIMD2<Int16>,
         key: UInt64,
         sortKey: Int,
         collisionPriority: Int,
         textStyle: LabelTextStyle,
         poiIcon: PoiSpriteIcon? = nil,
         minCameraZoom: Float = 0,
         placement: LabelPlacement = .screen) {
        self.text = text
        self.position = position
        self.key = key
        self.sortKey = sortKey
        self.collisionPriority = collisionPriority
        self.textStyle = textStyle
        self.poiIcon = poiIcon
        self.minCameraZoom = minCameraZoom
        self.placement = placement
    }
}
