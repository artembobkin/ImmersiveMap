// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Layout of the N:1 shadow atlas: cascade `i` rasterizes into the square
/// slot `[i·resolution, (i+1)·resolution) × [0, resolution)`. Shared by the
/// caster drawers, the attachment store and the resolver's UV math so the
/// slots can never disagree with the sampling matrices.
enum ShadowCascadeAtlas {
    /// Near (crisp) / middle / far. Texel world size roughly triples per
    /// step; the middle cascade exists because at a tilted camera most
    /// visible shadows land beyond the near disc, where far-cascade texels
    /// (~11 m) visibly wobble diagonal shadow edges.
    static let cascadeCount = 3

    static func selectCascade(renderEncoder: MTLRenderCommandEncoder,
                              cascadeIndex: Int,
                              mapResolution: Int) {
        let originX = cascadeIndex * mapResolution
        renderEncoder.setViewport(MTLViewport(originX: Double(originX),
                                              originY: 0,
                                              width: Double(mapResolution),
                                              height: Double(mapResolution),
                                              znear: 0,
                                              zfar: 1))
        renderEncoder.setScissorRect(MTLScissorRect(x: originX,
                                                    y: 0,
                                                    width: mapResolution,
                                                    height: mapResolution))
    }
}
