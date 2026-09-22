// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The buildings: extruded from the heights the schema reading states,
/// or, with the theme's extrusion off, the footprints as flat fills.
extension ImmersiveMapTilesDefaultMapStyle {
    func buildingStyle(props: [String: MvtValue], tileZoom: Int) -> FeatureStyle {
        guard tileZoom >= 13 else {
            return hiddenStyle
        }
        guard theme.features.buildingExtrusion else {
            // The same fill an extrusion draws under itself, and nothing
            // rises: how buildings draw on the globe, now on the plane too.
            return .fill(FillStyle(key: 30,
                                   color: theme.features.buildingFillColor,
                                   // A small footprint on screen fades out.
                                   lowZoomFadeMask: LowZoomOverviewFade.footprintFadeMask,
                                   outlineAntialiasing: false))
        }
        return .extrusion(ExtrusionStyle(
            key: 30,
            color: theme.features.buildingFillColor,
            heightScale: 8.0,
            anchorZoom: 16,
            roofShapes: theme.features.buildingRoofShapes
        ))
    }
}
