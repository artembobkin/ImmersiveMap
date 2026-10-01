// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// A base label as the collision solve ranks it, fixed when the working set
/// is packed: the box in layout points, the rank, and the key that is the
/// group its copies from other tiles share.
struct ScreenCollisionCandidate {
    var position: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var priority: Int
    var secondaryPriority: Int
    var sortPriority: Int
    var stableOrderKey: UInt64
    var groupId: UInt64
    var isEnabled: Bool

    init(position: SIMD2<Float>,
         halfSize: SIMD2<Float>,
         priority: Int = .max,
         secondaryPriority: Int = .max,
         sortPriority: Int = .max,
         stableOrderKey: UInt64 = UInt64.max,
         groupId: UInt64 = 0,
         isEnabled: Bool) {
        self.position = position
        self.halfSize = halfSize
        self.priority = priority
        self.secondaryPriority = secondaryPriority
        self.sortPriority = sortPriority
        self.stableOrderKey = stableOrderKey
        self.groupId = groupId
        self.isEnabled = isEnabled
    }
}
