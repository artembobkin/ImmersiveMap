// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import simd

/// Прямоугольник клипа фрагментов в локальных координатах source-тайла (0..4096).
/// Retained-подмена рисует source-тайл целиком по его собственному origin - без
/// клипа контент за пределами слота `placeIn` перекрывал бы соседние точные тайлы
/// (в глобусном атласе ту же роль играют scissor ячейки и discard в шейдере).
enum TileLocalClipMath {
    static let tileExtent: Float = 4096.0

    /// Отключённый клип: exact-размещения рисуются целиком, включая сшивочный
    /// margin геометрии за пределами 0..4096.
    static let disabledBounds = SIMD4<Float>(-Float.greatestFiniteMagnitude,
                                             -Float.greatestFiniteMagnitude,
                                             Float.greatestFiniteMagnitude,
                                             Float.greatestFiniteMagnitude)

    /// (minX, minY, maxX, maxY) области `placeIn` внутри `source` в локальных
    /// единицах source-тайла. Для `placeIn == source` клип отключается.
    /// Парсер сохраняет вершины с флипом Y (`tileExtent - y`): локальный y=0 -
    /// ЮЖНАЯ кромка тайла, тогда как тайловый индекс y растёт к югу, поэтому
    /// y-диапазон области зеркалируется относительно tileExtent.
    static func clipBounds(source: Tile, placeIn: Tile) -> SIMD4<Float> {
        let depth = placeIn.z - source.z
        guard depth > 0, depth < 30 else {
            return disabledBounds
        }

        let cellSize = tileExtent / Float(1 << depth)
        let offsetX = Float(placeIn.x - (source.x << depth))
        let offsetY = Float(placeIn.y - (source.y << depth))
        return SIMD4<Float>(offsetX * cellSize,
                            tileExtent - (offsetY + 1) * cellSize,
                            (offsetX + 1) * cellSize,
                            tileExtent - offsetY * cellSize)
    }
}
