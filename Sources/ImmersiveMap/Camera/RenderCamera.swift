// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit
import Metal

class RenderCamera {
    /// The fixed vertical field of view of the render camera, read by the
    /// horizon frame resolver as well (HorizonRenderSubsystem).
    static let verticalFovRadians = Float.pi / 4
    /// The near plane, in view units (kFlatCameraNearPlane in Tile.metal,
    /// pinned by TileClipDistanceContractTests).
    static let nearPlane: Float = 0.01
    /// The far plane of the matrices the CPU works with: the coverage,
    /// the horizon and the picking unproject through them, and they want a
    /// far plane close to the visible ground. The GPU draws with a far
    /// plane far past it (`gpuFarPlane`).
    static let farPlane: Float = 200.0
    /// The far plane the GPU draws with. The flat ground's depth is the
    /// projection's (Tile.metal), so the ground ends at the far plane, and
    /// at 200 units it ended a visible band under the horizon, the eye
    /// standing hundreds of units over the ground at the middle zooms. The
    /// float depth keeps its precision: it is near-plane dominated, and one
    /// rank step of the ground's band is still many float steps at a
    /// thousand units. Only the camera uniform carries it
    /// (`gpuClipDepthAdjustment`), as the real-depth scale.
    static let gpuFarPlane: Float = 100_000.0
    /// The scale the camera uniform the GPU draws with applies to the
    /// projection's z, for everything real (the buildings, the models,
    /// the markers): the flat ground writes its depth as the projection's
    /// z scaled by its layer's rank instead (Tile.metal,
    /// kFlatRealDepthScale), a scale of 1 minus up to 1220 rank steps for
    /// the ground's layers and the labels painted on it, so the real
    /// geometry takes a scale nearer than all of them, and a wall's base
    /// is never covered by the ground behind it. The far plane moves 0.06
    /// percent nearer, which nothing sees. Only the uniform carries it
    /// (`FrameContext.cameraUniform`): the matrices the CPU unprojects
    /// with (the coverage, the horizon, the shadows, the picking) stay
    /// the projection's own, since an NDC depth of 1 unprojected through
    /// the scaled matrix is past the far plane.
    static let realDepthScale: Float = 1 - 1536 * GlobeSurfaceDepthRank.layerDepthStep

    /// The map from the CPU projection's clip z to the GPU's: the far
    /// plane moved to `gpuFarPlane` and the z scaled by `realDepthScale`,
    /// both linear in clip space (z' = a z + b w), so one matrix applied
    /// after the projection-view does it and x, y and w are untouched.
    static let gpuClipDepthAdjustment: matrix_float4x4 = {
        func zRow(near: Float, far: Float) -> (zScale: Float, wzScale: Float) {
            (-(far + near) / (far - near), -2 * far * near / (far - near))
        }
        let cpu = zRow(near: nearPlane, far: farPlane)
        let gpu = zRow(near: nearPlane, far: gpuFarPlane)
        // The perspective's z_clip = zScale * z_view + wzScale, and w_clip
        // = -z_view, so z_clip = -zScale * w_clip + wzScale on both sides.
        let a = gpu.zScale / cpu.zScale
        let b = gpu.wzScale - a * cpu.wzScale
        var adjustment = matrix_identity_float4x4
        adjustment[2][2] = a * realDepthScale
        adjustment[3][2] = b * realDepthScale
        return adjustment
    }()

    var projection: matrix_float4x4?
    var view: matrix_float4x4?

    var eye: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
    var center: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    var up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)

    private(set) var frustrum: Frustum?

    private(set) var cameraMatrix: matrix_float4x4?

    init() {}

    func recalculateProjection(aspect: Float) {
        // The far plane is far past the visible ground (farPlane): the far
        // clip line would otherwise be a visible "horizon" whose position
        // depends on the zoom, since the render world's scale doubles with
        // the zoom while the clip stays at the same distance.
        self.projection = Matrix.perspectiveMatrix(fovRadians: Self.verticalFovRadians, aspect: aspect, near: Self.nearPlane, far: Self.farPlane)
        recalculateMatrix()
    }

    func recalculateMatrix() {
        guard let projection else {
            assertionFailure("Render camera projection must be set before recalculating matrices.")
            return
        }
        let view = Matrix.lookAt(eye: eye, center: center, up: up)
        self.view = view
        cameraMatrix = projection * view

        if let cameraMatrix {
            frustrum = Frustum(pv: cameraMatrix)
        } else {
            frustrum = nil
        }
    }
}
