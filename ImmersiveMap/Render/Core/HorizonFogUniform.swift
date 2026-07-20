// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Дымка у горизонта плоского представления; раскладка зеркалит `HorizonFog`
/// в RenderUniforms.h.
///
/// Дистанции измеряются в высотах глаза над плоскостью: туман начинается на
/// `startEyeHeights` (angular ≈ atan(1/12) ≈ 4.8° ниже линии схода) и
/// насыщается к `endEyeHeights` (≈ 0.2°). Благодаря этому полоса тумана
/// геометрически приклеена к линии схода при любом зуме и наклоне - смена
/// рендерного масштаба на целых зумах её не сдвигает, скачки исключены по
/// построению. При взгляде сверху вся видимая земля ближе `startEyeHeights`
/// высот, и карта остаётся чистой.
///
/// `strength` равен фазе перехода глобус→плоскость: на чистом глобусе тумана
/// нет, во время морфа он проявляется плавно, и к моменту смены поверхностей
/// обе стороны затуманены одинаково - шов линии горизонта скрыт.
struct HorizonFogUniform {
    var color: SIMD3<Float>
    var eye: SIMD3<Float>
    var strength: Float
    var startEyeHeights: Float
    var endEyeHeights: Float
    var _padding: Float = 0

    static let defaultStartEyeHeights: Float = 12
    static let defaultEndEyeHeights: Float = 250

    static let disabled = HorizonFogUniform(color: .zero,
                                            eye: .zero,
                                            strength: 0,
                                            startEyeHeights: 1,
                                            endEyeHeights: 2)

    static func make(transition: Float,
                     cameraEye: SIMD3<Float>,
                     mapClearColor: SIMD4<Double>) -> HorizonFogUniform {
        HorizonFogUniform(color: SIMD3<Float>(Float(mapClearColor.x),
                                              Float(mapClearColor.y),
                                              Float(mapClearColor.z)),
                          eye: cameraEye,
                          strength: min(max(transition, 0), 1),
                          startEyeHeights: defaultStartEyeHeights,
                          endEyeHeights: defaultEndEyeHeights)
    }
}
