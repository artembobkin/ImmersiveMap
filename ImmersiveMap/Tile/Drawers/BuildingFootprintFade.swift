// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The footprint fade of the flat building fills: a fill of the footprint
/// fade band (`LowZoomOverviewFade.footprintFadeMask`) takes its alpha from
/// its polygon's footprint on screen in square pixels, gone at the gone
/// area and under, whole at the opaque area and over, so a distant block
/// of small footprints leaves the ground softly instead of shimmering as
/// sub-pixel fills. The flat vertex stage resolves it (`tileFootprintAlpha`
/// in TileShading.h) from the radius the parser packs per polygon
/// (`TileVertexIn.footprintRadiusNormal`). The two areas ride with the rule
/// set (`RingRuleSetTuning`).
///
/// The extruded buildings take no part in it: they all draw, whole and
/// opaque, at every size on screen.
struct BuildingFootprintFade: Hashable {
    var goneAreaPixels: Float
    var opaqueAreaPixels: Float

    static let defaultGoneAreaPixels: Float = 100
    static let defaultOpaqueAreaPixels: Float = 2500
    static let goneAreaRange: ClosedRange<Double> = 0 ... 4000
    static let opaqueAreaRange: ClosedRange<Double> = 0 ... 20000

    /// A footprint on screen in square pixels: the square inscribed in the
    /// disc of the polygon's radius. Mirror of the shader's area.
    static func footprintAreaPixels(radiusPixels: Float) -> Float {
        2 * radiusPixels * radiusPixels
    }

    /// Mirror of `tileFootprintAlpha`'s ramp. A zero opaque area turns the
    /// fade off.
    func alpha(areaPixels: Float) -> Float {
        guard opaqueAreaPixels > 0 else { return 1 }
        let upper = max(opaqueAreaPixels, goneAreaPixels + 1e-3)
        let t = min(max((areaPixels - goneAreaPixels) / (upper - goneAreaPixels), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
