// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Mirror of `BuildingLOD` in TileExtruded.metal (vertex buffer 7 of the
/// building and the shadow-caster pipelines): the screen-footprint level
/// of detail of the buildings. The vertex stage sizes each building's
/// footprint in pixels from its baked radius (`ExtrudedVertexIn.footprintRadius`)
/// and the camera depth of the vertex, drops a building under `cutPixels`
/// (a negative clip distance, no fragment is born) and sinks one between
/// the two thresholds into its footprint (its height scaled by a
/// smoothstep), so a distant block of small houses is flat ground rather
/// than a field of sub-pixel walls flickering at every camera move.
struct BuildingLODUniform {
    /// The camera matrix's depth row: the clip-space w of a world point,
    /// which is its view depth, is the dot product with it.
    var cameraDepthRow: SIMD4<Float>
    /// Pixels one world unit spans at a view depth of one: half the
    /// drawable height times the projection's vertical focal length.
    var pixelsPerWorldUnitAtUnitDepth: Float
    var cutPixels: Float
    var fadePixels: Float
    var padding: Float = 0

    static let defaultCutPixels: Float = 2
    static let defaultFadePixels: Float = 12
    static let cutRange: ClosedRange<Double> = 0 ... 8
    static let fadeRange: ClosedRange<Double> = 0 ... 40

    /// - Parameters:
    ///   - projectionView: the camera's projection times view matrix.
    ///   - view: the camera's view matrix, to take the projection back out.
    ///   - drawableHeightPx: the drawable's height in pixels.
    static func make(projectionView: matrix_float4x4,
                     view: matrix_float4x4,
                     drawableHeightPx: Float,
                     cutPixels: Float,
                     fadePixels: Float) -> BuildingLODUniform {
        let projection = projectionView * simd_inverse(view)
        let focal = projection.columns.1.y
        return BuildingLODUniform(cameraDepthRow: SIMD4<Float>(projectionView.columns.0.w,
                                                               projectionView.columns.1.w,
                                                               projectionView.columns.2.w,
                                                               projectionView.columns.3.w),
                                  pixelsPerWorldUnitAtUnitDepth: drawableHeightPx * 0.5 * focal,
                                  cutPixels: max(cutPixels, 0),
                                  fadePixels: max(fadePixels, cutPixels + 0.01))
    }

    /// Everything drawn whole: no cut, no fade.
    static let disabled = BuildingLODUniform(cameraDepthRow: .zero,
                                             pixelsPerWorldUnitAtUnitDepth: 0,
                                             cutPixels: 0,
                                             fadePixels: 0.01)
}
