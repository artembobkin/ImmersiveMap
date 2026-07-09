// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

extension TileMvtParser {
    struct RoadConnectionPointKey: Hashable {
        let x: Int32
        let y: Int32

        init(point: SIMD2<Float>) {
            x = Int32(point.x.rounded())
            y = Int32(point.y.rounded())
        }
    }
}
