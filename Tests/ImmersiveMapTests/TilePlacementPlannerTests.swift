// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import MetalKit
import XCTest

final class TilePlacementPlannerTests: XCTestCase {
    func testBuildPlacementsUsesCurrentReadyParentForMissingTile() throws {
        let parentTile = Tile(x: 8, y: 5, z: 4)
        let targetTile = Tile(x: 34, y: 22, z: 6)
        let target = VisibleTile(tile: targetTile)
        let parentMetalTile = MetalTile(tile: parentTile, tileBuffers: try makeTileBuffers())

        let context = TilePlacementPlanner.buildPlacements(
            targets: [target],
            readyTilesBySource: [
                targetTile: nil,
                parentTile: parentMetalTile
            ],
            zoom: 6,
            previousContext: .empty
        )

        XCTAssertEqual(context.tilePlacements.count, 1)
        guard let placement = context.tilePlacements.first else {
            return
        }
        XCTAssertEqual(placement.metalTile.tile, parentTile)
        XCTAssertEqual(placement.placeIn.tile, targetTile)
        XCTAssertEqual(placement.lodKind, .retainedReplacement)
    }

    func testBuildPlacementsPrefersMostDetailedCurrentReadyParent() throws {
        let coarseParentTile = Tile(x: 4, y: 2, z: 3)
        let detailedParentTile = Tile(x: 8, y: 5, z: 4)
        let targetTile = Tile(x: 34, y: 22, z: 6)
        let target = VisibleTile(tile: targetTile)
        let coarseParentMetalTile = MetalTile(tile: coarseParentTile, tileBuffers: try makeTileBuffers())
        let detailedParentMetalTile = MetalTile(tile: detailedParentTile, tileBuffers: try makeTileBuffers())

        let context = TilePlacementPlanner.buildPlacements(
            targets: [target],
            readyTilesBySource: [
                targetTile: nil,
                coarseParentTile: coarseParentMetalTile,
                detailedParentTile: detailedParentMetalTile
            ],
            zoom: 6,
            previousContext: .empty
        )

        XCTAssertEqual(context.tilePlacements.count, 1)
        guard let placement = context.tilePlacements.first else {
            return
        }
        XCTAssertEqual(placement.metalTile.tile, detailedParentTile)
        XCTAssertEqual(placement.placeIn.tile, targetTile)
        XCTAssertEqual(placement.lodKind, .retainedReplacement)
    }

    func testBuildPlacementsKeepsRetainedAncestorOnZoomOut() throws {
        let ancestorTile = Tile(x: 2, y: 1, z: 2)
        let previousTargetTile = Tile(x: 34, y: 22, z: 6)
        let targetTile = Tile(x: 17, y: 11, z: 5)
        let ancestorMetalTile = MetalTile(tile: ancestorTile, tileBuffers: try makeTileBuffers())
        let previousContext = PlaceTilesContext(tilePlacements: [
            PlaceTile(metalTile: ancestorMetalTile,
                      placeIn: VisibleTile(tile: previousTargetTile),
                      lodKind: .retainedReplacement)
        ])

        let context = TilePlacementPlanner.buildPlacements(
            targets: [VisibleTile(tile: targetTile)],
            readyTilesBySource: [targetTile: nil],
            zoom: 5,
            previousContext: previousContext
        )

        XCTAssertEqual(context.tilePlacements.count, 1)
        guard let placement = context.tilePlacements.first else {
            return
        }
        XCTAssertEqual(placement.metalTile.tile, ancestorTile)
        XCTAssertEqual(placement.placeIn.tile, targetTile)
        XCTAssertEqual(placement.lodKind, .retainedReplacement)
    }

    func testBuildPlacementsPrefersRetainedChildrenOverAncestorOnZoomOutWhenChildrenCoverTarget() throws {
        let ancestorTile = Tile(x: 2, y: 1, z: 2)
        let childTiles = [
            Tile(x: 34, y: 22, z: 6),
            Tile(x: 35, y: 22, z: 6),
            Tile(x: 34, y: 23, z: 6),
            Tile(x: 35, y: 23, z: 6)
        ]
        let targetTile = Tile(x: 17, y: 11, z: 5)
        let ancestorMetalTile = MetalTile(tile: ancestorTile, tileBuffers: try makeTileBuffers())
        var previousPlacements = try childTiles.map { childTile in
            PlaceTile(metalTile: MetalTile(tile: childTile, tileBuffers: try makeTileBuffers()),
                      placeIn: VisibleTile(tile: childTile),
                      lodKind: .exact)
        }
        previousPlacements.append(PlaceTile(metalTile: ancestorMetalTile,
                                            placeIn: VisibleTile(tile: Tile(x: 36, y: 22, z: 6)),
                                            lodKind: .retainedReplacement))
        let previousContext = PlaceTilesContext(tilePlacements: previousPlacements)

        let context = TilePlacementPlanner.buildPlacements(
            targets: [VisibleTile(tile: targetTile)],
            readyTilesBySource: [targetTile: nil],
            zoom: 5,
            previousContext: previousContext
        )

        XCTAssertEqual(context.tilePlacements.count, 4)
        XCTAssertEqual(Set(context.tilePlacements.map(\.metalTile.tile)), Set(childTiles))
        XCTAssertTrue(context.tilePlacements.allSatisfy { $0.lodKind == .retainedReplacement })
    }

    func testBuildPlacementsFallsBackToAncestorOnZoomOutWhenChildrenCoverTargetPartially() throws {
        let ancestorTile = Tile(x: 2, y: 1, z: 2)
        let childTile = Tile(x: 34, y: 22, z: 6)
        let targetTile = Tile(x: 17, y: 11, z: 5)
        let ancestorMetalTile = MetalTile(tile: ancestorTile, tileBuffers: try makeTileBuffers())
        let childMetalTile = MetalTile(tile: childTile, tileBuffers: try makeTileBuffers())
        let previousContext = PlaceTilesContext(tilePlacements: [
            PlaceTile(metalTile: childMetalTile,
                      placeIn: VisibleTile(tile: childTile),
                      lodKind: .exact),
            PlaceTile(metalTile: ancestorMetalTile,
                      placeIn: VisibleTile(tile: Tile(x: 35, y: 22, z: 6)),
                      lodKind: .retainedReplacement)
        ])

        let context = TilePlacementPlanner.buildPlacements(
            targets: [VisibleTile(tile: targetTile)],
            readyTilesBySource: [targetTile: nil],
            zoom: 5,
            previousContext: previousContext
        )

        // Один прежний ребёнок закрывает четверть таргета — целиком регион
        // может показать только удерживаемый предок.
        XCTAssertEqual(context.tilePlacements.count, 1)
        guard let placement = context.tilePlacements.first else {
            return
        }
        XCTAssertEqual(placement.metalTile.tile, ancestorTile)
        XCTAssertEqual(placement.placeIn.tile, targetTile)
        XCTAssertEqual(placement.lodKind, .retainedReplacement)
    }

    func testBuildPlacementsCoverageIgnoresNestedSourcesOnZoomOut() throws {
        // 3 ребёнка z6 (75% площади) + 4 тайла z7, вложенных в первого ребёнка:
        // сумма долей без учёта вложенности дала бы ровно 1.0, но реальное
        // объединение — 75%, и целиком регион закрывает только предок.
        let ancestorTile = Tile(x: 2, y: 1, z: 2)
        let targetTile = Tile(x: 17, y: 11, z: 5)
        let childTiles = [
            Tile(x: 34, y: 22, z: 6),
            Tile(x: 35, y: 22, z: 6),
            Tile(x: 34, y: 23, z: 6)
        ]
        let nestedTiles = [
            Tile(x: 68, y: 44, z: 7),
            Tile(x: 69, y: 44, z: 7),
            Tile(x: 68, y: 45, z: 7),
            Tile(x: 69, y: 45, z: 7)
        ]
        var previousPlacements = try (childTiles + nestedTiles).map { tile in
            PlaceTile(metalTile: MetalTile(tile: tile, tileBuffers: try makeTileBuffers()),
                      placeIn: VisibleTile(tile: tile),
                      lodKind: .exact)
        }
        let ancestorMetalTile = MetalTile(tile: ancestorTile, tileBuffers: try makeTileBuffers())
        previousPlacements.append(PlaceTile(metalTile: ancestorMetalTile,
                                            placeIn: VisibleTile(tile: Tile(x: 35, y: 23, z: 6)),
                                            lodKind: .retainedReplacement))
        let previousContext = PlaceTilesContext(tilePlacements: previousPlacements)

        let context = TilePlacementPlanner.buildPlacements(
            targets: [VisibleTile(tile: targetTile)],
            readyTilesBySource: [targetTile: nil],
            zoom: 5,
            previousContext: previousContext
        )

        XCTAssertEqual(context.tilePlacements.count, 1)
        guard let placement = context.tilePlacements.first else {
            return
        }
        XCTAssertEqual(placement.metalTile.tile, ancestorTile)
        XCTAssertEqual(placement.placeIn.tile, targetTile)
    }

    func testBuildPlacementsPrefersUnclippedRetainedSourceOverClippedPartialCarries() throws {
        // Source == таргет удержан из прошлого контекста, но размещён в двух
        // клипнутых дочерних слотах — реально закрашена лишь половина таргета.
        // Полное покрытие даёт bestFullReplacement тем же тайлом без клипа.
        let targetTile = Tile(x: 17, y: 11, z: 5)
        let childA = Tile(x: 34, y: 22, z: 6)
        let childB = Tile(x: 35, y: 22, z: 6)
        let retainedMetalTile = MetalTile(tile: targetTile, tileBuffers: try makeTileBuffers())
        let previousContext = PlaceTilesContext(tilePlacements: [
            PlaceTile(metalTile: retainedMetalTile,
                      placeIn: VisibleTile(tile: childA),
                      lodKind: .retainedReplacement),
            PlaceTile(metalTile: retainedMetalTile,
                      placeIn: VisibleTile(tile: childB),
                      lodKind: .retainedReplacement)
        ])

        let context = TilePlacementPlanner.buildPlacements(
            targets: [VisibleTile(tile: targetTile)],
            readyTilesBySource: [targetTile: nil],
            zoom: 5,
            previousContext: previousContext
        )

        XCTAssertEqual(context.tilePlacements.count, 1)
        XCTAssertEqual(context.tilePlacements.first?.metalTile.tile, targetTile)
        XCTAssertEqual(context.tilePlacements.first?.placeIn.tile, targetTile)
    }

    func testBuildPlacementsPrefersDetailedRetainedCoveringSourceOverCoarserReadyParent() throws {
        // «чётко → мыло»: удерживаемый детальный source не должен уступать
        // только что материализовавшемуся более грубому родителю из кэша.
        let retainedTile = Tile(x: 17, y: 11, z: 5)
        let readyParentTile = Tile(x: 4, y: 2, z: 3)
        let targetTile = Tile(x: 34, y: 22, z: 6)
        let retainedMetalTile = MetalTile(tile: retainedTile, tileBuffers: try makeTileBuffers())
        let readyParentMetalTile = MetalTile(tile: readyParentTile, tileBuffers: try makeTileBuffers())
        let previousContext = PlaceTilesContext(tilePlacements: [
            PlaceTile(metalTile: retainedMetalTile,
                      placeIn: VisibleTile(tile: targetTile),
                      lodKind: .retainedReplacement)
        ])

        let context = TilePlacementPlanner.buildPlacements(
            targets: [VisibleTile(tile: targetTile)],
            readyTilesBySource: [
                targetTile: nil,
                readyParentTile: readyParentMetalTile
            ],
            zoom: 6,
            previousContext: previousContext
        )

        XCTAssertEqual(context.tilePlacements.count, 1)
        XCTAssertEqual(context.tilePlacements.first?.metalTile.tile, retainedTile)
        XCTAssertEqual(context.tilePlacements.first?.placeIn.tile, targetTile)
        XCTAssertEqual(context.tilePlacements.first?.lodKind, .retainedReplacement)
    }

    func testBuildPlacementsPrefersReadyParentOverCoarserRetainedSource() throws {
        let retainedAncestorTile = Tile(x: 2, y: 1, z: 2)
        let readyParentTile = Tile(x: 17, y: 11, z: 5)
        let targetTile = Tile(x: 34, y: 22, z: 6)
        let retainedAncestorMetalTile = MetalTile(tile: retainedAncestorTile, tileBuffers: try makeTileBuffers())
        let readyParentMetalTile = MetalTile(tile: readyParentTile, tileBuffers: try makeTileBuffers())
        let previousContext = PlaceTilesContext(tilePlacements: [
            PlaceTile(metalTile: retainedAncestorMetalTile,
                      placeIn: VisibleTile(tile: targetTile),
                      lodKind: .retainedReplacement)
        ])

        let context = TilePlacementPlanner.buildPlacements(
            targets: [VisibleTile(tile: targetTile)],
            readyTilesBySource: [
                targetTile: nil,
                readyParentTile: readyParentMetalTile
            ],
            zoom: 6,
            previousContext: previousContext
        )

        XCTAssertEqual(context.tilePlacements.count, 1)
        XCTAssertEqual(context.tilePlacements.first?.metalTile.tile, readyParentTile)
        XCTAssertEqual(context.tilePlacements.first?.placeIn.tile, targetTile)
        XCTAssertEqual(context.tilePlacements.first?.lodKind, .retainedReplacement)
    }

    private func makeTileBuffers() throws -> TileBuffers {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for MetalTile test fixture.")
        }
        let value: UInt32 = 0
        let buffer = device.makeBuffer(bytes: [value], length: MemoryLayout<UInt32>.stride)!
        let ground = TileBuffers.GeometryLayer(verticesBuffer: buffer,
                                               indicesBuffer: buffer,
                                               stylesBuffer: buffer,
                                               overviewStyleMaskBuffer: buffer,
                                               indicesCount: 0,
                                               verticesCount: 0)
        let extruded = TileBuffers.Extruded(verticesBuffer: buffer,
                                            indicesBuffer: buffer,
                                            stylesBuffer: buffer,
                                            indicesCount: 0,
                                            verticesCount: 0)
        let phases = RoadGeometryPhases(shadow: ground,
                                        casing: ground,
                                        fill: ground,
                                        detail: ground,
                                        overlay: ground)
        let roads = RoadStructureBuckets(tunnel: phases,
                                         ground: phases,
                                         bridge: phases)
        return TileBuffers(ground: ground,
                           roads: roads,
                           bridgeOverlay: ground,
                           extruded: extruded,
                           textLabels: TileBuffers.TextLabels(full: emptyTextLabelSet(),
                                                               reduced: emptyTextLabelSet(),
                                                               minimal: emptyTextLabelSet()),
                           roadLabels: TileBuffers.RoadLabels(pathInputs: [],
                                                              pathRanges: [],
                                                              pathLabels: [],
                                                              labelStyle: nil,
                                                              localGlyphVerticesBuffer: nil,
                                                              localGlyphVertexCount: 0,
                                                              glyphBounds: [],
                                                              glyphBoundRanges: [],
                                                              sizes: [],
                                                              anchorRanges: [],
                                                              anchors: []))
    }

    private func emptyTextLabelSet() -> TileBuffers.TextLabelSet {
        TileBuffers.TextLabelSet(placementInputs: [],
                                 labelsByStyleRuns: [],
                                 poiIconRuns: [])
    }
}
