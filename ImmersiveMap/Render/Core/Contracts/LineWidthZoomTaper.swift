// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Camera-zoom taper for point-locked line widths.
///
/// A point-locked width holds its size on screen at every zoom, which is the
/// point, but a width designed for a regional view is far too heavy when the
/// whole planet is on screen: borders drawn at their full points over a
/// z1 globe dominate the picture. The taper scales every point-locked width
/// down toward half size at planet zooms and releases smoothly to full size
/// by regional zoom. It is continuous in camera zoom, so it cannot reintroduce
/// the integer-zoom width jumps the point lock removed: the flat path applies
/// it per frame, and the atlas path folds it into the quantized raster scale
/// that drives its re-bakes.
enum LineWidthZoomTaper {
    static let floorScale: Float = 0.5
    static let taperStartZoom: Double = 2.0
    static let taperEndZoom: Double = 5.0

    static func scale(for zoom: Double) -> Float {
        let progress = Float((zoom - taperStartZoom) / (taperEndZoom - taperStartZoom))
        let clamped = simd_clamp(progress, 0.0, 1.0)
        let eased = clamped * clamped * (3.0 - 2.0 * clamped)
        return floorScale + (1.0 - floorScale) * eased
    }
}

/// The one camera quantity point-locked widths on the globe must track: the
/// fractional-zoom dolly, which magnifies the whole baked atlas on screen by
/// 1/(1 - 0.5 frac(zoom)). It is global, identical for every tile, so
/// compensating with it cannot make widths differ between tiles or shift
/// under panning and tilting, unlike anything derived from a tile's own
/// projected footprint. Log-quantized to eighth-of-an-octave steps so it can
/// sit in the atlas redraw hash without re-baking every frame; across an
/// integer zoom the factor snaps from a half back to one exactly as the next
/// level's tiles halve on screen, so the products cancel and the width is
/// continuous.
enum LineWidthDollyScale {
    static func quantized(for zoom: Double) -> Float {
        let dolly = Float(1.0 - 0.5 * zoom.truncatingRemainder(dividingBy: 1.0))
        let stepped = (log2(max(dolly, 0.5)) * 8.0).rounded() / 8.0
        return exp2(stepped)
    }
}
