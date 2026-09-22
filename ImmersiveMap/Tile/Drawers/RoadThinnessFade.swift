// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The roads' thinness fade: a road becomes more transparent as it gets
/// thinner on screen. At `opaqueWidthPixels` wide and over it draws at its
/// style's alpha, and under that it fades smoothly with its width, down to
/// nothing at no width at all. The width is the road's visible width in
/// drawable pixels, after the perspective has thinned it. Edited in the
/// debug panel. Mirror of `tileRoadThinnessFade` in TileShading.h.
struct RoadThinnessFade: Hashable {
    var opaqueWidthPixels: Float

    static let opaqueRange: ClosedRange<Double> = 0 ... 16
    static let `default` = RoadThinnessFade(opaqueWidthPixels: 10)
    /// No fade: what a rasterized tile's picture is drawn with, where a
    /// pixel is a texel of the picture and not of the screen.
    static let off = RoadThinnessFade(opaqueWidthPixels: 0)

    init(opaqueWidthPixels: Float) {
        self.opaqueWidthPixels = max(opaqueWidthPixels, 0)
    }

    /// The share of a road's alpha left at a width on screen.
    func alpha(widthPixels: Float) -> Float {
        guard opaqueWidthPixels > 0 else { return 1 }
        let t = min(max(widthPixels / opaqueWidthPixels, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
