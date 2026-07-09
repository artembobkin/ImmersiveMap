// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct ParsedPolygon {
        var vertices: [SIMD2<Int16>] = []
        var indices: [UInt32] = []
    }
}
