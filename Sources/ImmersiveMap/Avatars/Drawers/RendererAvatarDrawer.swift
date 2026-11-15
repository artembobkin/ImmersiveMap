// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal
import simd

final class RendererAvatarDrawer {
    private init() {}

    static func drawAvatars(renderEncoder: MTLRenderCommandEncoder,
                            screenMatrix: matrix_float4x4,
                            time: Float,
                            frameSlotIndex: Int,
                            avatarsRenderer: AvatarsRenderer) {
        avatarsRenderer.drawAvatars(renderEncoder: renderEncoder,
                                    screenMatrix: screenMatrix,
                                    time: time,
                                    frameSlotIndex: frameSlotIndex)
    }
}
