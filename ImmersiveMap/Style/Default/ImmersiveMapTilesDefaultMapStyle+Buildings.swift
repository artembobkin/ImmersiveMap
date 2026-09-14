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
        return FeatureStyle(
            key: 30,
            color: configuration.features.buildingFillColor,
            lineGeometry: LineGeometryStyle(lineWidth: 0),
            building: .openStreetMap(ImmersiveMapFeatureProperties(values: props)),
            extrusionHeightScale: 8.0,
            extrusionAnchorZoom: 16
        )
    }
}
