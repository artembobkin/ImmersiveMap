// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import simd

/// Conversion between layout points and device pixels.
///
/// Points are the engine's screen-space unit for everything with a perceived
/// physical size: label text, halos, POI icons, collision grid cells, avatar
/// markers. A point subtends roughly the same visual angle on a phone held at
/// reading distance as on a desktop display at desk distance, so a value
/// expressed in points reads the same on both, while the same value expressed
/// in device pixels shrinks as the display gets denser.
///
/// The conversion happens once, at the render boundary: geometry baked into a
/// prepared tile stays in points and therefore stays resolution independent,
/// which is what lets one prepared-tile disk cache serve displays of different
/// scales.
///
/// Quantities that are genuinely about device pixels do not pass through here:
/// texture atlas texel math, MSAA and FXAA sampling, and the signed-distance
/// range derived from screen-space derivatives in the text shader.
///
/// Labels, POI icons, collision grids and route widths are converted. Avatar
/// markers and their badges are not yet: their on-screen size is currently the
/// same number as the resolution of the atlas cell they sample
/// (`AvatarsRenderer.markerSizePx`), so giving them a unit means decoupling
/// those two and re-rasterizing three lazily built atlases whenever the scale
/// changes, which is its own change rather than a rename.
struct ScreenScale: Equatable, Sendable {
    /// Device pixels per layout point. Matches the backing layer's
    /// `contentsScale` for on-screen rendering.
    let pixelsPerPoint: Float

    /// The scale the built-in styles are authored against: a 2x Retina display.
    /// Style values in points multiplied by this reproduce the pixel sizes the
    /// engine used before screen-space quantities carried a unit.
    static let reference = ScreenScale(pixelsPerPoint: Float(2))

    static let identity = ScreenScale(pixelsPerPoint: Float(1))

    init(pixelsPerPoint: Float) {
        self.pixelsPerPoint = max(pixelsPerPoint, 0.01)
    }

    /// From a layer's `contentsScale`.
    init(contentsScale: CGFloat) {
        self.init(pixelsPerPoint: Float(contentsScale))
    }

    func pixels(_ points: Float) -> Float {
        points * pixelsPerPoint
    }

    func pixels(_ points: SIMD2<Float>) -> SIMD2<Float> {
        points * pixelsPerPoint
    }

    func points(_ pixels: Float) -> Float {
        pixels / pixelsPerPoint
    }
}
