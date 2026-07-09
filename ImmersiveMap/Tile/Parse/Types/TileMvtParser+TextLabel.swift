// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct TextLabel {
        let text: String
        let position: SIMD2<Int16>
        let key: UInt64
        let sortKey: Int
        let collisionPriority: Int
        let textStyle: LabelTextStyle
        let poiIcon: PoiSpriteIcon?

        init(text: String,
             position: SIMD2<Int16>,
             tile: Tile,
             featureId: UInt64,
             hasFeatureId: Bool,
             layerName: String,
             sortKey: Int,
             collisionPriority: Int,
             textStyle: LabelTextStyle,
             poiIcon: PoiSpriteIcon? = nil) {
            self.text = text
            self.position = position
            self.key = TileMvtParser.makePointLabelKey(text: text,
                                                       anchor: position,
                                                       featureId: featureId,
                                                       hasFeatureId: hasFeatureId,
                                                       layerName: layerName)
            self.sortKey = sortKey
            self.collisionPriority = collisionPriority
            self.textStyle = textStyle
            self.poiIcon = poiIcon
        }

        init(text: String,
             position: SIMD2<Int16>,
             key: UInt64,
             sortKey: Int,
             collisionPriority: Int,
             textStyle: LabelTextStyle,
             poiIcon: PoiSpriteIcon? = nil) {
            self.text = text
            self.position = position
            self.key = key
            self.sortKey = sortKey
            self.collisionPriority = collisionPriority
            self.textStyle = textStyle
            self.poiIcon = poiIcon
        }
    }
}
