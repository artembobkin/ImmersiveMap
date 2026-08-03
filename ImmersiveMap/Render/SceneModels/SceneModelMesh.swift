// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit
import simd

/// A loaded, GPU-ready model asset: MetalKit meshes with per-submesh materials,
/// per-mesh node transforms, and the asset-local bounds used for sizing and
/// culling. Shared by every scene model referencing the same source URL.
struct SceneModelMesh {
    struct SubmeshMaterial {
        /// nil means untextured: the drawer binds the shared white texture and
        /// `baseColor` carries the constant color.
        let baseColorTexture: MTLTexture?
        let baseColor: SIMD4<Float>
    }

    /// Bounds in asset space (before the Y-up to Z-up anchor conversion);
    /// rotation-invariant radius/extent survive the conversion unchanged.
    struct Bounds {
        let center: SIMD3<Float>
        let radius: Float
        let maxExtent: Float
    }

    let meshes: [MTKMesh]
    /// Flattened node transform of each mesh inside the asset, parallel to `meshes`.
    let localTransforms: [matrix_float4x4]
    /// materials[meshIndex][submeshIndex], parallel to `meshes` and their submeshes.
    let materials: [[SubmeshMaterial]]
    let localBounds: Bounds
    let costInBytes: Int
}
