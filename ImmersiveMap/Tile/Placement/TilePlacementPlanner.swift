// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

struct TilePlacementPlanner {
    static func buildPlacements(targets: [VisibleTile],
                                readyTilesBySource: [Tile: MetalTile?],
                                zoom: Int,
                                previousContext: PlaceTilesContext) -> PlaceTilesContext {
        var placeTiles: [PlaceTile] = []
        let readyReplacementCandidates = readyTilesBySource.values.compactMap { $0 }.sorted { lhs, rhs in
            if lhs.tile.z != rhs.tile.z {
                return lhs.tile.z > rhs.tile.z
            }
            if lhs.tile.x != rhs.tile.x {
                return lhs.tile.x < rhs.tile.x
            }
            return lhs.tile.y < rhs.tile.y
        }

        for target in targets {
            let sourceTile = target.tile
            let lodKind: TileLodKind = sourceTile.z < zoom ? .coarseSubstitute : .exact
            let metalTile = readyTilesBySource[sourceTile] ?? nil

            func bestFullReplacement() -> MetalTile? {
                var bestReplacement: MetalTile?
                for prev in previousContext.tilePlacements {
                    let prevSourceTile = prev.metalTile.tile

                    // Previous tile fully covers the required tile
                    // (including exact same tile identity).
                    if prevSourceTile == target.tile || prevSourceTile.covers(target.tile) {
                        // Keep the most detailed fallback source among
                        // all covering tiles from the previous frame.
                        if prevSourceTile.z > (bestReplacement?.tile.z ?? Int.min) {
                            bestReplacement = prev.metalTile
                        }
                    }
                }
                return bestReplacement
            }

            func collectPartialReplacements() -> (placements: [PlaceTile], coversTarget: Bool) {
                var partialPlacements: [PlaceTile] = []
                var uniquePlaceInTiles: Set<Tile> = []
                for prev in previousContext.tilePlacements {
                    let prevMetalTile = prev.metalTile
                    let prevSourceTile = prev.metalTile.tile

                    // Previous tile is inside the required tile
                    // (including exact same tile identity).
                    // Сравнение по placeIn.loop: контент общий между wrapped-копиями,
                    // но рисуется placement строго в мировой копии своего placeIn -
                    // копию таргета в другом loop он не закрашивает.
                    if prev.placeIn.loop == target.loop,
                       prevSourceTile == target.tile || target.tile.covers(prevSourceTile) {
                        partialPlacements.append(PlaceTile(metalTile: prevMetalTile,
                                                           placeIn: prev.placeIn,
                                                           lodKind: .retainedReplacement))
                        uniquePlaceInTiles.insert(prev.placeIn.tile)
                    }
                }

                // Покрытие - площадь ОБЪЕДИНЕНИЯ слотов placeIn (слот глубины d
                // занимает 1/4^d площади таргета): рисуется ровно область placeIn
                // (фрагментный клип), а не весь source. Слоты разных поколений
                // могут быть вложены - вложенные в уже учтённый более грубый слот
                // площади не добавляют.
                var coveredFraction = 0.0
                var countedPlaceInTiles: [Tile] = []
                for placeInTile in uniquePlaceInTiles.sorted(by: { ($0.z, $0.x, $0.y) < ($1.z, $1.x, $1.y) }) {
                    if countedPlaceInTiles.contains(where: { $0.covers(placeInTile) }) {
                        continue
                    }
                    countedPlaceInTiles.append(placeInTile)
                    let depth = placeInTile.z - target.tile.z
                    coveredFraction += depth >= 30 ? 0 : 1.0 / Double(1 << (2 * depth))
                }
                return (partialPlacements, coveredFraction >= 0.999_999)
            }

            func bestReadyParent() -> MetalTile? {
                for candidate in readyReplacementCandidates {
                    let candidateTile = candidate.tile
                    guard candidateTile != target.tile,
                          candidateTile.covers(target.tile) else {
                        continue
                    }
                    return candidate
                }

                return nil
            }

            // Каскад подмен отсутствующего таргета - по максимуму детальности:
            // 1) прежние тайлы ВНУТРИ таргета (всегда детальнее любого
            //    покрывающего source), но только если закрывают его целиком -
            //    детальный контент с дырами хуже полного грубого;
            // 2) более детальный из: покрывающего source прошлого кадра
            //    (retention, включая сам таргет по strong-ссылке) и готового
            //    родителя из кэша; при равенстве - родитель из кэша (свежее);
            // 3) неполные прежние тайлы - лучше, чем пустой регион.
            // Два source в одном слоте не смешиваются: наложение даёт двойной
            // blend полупрозрачных слоёв (дороги).
            if metalTile == nil {
                let partial = collectPartialReplacements()
                if partial.coversTarget {
                    placeTiles.append(contentsOf: partial.placements)
                    continue
                }

                let readyParent = bestReadyParent()
                let fullReplacement = bestFullReplacement()
                if let fullReplacement, fullReplacement.tile.z > (readyParent?.tile.z ?? Int.min) {
                    placeTiles.append(PlaceTile(metalTile: fullReplacement,
                                                placeIn: target,
                                                lodKind: .retainedReplacement))
                } else if let readyParent {
                    placeTiles.append(PlaceTile(metalTile: readyParent,
                                                placeIn: target,
                                                lodKind: .retainedReplacement))
                } else {
                    placeTiles.append(contentsOf: partial.placements)
                }

                continue
            }

            placeTiles.append(PlaceTile(metalTile: metalTile!,
                                        placeIn: target,
                                        lodKind: lodKind))
        }

        return PlaceTilesContext(tilePlacements: placeTiles)
    }
}
