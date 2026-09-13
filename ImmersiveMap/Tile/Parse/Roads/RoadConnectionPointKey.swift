// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// A road vertex rounded to the tile grid, the key the junction counts and
/// the street stitcher match endpoints by.
struct RoadConnectionPointKey: Hashable {
    let x: Int32
    let y: Int32

    init(point: SIMD2<Float>) {
        x = Int32(point.x.rounded())
        y = Int32(point.y.rounded())
    }
}
