// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// CPU mirror of `tileStyleFade` in TileShading.h, reduced to the two
/// questions the layered ground drawer asks: is this style's fade exactly 1
/// this frame (an alpha-opaque style draws opaque), and is it exactly 0 (the
/// run is invisible and skipped before a buffer is bound)? Thresholds must
/// match the shader's, band for band.
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

    /// True when the style's fade resolves to exactly 0 this frame: the run
    /// would rasterize with alpha 0, so the drawer skips it entirely.
    /// The road-marking fade band of the baked mask (the shader's
    /// `roadMarkingAlpha` band): the styles the distance LOD may skip.
    static func isMarkingBand(mask: Float) -> Bool {
        mask >= 3.5 && mask < 4.5
    }

    static func fadeIsZero(mask: Float, overviewFade: TileOverviewFadeUniform) -> Bool {
        if mask >= 9.5 {
            // Class fade: nothing shows until the camera passes its start zoom.
            return overviewFade.cameraZoom - (mask - 10.0) <= 0.0
        } else if mask >= 3.5 {
            return overviewFade.roadMarkingAlpha <= 0.0
        } else if mask >= 2.5 {
            return overviewFade.landuseAlpha <= 0.0
        } else if mask >= 1.5 {
            return overviewFade.roadAlpha <= 0.0
        } else if mask >= 0.5 {
            return overviewFade.overviewAlpha <= 0.0
        }
        return false
    }
}
