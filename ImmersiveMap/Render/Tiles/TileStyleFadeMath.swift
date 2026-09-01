// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// CPU mirror of `tileStyleFade` in TileShading.h, reduced to the one
/// question the layered ground drawer asks: is this style's fade exactly 1
/// this frame, so an alpha-opaque style draws opaque? Thresholds must match
/// the shader's, band for band.
enum TileStyleFadeMath {
    static func fadeIsOne(mask: Float, overviewFade: TileOverviewFadeUniform) -> Bool {
        if mask >= 9.5 {
            // Class fade: fully in one zoom level past its start zoom.
            return overviewFade.cameraZoom - (mask - 10.0) >= 1.0
        } else if mask >= 3.5 {
            return overviewFade.roadMarkingAlpha >= 1.0
        } else if mask >= 2.5 {
            return overviewFade.landuseAlpha >= 1.0
        } else if mask >= 1.5 {
            return overviewFade.roadAlpha >= 1.0
        } else if mask >= 0.5 {
            return overviewFade.overviewAlpha >= 1.0
        }
        return true
    }
}
