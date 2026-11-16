// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import simd

struct PinInstanceGPU {
    var uvRect: SIMD4<Float>
    var borderColor: SIMD4<Float>
    var squashScale: SIMD2<Float>
    var atlasIndex: UInt32
    var flags: UInt32
    var morph: Float
    var _pad0: Float = 0.0
    var _pad1: SIMD2<Float> = .zero
}



struct PinCountBadgeInstanceGPU {
    var uvRect: SIMD4<Float>
    var flags: UInt32
    var screenSizeScale: Float
    var contentAlpha: Float
    var _padding: Float = 0.0
}

struct PinOffset {
    var value: SIMD2<Float>
    var scale: Float
    var _padding: Float = 0.0
}

struct PinBeamStyleGPU {
    /// From the pin's anchor to the center of its circle, at scale 1.
    var pinCenterOffsetPx: SIMD2<Float>
    var pinBodyHalfMinPx: Float
    var _padding: Float = 0.0
}

/// Mirrors `PinStyleGPU` in PinCommon.h. The fractions are of the pin's quad,
/// origin in the bottom left corner, y up.
struct PinStyleGPU {
    var sizePx: SIMD2<Float>
    var anchorUv: SIMD2<Float>
    var bodyCenterUv: SIMD2<Float>
    var bodyHalfUv: SIMD2<Float>
    var circleRadiusUv: Float
    var outlineWidthPx: Float
    var contentInsetPx: Float
    var distanceRangeTexels: Float
    var fillColor: SIMD4<Float>
    var frameless: UInt32
    /// The distance is in the texture's alpha, as in the built-in bubble's,
    /// and not in its red, as in a baked one.
    var distanceInAlpha: UInt32
    var _pad1: SIMD2<Float> = .zero
}



struct PinCountBadgeStyleGPU {
    var sizePx: SIMD2<Float>
    var originXPx: Float
    var originYPx: Float
}

/// The sizes of a map's pins on the screen, worked out once from the pin
/// settings and the shape.
struct PinStyle {
    let gpu: PinStyleGPU

    init(sizePx: Float,
         outlineWidthPx: Float,
         contentInset: Float = 0.06,
         fillColor: SIMD4<Float> = SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
         metrics: PinShapeMetrics = PinShapeMetrics(shape: .bubble),
         distanceRangeTexels: Float = PinShapeDistanceField.distanceRangeTexels,
         distanceInAlpha: Bool = false) {
        self.gpu = PinStyleGPU(sizePx: SIMD2<Float>(repeating: sizePx),
                               anchorUv: metrics.anchor,
                               bodyCenterUv: metrics.bodyCenter,
                               bodyHalfUv: metrics.bodyHalfSize,
                               circleRadiusUv: metrics.circleRadius,
                               outlineWidthPx: max(outlineWidthPx, 0.0),
                               contentInsetPx: max(sizePx * contentInset, 0.0),
                               distanceRangeTexels: distanceRangeTexels,
                               fillColor: fillColor,
                               frameless: metrics.isFrameless ? 1 : 0,
                               distanceInAlpha: distanceInAlpha ? 1 : 0)
    }

    /// The side of the pin's quad.
    var totalSizePx: SIMD2<Float> {
        gpu.sizePx
    }

    /// The lower left corner of the quad, from the pin's anchor.
    var quadOriginPx: SIMD2<Float> {
        -gpu.anchorUv * gpu.sizePx
    }

    /// The center of the picture area, and of the circle a pushed pin turns
    /// into, from the pin's anchor.
    var bodyCenterOffsetPx: SIMD2<Float> {
        (gpu.bodyCenterUv - gpu.anchorUv) * gpu.sizePx
    }

    /// The upper right corner of the picture area, from the pin's anchor.
    var bodyTopRightPx: SIMD2<Float> {
        (gpu.bodyCenterUv + gpu.bodyHalfUv - gpu.anchorUv) * gpu.sizePx
    }

    /// Half the longer side of the picture area.
    var bodyRadiusPx: Float {
        max(gpu.bodyHalfUv.x, gpu.bodyHalfUv.y) * gpu.sizePx.x
    }

    /// The radius of the circle a pushed pin turns into.
    var circleRadiusPx: Float {
        gpu.circleRadiusUv * gpu.sizePx.x
    }
}


/// Round bubble counter of a merged pin: sits on the top-right edge of the body
/// and protrudes above it.
struct PinCountBadgeStyle {
    static let sizeRatio: Float = 0.40
    static let minimumSizePx: Float = 46.0
    /// Offset of the bubble center inward from the body's right edge, as a fraction of the diameter.
    static let horizontalInsetRatio: Float = 0.18
    /// Offset of the bubble center down from the top of the body, as a fraction of the diameter.
    static let verticalInsetRatio: Float = 0.15

    let gpu: PinCountBadgeStyleGPU

    init(sizePx: Float, pinStyle: PinStyle) {
        let diameterPx = max(sizePx * Self.sizeRatio, Self.minimumSizePx)
        let centerXPx = pinStyle.bodyTopRightPx.x - diameterPx * Self.horizontalInsetRatio
        let centerYPx = pinStyle.bodyTopRightPx.y - diameterPx * Self.verticalInsetRatio

        self.gpu = PinCountBadgeStyleGPU(sizePx: SIMD2<Float>(repeating: diameterPx),
                                            originXPx: centerXPx - diameterPx * 0.5,
                                            originYPx: centerYPx - diameterPx * 0.5)
    }

    var sizePx: SIMD2<Float> {
        gpu.sizePx
    }
}

