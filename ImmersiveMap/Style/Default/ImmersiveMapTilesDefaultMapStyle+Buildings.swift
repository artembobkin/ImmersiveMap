// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The buildings: extruded from the tiles' render heights.
extension ImmersiveMapTilesDefaultMapStyle {
    func buildingStyle(props: [String: MvtValue], tileZoom: Int) -> FeatureStyle {
        guard tileZoom >= 13 else {
            return hiddenStyle
        }
        // 3D extruded buildings driven by OpenMapTiles render_height / render_min_height.
        return .extrusion(ExtrusionStyle(
            key: 30,
            color: configuration.features.buildingFillColor,
            heightScale: 8.0,
            anchorZoom: 16
        ))
    }
}
