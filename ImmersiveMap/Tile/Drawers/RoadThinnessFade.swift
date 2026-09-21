// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The roads' thinness fade: a road becomes more transparent as it gets
/// thinner on screen. At `opaqueWidthPixels` wide and over it draws at its
/// style's alpha, at `goneWidthPixels` and under it is gone, and it fades
/// smoothly between the two. The widths are the road's visible width in
/// drawable pixels, after the perspective has thinned it. Edited in the
/// debug panel. Mirror of `tileRoadThinnessFade` in TileShading.h.
struct RoadThinnessFade: Equatable {
    var goneWidthPixels: Float
    var opaqueWidthPixels: Float

    static let goneRange: ClosedRange<Double> = 0 ... 8
    static let opaqueRange: ClosedRange<Double> = 0 ... 16
    static let `default` = RoadThinnessFade(goneWidthPixels: 4, opaqueWidthPixels: 16)
    /// No fade: what a rasterized tile's picture is drawn with, where a
    /// pixel is a texel of the picture and not of the screen.
    static let off = RoadThinnessFade(goneWidthPixels: 0, opaqueWidthPixels: 0)

    init(goneWidthPixels: Float, opaqueWidthPixels: Float) {
        self.goneWidthPixels = max(goneWidthPixels, 0)
        self.opaqueWidthPixels = max(opaqueWidthPixels, 0)
    }

    /// The share of a road's alpha left at a width on screen.
    func alpha(widthPixels: Float) -> Float {
        guard opaqueWidthPixels > 0 else { return 1 }
        let upper = max(opaqueWidthPixels, goneWidthPixels + 1e-3)
        let t = min(max((widthPixels - goneWidthPixels) / (upper - goneWidthPixels), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
