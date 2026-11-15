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
    var pinCenterOffsetPx: Float
    var pinBodyHalfMinPx: Float
    var _padding: SIMD2<Float> = .zero
}

struct PinStyleGPU {
    var bodySizePx: SIMD2<Float>
    var totalSizePx: SIMD2<Float>
    var cornerRadiusPx: Float
    var pointerHeightPx: Float
    var pointerHalfWidthPx: Float
    var outlineWidthPx: Float
    var contentInsetPx: Float
}



struct PinCountBadgeStyleGPU {
    var sizePx: SIMD2<Float>
    var originXPx: Float
    var originYPx: Float
}

struct PinStyle {
    static let pointerHalfWidthRatio: Float = 0.16666667
    static let cornerRadiusRatio: Float = 0.22222222
    static let contentInsetRatio: Float = 0.06

    let gpu: PinStyleGPU

    init(sizePx: Float,
         outlineWidthPx: Float,
         pointerHeightRatio: Float) {
        let totalWidthPx = sizePx
        let totalHeightPx = sizePx
        let pointerHeightPx = max(sizePx * pointerHeightRatio, 0.0)
        let bodyWidthPx = totalWidthPx
        let bodyHeightPx = max(totalHeightPx - pointerHeightPx, 0.0)
        let pointerHalfWidthPx = max(sizePx * Self.pointerHalfWidthRatio, outlineWidthPx * 1.5)
        let cornerRadiusPx = min(bodyWidthPx, bodyHeightPx) * Self.cornerRadiusRatio
        let contentInsetPx = max(sizePx * Self.contentInsetRatio, outlineWidthPx + 4.0)

        self.gpu = PinStyleGPU(bodySizePx: SIMD2<Float>(bodyWidthPx, bodyHeightPx),
                                        totalSizePx: SIMD2<Float>(totalWidthPx, totalHeightPx),
                                        cornerRadiusPx: cornerRadiusPx,
                                        pointerHeightPx: pointerHeightPx,
                                        pointerHalfWidthPx: pointerHalfWidthPx,
                                        outlineWidthPx: outlineWidthPx,
                                        contentInsetPx: contentInsetPx)
    }

    var bodySizePx: SIMD2<Float> {
        gpu.bodySizePx
    }

    var totalSizePx: SIMD2<Float> {
        gpu.totalSizePx
    }

    var pointerHeightPx: Float {
        gpu.pointerHeightPx
    }

    var pointerHalfWidthPx: Float {
        gpu.pointerHalfWidthPx
    }

    var cornerRadiusPx: Float {
        gpu.cornerRadiusPx
    }

    var outlineWidthPx: Float {
        gpu.outlineWidthPx
    }

    var contentInsetPx: Float {
        gpu.contentInsetPx
    }

    func localPosition(for uv: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>((uv.x - 0.5) * totalSizePx.x,
                     uv.y * totalSizePx.y)
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
        let centerXPx = pinStyle.bodySizePx.x * 0.5 - diameterPx * Self.horizontalInsetRatio
        let centerYPx = pinStyle.pointerHeightPx + pinStyle.bodySizePx.y - diameterPx * Self.verticalInsetRatio

        self.gpu = PinCountBadgeStyleGPU(sizePx: SIMD2<Float>(repeating: diameterPx),
                                            originXPx: centerXPx - diameterPx * 0.5,
                                            originYPx: centerYPx - diameterPx * 0.5)
    }

    var sizePx: SIMD2<Float> {
        gpu.sizePx
    }
}

