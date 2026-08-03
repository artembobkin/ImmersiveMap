// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Layout of the 2:1 shadow atlas: cascade `i` rasterizes into the square
/// half `[i·resolution, (i+1)·resolution) × [0, resolution)`. Shared by both
/// caster drawers so the halves can never disagree with the sampling matrices.
enum ShadowCascadeAtlas {
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
