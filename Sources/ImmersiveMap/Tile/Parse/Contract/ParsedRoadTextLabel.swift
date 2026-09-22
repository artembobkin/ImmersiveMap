// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A road name as the parser read it: the text and the path in tile
/// units it is laid along, with the identity that keeps it stable across
/// parses.
struct ParsedRoadTextLabel {
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
        self.key = ParsedLabelKey.makeRoadLabelKey(text: text,
                                                  path: path,
                                                  featureId: featureId,
                                                  hasFeatureId: hasFeatureId,
                                                  layerName: layerName)
        self.textStyle = textStyle
    }
}
