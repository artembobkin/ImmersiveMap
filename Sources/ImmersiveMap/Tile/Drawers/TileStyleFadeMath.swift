// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// CPU mirror of `tileStyleFade` in TileShading.h, reduced to the two
/// questions the layered ground drawer asks: is this style's fade exactly 1
/// this frame (an alpha-opaque style draws opaque), and is it exactly 0 (the
/// run is invisible and skipped before a buffer is bound)? The progress is
/// computed exactly as the shader computes it, so the drawer and the shader
/// never disagree about the ends of a fade.
enum TileStyleFadeMath {
    /// The fade's progress at the frame's camera zoom, clamped to [0, 1]:
    /// `zoomFade` is the shader pair, x the zoom of zero alpha and y the
    /// zoom of full alpha (`ImmersiveMapZoomFade`).
    static func progress(zoomFade: SIMD2<Float>, overviewFade: TileOverviewFadeUniform) -> Float {
        let span = zoomFade.y - zoomFade.x
        guard span != 0 else { return overviewFade.cameraZoom >= zoomFade.y ? 1 : 0 }
        return simd_clamp((overviewFade.cameraZoom - zoomFade.x) / span, 0, 1)
    }

    static func fadeIsOne(zoomFade: SIMD2<Float>, overviewFade: TileOverviewFadeUniform) -> Bool {
        progress(zoomFade: zoomFade, overviewFade: overviewFade) >= 1
    }

    /// True when the style's fade resolves to exactly 0 this frame: the run
    /// would rasterize with alpha 0, so the drawer skips it entirely.
    static func fadeIsZero(zoomFade: SIMD2<Float>, overviewFade: TileOverviewFadeUniform) -> Bool {
        progress(zoomFade: zoomFade, overviewFade: overviewFade) <= 0
    }
}
