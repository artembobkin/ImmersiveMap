// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

enum VisibleTileRelativeDistance {
    static func compute(tile: VisibleTile, center: Center, renderSurfaceMode: ViewMode) -> Int {
        let centerX = Int(center.tileX)
        let centerY = Int(center.tileY)

        switch renderSurfaceMode {
        case .spherical:
            let tilesCount = 1 << tile.z
            let normalizedCenterX = normalizeWrappedIndex(centerX, modulo: tilesCount)
            let directDistance = abs(normalizedCenterX - tile.x)
            let wrappedDistance = tilesCount - directDistance
            let relX = min(directDistance, wrappedDistance)
            let relY = abs(centerY - tile.y)
            return max(relX, relY)
        case .flat:
            let tilesCount = 1 << tile.z
            let worldX = tile.x + Int(tile.loop) * tilesCount
            let relX = abs(centerX - worldX)
            let relY = abs(centerY - tile.y)
            return max(relX, relY)
        }
    }

    private static func normalizeWrappedIndex(_ value: Int, modulo: Int) -> Int {
        let normalized = value % modulo
        return normalized >= 0 ? normalized : normalized + modulo
    }
}
