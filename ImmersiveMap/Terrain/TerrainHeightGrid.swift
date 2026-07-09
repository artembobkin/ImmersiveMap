// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct TerrainHeightGrid: Equatable {
    let width: Int
    let height: Int
    let heightsMeters: [Float]

    init(width: Int, height: Int, heightsMeters: [Float]) {
        precondition(width > 0)
        precondition(height > 0)
        precondition(heightsMeters.count == width * height)
        self.width = width
        self.height = height
        self.heightsMeters = heightsMeters
    }

    func heightAt(x: Int, y: Int) -> Float {
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        return heightsMeters[clampedY * width + clampedX]
    }
}
