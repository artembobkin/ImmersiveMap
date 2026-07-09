// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

enum RoadLabelNearCameraFilter {
    private static let minimumProjectedTileThicknessPx: Float = 40

    static func shouldKeepTile(cornerPoints: [ScreenPointOutput],
                               viewportWidth: Float,
                               viewportHeight: Float) -> Bool {
        guard cornerPoints.count == 4,
              viewportWidth.isFinite,
              viewportWidth > 0,
              viewportHeight.isFinite,
              viewportHeight > 0 else {
            return false
        }

        let points = cornerPoints.map(\.position)
        let thickness = projectedThickness(points: points)
        return thickness >= minimumProjectedTileThicknessPx
    }

    static func makeTileCornerInputs(tile: VisibleTile) -> [TilePointInput] {
        let tileVector = SIMD3<Int32>(Int32(tile.x), Int32(tile.y), Int32(tile.z))
        return [
            TilePointInput(uv: SIMD2<Float>(0, 0), tile: tileVector, tileSlotIndex: 0),
            TilePointInput(uv: SIMD2<Float>(1, 0), tile: tileVector, tileSlotIndex: 0),
            TilePointInput(uv: SIMD2<Float>(1, 1), tile: tileVector, tileSlotIndex: 0),
            TilePointInput(uv: SIMD2<Float>(0, 1), tile: tileVector, tileSlotIndex: 0)
        ]
    }

    private static func projectedArea(points: [SIMD2<Float>]) -> Float {
        guard points.count == 4 else {
            return 0
        }

        var doubledArea: Float = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            doubledArea += current.x * next.y - next.x * current.y
        }
        return abs(doubledArea) * 0.5
    }

    private static func projectedThickness(points: [SIMD2<Float>]) -> Float {
        guard points.count == 4 else {
            return 0
        }

        var longestEdgeLength: Float = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            longestEdgeLength = max(longestEdgeLength, simd_length(next - current))
        }

        guard longestEdgeLength > .ulpOfOne else {
            return 0
        }

        return projectedArea(points: points) / longestEdgeLength
    }
}
