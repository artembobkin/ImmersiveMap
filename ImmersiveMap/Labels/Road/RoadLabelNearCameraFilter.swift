// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Решает, достоин ли тайл дорожных подписей, по его ВИДИМОЙ экранной площади:
/// четырёхугольник тайла клипится в однородных координатах по near-плоскости и
/// границам вьюпорта, и метрики считаются по тому, что реально на экране.
/// Поэтому ближний тайл, уходящий углами за камеру, оценивается честно своей
/// огромной видимой частью, а не вырожденной проекцией углов.
enum RoadLabelNearCameraFilter {
    /// Минимальная видимая площадь: меньше эквивалента квадрата 300x300 px -
    /// тайл занимает слишком мало экрана, чтобы его дорожные подписи читались.
    private static let minimumVisibleAreaPx: Float = 300 * 300

    /// Минимальная видимая площадь НА ЭКВИВАЛЕНТ ТАЙЛА ЦЕЛЕВОГО ЗУМА
    /// (видимая площадь / 4^недозум). Грубый родитель дальней полосы может
    /// занимать пол-экрана, но мир в нём ужат в 4^N раз, и подписи вдоль его
    /// дорог вырождены. Нормировка зум-агностична и переживает смену maxzoom
    /// источника.
    private static let minimumVisibleAreaPerNativeTilePx: Float = 200 * 200

    /// Минимальный коэффициент сжатия видимого полигона (площадь / квадрат
    /// длинного ребра): сплюснутая перспективой лента отклоняется независимо
    /// от площади. Калибровка: квадрат сверху 1.0, ближний тайл при
    /// максимальном наклоне ~0.1-0.15, лента у горизонта 0.02-0.05.
    private static let minimumProjectedCompressionRatio: Float = 0.07

    static func shouldKeepTile(clipCorners: [SIMD4<Float>],
                               viewportWidth: Float,
                               viewportHeight: Float,
                               underzoomLevels: Int = 0) -> Bool {
        guard clipCorners.count == 4,
              viewportWidth.isFinite,
              viewportWidth > 0,
              viewportHeight.isFinite,
              viewportHeight > 0 else {
            return false
        }

        let visiblePolygon = clipToViewport(polygon: clipCorners)
        guard visiblePolygon.count >= 3 else {
            return false
        }

        let viewport = SIMD2<Float>(viewportWidth, viewportHeight)
        let screenPoints = visiblePolygon.map { vertex -> SIMD2<Float> in
            let ndc = SIMD2<Float>(vertex.x, vertex.y) / vertex.w
            return (ndc * 0.5 + 0.5) * viewport
        }

        let longestEdge = longestEdgeLength(points: screenPoints)
        guard longestEdge > .ulpOfOne else {
            return false
        }

        let visibleArea = polygonArea(points: screenPoints)
        let contentScale = Float(1 << (2 * min(max(underzoomLevels, 0), 10)))
        let compressionRatio = visibleArea / (longestEdge * longestEdge)
        return visibleArea >= minimumVisibleAreaPx
            && visibleArea / contentScale >= minimumVisibleAreaPerNativeTilePx
            && compressionRatio >= minimumProjectedCompressionRatio
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

    /// Sutherland-Hodgman в однородных координатах: сначала near-плоскость
    /// (w > 0, точки за камерой отсекаются до перспективного деления), затем
    /// четыре границы NDC-вьюпорта.
    private static func clipToViewport(polygon: [SIMD4<Float>]) -> [SIMD4<Float>] {
        let planes: [(SIMD4<Float>) -> Float] = [
            { $0.w - 1e-4 },
            { $0.w + $0.x },
            { $0.w - $0.x },
            { $0.w + $0.y },
            { $0.w - $0.y }
        ]

        var clipped = polygon
        for plane in planes {
            guard clipped.count >= 3 else {
                return []
            }
            var next: [SIMD4<Float>] = []
            next.reserveCapacity(clipped.count + 1)
            for index in clipped.indices {
                let current = clipped[index]
                let following = clipped[(index + 1) % clipped.count]
                let currentDistance = plane(current)
                let followingDistance = plane(following)
                if currentDistance >= 0 {
                    next.append(current)
                }
                if (currentDistance >= 0) != (followingDistance >= 0) {
                    let t = currentDistance / (currentDistance - followingDistance)
                    next.append(current + (following - current) * t)
                }
            }
            clipped = next
        }
        return clipped
    }

    private static func polygonArea(points: [SIMD2<Float>]) -> Float {
        guard points.count >= 3 else {
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

    private static func longestEdgeLength(points: [SIMD2<Float>]) -> Float {
        var longestEdge: Float = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            longestEdge = max(longestEdge, simd_length(next - current))
        }
        return longestEdge
    }
}
