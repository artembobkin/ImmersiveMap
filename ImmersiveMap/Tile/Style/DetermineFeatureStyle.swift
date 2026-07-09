// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class DetermineFeatureStyle {
    private let fallbackKey: UInt8 = 0
    private var fallbackStyle: FeatureStyle
    private let mapStyle: ImmersiveMapStyle

    init(mapStyle: ImmersiveMapStyle) {
        fallbackStyle = FeatureStyle(
            key: fallbackKey,
            color: SIMD4<Float>(1.0, 0.0, 0.0, 1.0),
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
        
        self.mapStyle = mapStyle
    }
    
    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        return mapStyle.makeStyle(data: data)
    }
}
