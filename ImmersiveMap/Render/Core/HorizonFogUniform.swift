// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Haze at the horizon of the flat presentation; the layout mirrors `HorizonFog`
/// in RenderUniforms.h.
///
/// Distances are measured in eye heights above the plane: the fog starts at
/// `startEyeHeights` (angular ≈ atan(1/12) ≈ 4.8° below the vanishing line) and
/// saturates by `endEyeHeights` (≈ 0.2°). This keeps the fog band geometrically
/// glued to the vanishing line at any zoom and tilt: the render-scale change at
/// integer zooms does not move it, so jumps are ruled out by construction.
/// When looking straight down, all visible ground is closer than
/// `startEyeHeights` heights and the map stays clean.
///
/// `strength` equals the globe→flat transition phase: no fog on the pure globe,
/// it fades in smoothly during the morph, and by the surface switch both sides
/// are fogged identically, hiding the horizon-line seam.
struct HorizonFogUniform {
    var color: SIMD3<Float>
    var eye: SIMD3<Float>
    var strength: Float
    var startEyeHeights: Float
    var endEyeHeights: Float
    var _padding: Float = 0

    static let defaultStartEyeHeights: Float = 12
    /// Full opacity must be reached BEFORE the nearest possible edge of the
    /// tile coverage, otherwise the backdrop flashes beyond it during the
    /// surface switch. Edge = coverage radius (40 tiles of the target zoom ×
    /// 2π·globeRadiusScale ≈ 35.2 render units) at the maximum eye height
    /// 0.25 → minimum ≈ 140 heights. 120 leaves margin; angular that is
    /// ≈ atan(1/120) ≈ 0.48° below the vanishing line, a thin rim right at the
    /// horizon. Recompute if `VisibleTilesPreprocessor.defaultMaxVisibleRelativeDistance`
    /// or `globeRadiusScale` changes.
    static let defaultEndEyeHeights: Float = 120

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
