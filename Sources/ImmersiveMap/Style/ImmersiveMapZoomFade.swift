// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// How a styled layer appears or disappears with the camera: fully drawn on
/// one side of a zoom range, not drawn on the other, and a smooth blend in
/// between. Any fill, line or road pass takes one (`FillStyle.zoomFade`,
/// `LinePass.zoomFade`).
///
/// The fade is a function of the camera zoom alone, evaluated per frame in
/// the shader, so it is continuous while the camera moves and two tile
/// levels that state the same fade draw the same frame: the swap from one
/// tile level to the next shows nothing. Tiles are chosen by flooring the
/// camera zoom, so a layer a source ships through tile z7 is still on
/// screen for camera zoom 7.0 up to 8.0, and that is the range to fade it
/// out over (`fadeOut(from: 7, to: 8)`) so it is gone before the z8 tiles
/// that lack it take over. A layer that first ships at tile z8 but is
/// also in the z7 tiles fades in over the same range on the z7 tiles.
public struct ImmersiveMapZoomFade: Hashable, Sendable {
    /// The camera zoom at which the layer is not drawn at all.
    public let zeroAlphaZoom: Double
    /// The camera zoom from which the layer is drawn at its full alpha.
    public let fullAlphaZoom: Double

    private init(zeroAlphaZoom: Double, fullAlphaZoom: Double) {
        self.zeroAlphaZoom = zeroAlphaZoom
        self.fullAlphaZoom = fullAlphaZoom
    }

    /// No fade: the layer is drawn at its full alpha at every zoom.
    public static let none = ImmersiveMapZoomFade(zeroAlphaZoom: -2, fullAlphaZoom: -1)

    /// Not drawn up to camera zoom `from`, drawn in full from `to`.
    public static func fadeIn(from: Double, to: Double) -> ImmersiveMapZoomFade {
        precondition(from < to, "A zoom fade runs from a lower to a higher zoom")
        return ImmersiveMapZoomFade(zeroAlphaZoom: from, fullAlphaZoom: to)
    }

    /// Drawn in full up to camera zoom `from`, gone from `to`.
    public static func fadeOut(from: Double, to: Double) -> ImmersiveMapZoomFade {
        precondition(from < to, "A zoom fade runs from a lower to a higher zoom")
        return ImmersiveMapZoomFade(zeroAlphaZoom: to, fullAlphaZoom: from)
    }

    /// The share of the layer's alpha drawn at a camera zoom: a smoothstep
    /// from 0 at `zeroAlphaZoom` to 1 at `fullAlphaZoom`. The shader's
    /// `tileStyleFade` evaluates the same curve.
    public func alpha(atZoom zoom: Double) -> Float {
        let progress = Float((zoom - zeroAlphaZoom) / (fullAlphaZoom - zeroAlphaZoom))
        let clamped = simd_clamp(progress, 0, 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// The pair the tile shaders read per style: x the zero alpha zoom, y
    /// the full alpha zoom.
    var shaderPair: SIMD2<Float> {
        SIMD2(Float(zeroAlphaZoom), Float(fullAlphaZoom))
    }
}

extension ImmersiveMapZoomFade {
    /// The band over which the globe's overview content comes in as the
    /// camera leaves the whole-planet view: point-locked strokes and the
    /// labels of the first zoom level.
    static let overview = ImmersiveMapZoomFade.fadeIn(from: 0, to: 1)
}
