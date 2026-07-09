// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

struct AvatarGeoInput {
    var latitude: Float
    var longitude: Float
    var sizePx: Float
    var idHash: UInt32
}

struct AvatarInstanceGPU {
    var uvRect: SIMD4<Float>
    var borderColor: SIMD4<Float>
    var squashScale: SIMD2<Float>
    var atlasIndex: UInt32
    var flags: UInt32
}

struct AvatarBatteryBadgeInstanceGPU {
    var uvRect: SIMD4<Float>
    var flags: UInt32
    var screenSizeScale: Float
    var _padding: SIMD2<Float>
}

struct AvatarSpeedBadgeInstanceGPU {
    var uvRect: SIMD4<Float>
    var flags: UInt32
    var screenSizeScale: Float
    var _padding: SIMD2<Float>
}

struct AvatarOffset {
    var value: SIMD2<Float>
    var scale: Float
    var _padding: Float
}

struct AvatarMarkerStyleGPU {
    var bodySizePx: SIMD2<Float>
    var totalSizePx: SIMD2<Float>
    var cornerRadiusPx: Float
    var pointerHeightPx: Float
    var pointerHalfWidthPx: Float
    var outlineWidthPx: Float
    var contentInsetPx: Float
}

struct AvatarBatteryBadgeStyleGPU {
    var sizePx: SIMD2<Float>
    var gapPx: Float
    var cornerRadiusPx: Float
}

struct AvatarSpeedBadgeStyleGPU {
    var sizePx: SIMD2<Float>
    var originXPx: Float
    var originYPx: Float
}

struct AvatarMarkerStyle {
    static let pointerHalfWidthRatio: Float = 0.16666667
    static let cornerRadiusRatio: Float = 0.22222222
    static let contentInsetRatio: Float = 0.06

    let gpu: AvatarMarkerStyleGPU

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

        self.gpu = AvatarMarkerStyleGPU(bodySizePx: SIMD2<Float>(bodyWidthPx, bodyHeightPx),
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

struct AvatarBatteryBadgeStyle {
    static let widthRatio: Float = 0.62
    static let heightRatio: Float = 0.21
    static let gapRatio: Float = 0.045
    static let cornerRadiusRatio: Float = 0.26
    static let minimumWidthPx: Float = 76.0
    static let minimumHeightPx: Float = 21.0
    static let minimumGapPx: Float = 5.0

    let gpu: AvatarBatteryBadgeStyleGPU

    init(sizePx: Float) {
        let widthPx = max(sizePx * Self.widthRatio, Self.minimumWidthPx)
        let heightPx = max(sizePx * Self.heightRatio, Self.minimumHeightPx)
        let gapPx = max(sizePx * Self.gapRatio, Self.minimumGapPx)
        let cornerRadiusPx = heightPx * Self.cornerRadiusRatio

        self.gpu = AvatarBatteryBadgeStyleGPU(sizePx: SIMD2<Float>(widthPx, heightPx),
                                              gapPx: gapPx,
                                              cornerRadiusPx: cornerRadiusPx)
    }

    var sizePx: SIMD2<Float> {
        gpu.sizePx
    }

    var gapPx: Float {
        gpu.gapPx
    }

    var cornerRadiusPx: Float {
        gpu.cornerRadiusPx
    }

    var bottomExtensionPx: Float {
        gpu.sizePx.y + gpu.gapPx
    }
}

struct AvatarSpeedBadgeStyle {
    static let sizeRatio: Float = 0.40
    static let overlapRatio: Float = 0.58
    static let verticalLiftRatio: Float = -0.06
    static let verticalOriginRatio: Float = 0.02
    static let cornerRadiusRatio: Float = 0.20
    static let minimumSizePx: Float = 46.666667
    static let minimumOverlapPx: Float = 18.0

    let gpu: AvatarSpeedBadgeStyleGPU
    let overlapPx: Float
    let cornerRadiusPx: Float

    init(sizePx: Float, markerStyle: AvatarMarkerStyle) {
        let squareSizePx = max(sizePx * Self.sizeRatio, Self.minimumSizePx)
        let overlapPx = max(squareSizePx * Self.overlapRatio, Self.minimumOverlapPx)
        let cornerRadiusPx = squareSizePx * Self.cornerRadiusRatio
        let originXPx = markerStyle.bodySizePx.x * 0.5 - overlapPx
        let originYPx = max(markerStyle.pointerHeightPx + squareSizePx * Self.verticalLiftRatio,
                            markerStyle.bodySizePx.y * Self.verticalOriginRatio)

        self.gpu = AvatarSpeedBadgeStyleGPU(sizePx: SIMD2<Float>(repeating: squareSizePx),
                                            originXPx: originXPx,
                                            originYPx: originYPx)
        self.overlapPx = overlapPx
        self.cornerRadiusPx = cornerRadiusPx
    }

    var sizePx: SIMD2<Float> {
        gpu.sizePx
    }
}
