// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct RoadTextLabel {
        let text: String
        let path: [SIMD2<Int16>]
        let key: UInt64
        let textStyle: LabelTextStyle

        init(text: String,
             path: [SIMD2<Int16>],
             tile: Tile,
             featureId: UInt64,
             hasFeatureId: Bool,
             layerName: String,
             textStyle: LabelTextStyle) {
            self.text = text
            self.path = path
            self.key = TileMvtParser.makeRoadLabelKey(text: text,
                                                      path: path,
                                                      featureId: featureId,
                                                      hasFeatureId: hasFeatureId,
                                                      layerName: layerName)
            self.textStyle = textStyle
        }
    }
}
