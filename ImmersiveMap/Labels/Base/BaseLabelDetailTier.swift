// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

enum BaseLabelDetailTier: UInt8, CaseIterable, Equatable {
    case full
    case reduced
    case minimal

    static func tier(forRelativeDistance distance: Int) -> BaseLabelDetailTier {
        if distance <= 2 { return .full }
        if distance <= 7 { return .reduced }
        return .minimal
    }

    /// Абсолютный бюджет якорных подписей (места, вода, пики) на тайл в тире.
    /// Абсолютные числа выравнивают экранную плотность: плотный тайл отдаёт
    /// ровно бюджет, разреженный - всё своё, и границы тайлов не дают швов.
    /// Порядок расходования - приоритет коллизий, поэтому бюджет забирают
    /// самые важные фичи. `nil` - без ограничения.
    static func anchorLabelBudget(tier: BaseLabelDetailTier) -> Int? {
        switch tier {
        case .full:
            return nil
        case .reduced:
            return 12
        case .minimal:
            return 4
        }
    }

    /// Абсолютный бюджет POI на тайл в тире: в среднем тире тайл отдаёт лишь
    /// горстку лучших по рангу заведений (крупные целиком, мелочь иконками),
    /// в дальнем POI не живут вовсе. Внутри POI приоритет коллизий совпадает
    /// с локальным рангом OpenMapTiles, поэтому бюджет распределяется по
    /// тайлу равномерно, а не из одного угла.
    static func poiLabelBudget(tier: BaseLabelDetailTier) -> Int? {
        switch tier {
        case .full:
            return nil
        case .reduced:
            return 12
        case .minimal:
            return 0
        }
    }

    static func relativeDistance(tile: VisibleTile, center: Center, renderSurfaceMode: ViewMode) -> Int {
        VisibleTileRelativeDistance.compute(tile: tile,
                                            center: center,
                                            renderSurfaceMode: renderSurfaceMode)
    }

    /// Дистанция от центра вида до ближайшей точки тайла-владельца, в тайлах
    /// ЗУМА ВИДА. Считать в единицах зума вида принципиально: грубый родитель
    /// дальней полосы в собственных единицах «рядом» с центром и получал бы
    /// ближний тир со всем своим набором лейблов без бюджета.
    static func relativeDistance(tile: VisibleTile,
                                 center: Center,
                                 centerZoom: Int,
                                 renderSurfaceMode: ViewMode) -> Int {
        let tileSpan = Double(sign: .plus, exponent: centerZoom - tile.z, significand: 1)
        let worldSize = Double(sign: .plus, exponent: centerZoom, significand: 1)
        let baseX = (Double(tile.x) + Double(tile.loop) * Double(1 << tile.z)) * tileSpan
        let minY = Double(tile.y) * tileSpan
        let dy = max(0.0, max(minY - center.tileY, center.tileY - (minY + tileSpan)))

        func xDistance(offset: Double) -> Double {
            let minX = baseX + offset
            return max(0.0, max(minX - center.tileX, center.tileX - (minX + tileSpan)))
        }

        let dx: Double
        switch renderSurfaceMode {
        case .flat:
            dx = xDistance(offset: 0)
        case .spherical:
            dx = min(xDistance(offset: 0),
                     min(xDistance(offset: worldSize), xDistance(offset: -worldSize)))
        }
        return Int(max(dx, dy))
    }

}
