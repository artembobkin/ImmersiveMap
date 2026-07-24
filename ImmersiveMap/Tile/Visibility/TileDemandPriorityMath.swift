// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Порядок сетевого спроса тайлов: от ближайших к центру камеры к дальним.
/// Загрузчик и очередь парсинга сохраняют переданный порядок, поэтому именно
/// эта сортировка определяет, какие тайлы стартуют в сеть первыми и кто
/// первым получает парс-слот. Метрика - чебышёвское расстояние в
/// нормализованных мировых координатах: сравнима между таргетами разных
/// зумов (дистанционный LOD выдаёт смешанные z).
enum TileDemandPriorityMath {
    static func sortedByCameraProximity(_ targets: [VisibleTile],
                                        centerWorldMercator: SIMD2<Double>,
                                        renderSurfaceMode: ViewMode) -> [VisibleTile] {
        let wrappedCenterX = ImmersiveMapProjection.wrapNormalizedWorldX(centerWorldMercator.x)
        let clampedCenterY = ImmersiveMapProjection.clampNormalizedWorldY(centerWorldMercator.y)

        func normalizedDistance(_ target: VisibleTile) -> Double {
            let tilesCount = Double(1 << target.z)
            let tileCenterX = (Double(target.x) + 0.5) / tilesCount
            let tileCenterY = (Double(target.y) + 0.5) / tilesCount

            let dx: Double
            switch renderSurfaceMode {
            case .spherical:
                let direct = abs(wrappedCenterX - tileCenterX)
                dx = min(direct, 1.0 - direct)
            case .flat:
                dx = abs(wrappedCenterX - (tileCenterX + Double(target.loop)))
            }
            let dy = abs(clampedCenterY - tileCenterY)
            return max(dx, dy)
        }

        return targets
            .map { (target: $0, distance: normalizedDistance($0)) }
            .sorted { lhs, rhs in
                if lhs.distance != rhs.distance {
                    return lhs.distance < rhs.distance
                }
                let left = lhs.target
                let right = rhs.target
                if left.z != right.z {
                    return left.z > right.z
                }
                if left.loop != right.loop {
                    return left.loop < right.loop
                }
                if left.x != right.x {
                    return left.x < right.x
                }
                return left.y < right.y
            }
            .map(\.target)
    }
}
