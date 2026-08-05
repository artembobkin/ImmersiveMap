// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// A scene model's anchor resolved for the current frame: the model matrix
/// placing the mesh on the (possibly mid-morph) map surface, the world-space
/// bounding sphere for frustum culling, and the globe horizon visibility gate.
struct SceneModelAnchor {
    let modelMatrix: matrix_float4x4
    let boundingSphereCenter: SIMD3<Float>
    let boundingSphereRadius: Float
    /// False when the anchor is beyond the globe horizon gate: the depth test
    /// would hide the model anyway, this only skips the draw.
    let passesHorizonGate: Bool
}

/// Composes the model matrix on top of the surface frame resolved by
/// `GeoSurfaceFrameMath`: the morph is evaluated ONCE per anchor, so a model
/// sits exactly on the morph geometry while staying rigid (no per-vertex
/// shear), and it shares that evaluation with route tessellation.
enum SceneModelAnchorMath {
    static func resolveAnchor(presented: PresentedSceneModel,
                              bounds: SceneModelMesh.Bounds,
                              constants: GeoScreenProjectionMath.FrameConstants) -> SceneModelAnchor {
        let frame = GeoSurfaceFrameMath.resolve(basis: presented.projectionBasis, constants: constants)

        let fitScale: Float
        if let fitDiameterMeters = presented.fitDiameterMeters, fitDiameterMeters > 0 {
            fitScale = Float(fitDiameterMeters) / bounds.maxExtent
        } else {
            fitScale = 1
        }
        let scale = frame.unitsPerMeter * Float(presented.scale) * fitScale
        let worldPosition = frame.worldPosition
            + frame.up * (Float(presented.altitudeMeters) * frame.unitsPerMeter)

        // Column-vector composition, rightmost first: uniform scale in asset
        // units → USD Y-up to anchor Z-up → heading/pitch/roll in the tangent
        // frame → tangent basis into render space → translate to the anchor.
        let basisMatrix = matrix_float4x4(columns: (SIMD4<Float>(frame.east, 0),
                                                    SIMD4<Float>(frame.north, 0),
                                                    SIMD4<Float>(frame.up, 0),
                                                    SIMD4<Float>(0, 0, 0, 1)))
        let modelMatrix = Matrix.translationMatrix(x: worldPosition.x,
                                                   y: worldPosition.y,
                                                   z: worldPosition.z)
            * basisMatrix
            * matrix_float4x4(presented.orientation)
            * Matrix.rotationMatrixX(.pi / 2)
            * Matrix.scaleMatrix(sx: scale, sy: scale, sz: scale)

        let boundingCenter = modelMatrix * SIMD4<Float>(bounds.center, 1)
        return SceneModelAnchor(modelMatrix: modelMatrix,
                                boundingSphereCenter: boundingCenter.xyz,
                                boundingSphereRadius: bounds.radius * scale,
                                passesHorizonGate: frame.passesHorizonGate)
    }
}
