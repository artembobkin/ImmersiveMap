// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// One tree of a tile, as the GPU reads it: the arena slot
/// `TileArenaSlot.treeInstances`, mirrored by `TreeInstance` in
/// Trees.metal, 16 bytes. A tile's trees are sorted by their priority
/// (`TreeScatter`), so the frame thins a tile by drawing a prefix of them.
struct TreeInstance: Sendable, Equatable {
    /// Where the trunk meets the ground, in render space (x east, y up),
    /// tile units.
    var position: SIMD2<Float>
    /// The tree's height in tile units at the tile's zoom: the model is
    /// scaled so its own height spans this.
    var height: Float
    /// The turn about the trunk in the low 16 bits (0 to 65535 for 0 to a
    /// full turn), the tint in the next 8 (0 to 255 from the darkest to
    /// the lightest of the model's colour), the rest reserved.
    var packed: UInt32

    init(position: SIMD2<Float>, height: Float, rotation: Float, tint: Float) {
        self.position = position
        self.height = height
        let turn = rotation.truncatingRemainder(dividingBy: 1)
        let rotationBits = UInt32(min(max(turn < 0 ? turn + 1 : turn, 0), 1) * 65535)
        let tintBits = UInt32(min(max(tint, 0), 1) * 255)
        packed = rotationBits | (tintBits << 16)
    }

    /// The turn about the trunk, 0 to 1 for 0 to a full turn.
    var rotation: Float {
        Float(packed & 0xFFFF) / 65535
    }

    /// The tint, 0 to 1.
    var tint: Float {
        Float((packed >> 16) & 0xFF) / 255
    }
}
