// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

enum ScreenCollisionShapeType: UInt32 {
    case rect = 0
    case circle = 1
}

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

struct ScreenCollisionInput {
    var halfSize: SIMD2<Float>
    var radius: Float
    var shapeType: UInt32

    init(halfSize: SIMD2<Float>, radius: Float, shapeType: ScreenCollisionShapeType) {
        self.halfSize = halfSize
        self.radius = radius
        self.shapeType = shapeType.rawValue
    }
}
