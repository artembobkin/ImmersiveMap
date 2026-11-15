// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal
import simd

final class RendererPinDrawer {
    private init() {}

    static func drawPins(renderEncoder: MTLRenderCommandEncoder,
                            screenMatrix: matrix_float4x4,
                            time: Float,
                            frameSlotIndex: Int,
                            pinsRenderer: PinsRenderer) {
        pinsRenderer.drawPins(renderEncoder: renderEncoder,
                                    screenMatrix: screenMatrix,
                                    time: time,
                                    frameSlotIndex: frameSlotIndex)
    }
}
