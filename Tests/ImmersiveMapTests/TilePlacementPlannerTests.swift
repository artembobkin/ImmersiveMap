// Copyright (c) 2025-2026 ImmersiveMap contributors.
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

        // A single previous child covers a quarter of the target, so only the
        // retained ancestor can show the region in full.
        XCTAssertEqual(context.tilePlacements.count, 1)
        guard let placement = context.tilePlacements.first else {
            return
        }
        XCTAssertEqual(placement.metalTile.tile, ancestorTile)
        XCTAssertEqual(placement.placeIn.tile, targetTile)
        XCTAssertEqual(placement.lodKind, .retainedReplacement)
    }

    func testBuildPlacementsCoverageIgnoresNestedSourcesOnZoomOut() throws {
        // 3 z6 children (75% of the area) + 4 z7 tiles nested inside the first
        // child: the sum of shares ignoring nesting would come to exactly 1.0,
        // but the real union is 75%, and only the ancestor covers the whole region.
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
        // Source == target is retained from the previous context but placed in
        // two clipped child slots, so only half of the target is actually
        // painted. Full coverage comes from bestFullReplacement with the same
        // tile unclipped.
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
        // "Sharp → blur": a retained detailed source must not lose to a coarser
        // parent that has just materialized from the cache.
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

    func testBuildPlacementsKeepsPartialRetainedChildrenOverBackdropLevelParent() throws {
        let backdropTile = Tile(x: 2, y: 1, z: 3)
        let childTile = Tile(x: 68, y: 44, z: 7)
        let targetTile = Tile(x: 34, y: 22, z: 6)
        let backdropMetalTile = MetalTile(tile: backdropTile, tileBuffers: try makeTileBuffers())
        let childMetalTile = MetalTile(tile: childTile, tileBuffers: try makeTileBuffers())
        let previousContext = PlaceTilesContext(tilePlacements: [
            PlaceTile(metalTile: childMetalTile,
                      placeIn: VisibleTile(tile: childTile),
                      lodKind: .exact)
        ])

        let context = TilePlacementPlanner.buildPlacements(
            targets: [VisibleTile(tile: targetTile)],
            readyTilesBySource: [
                targetTile: nil,
                backdropTile: backdropMetalTile
            ],
            zoom: 6,
            previousContext: previousContext,
            backdropZoomLevel: 3
        )

        // A backdrop of the same zoom is already drawn a layer below: partial
        // detail is better than a solid copy of the backdrop on top of it.
        XCTAssertEqual(context.tilePlacements.count, 1)
        XCTAssertEqual(context.tilePlacements.first?.metalTile.tile, childTile)
        XCTAssertEqual(context.tilePlacements.first?.lodKind, .retainedReplacement)
    }

    func testBuildPlacementsStillPrefersUsefulParentOverPartialChildrenWithBackdrop() throws {
        let readyParentTile = Tile(x: 17, y: 11, z: 5)
        let childTile = Tile(x: 68, y: 44, z: 7)
        let targetTile = Tile(x: 34, y: 22, z: 6)
        let readyParentMetalTile = MetalTile(tile: readyParentTile, tileBuffers: try makeTileBuffers())
        let childMetalTile = MetalTile(tile: childTile, tileBuffers: try makeTileBuffers())
        let previousContext = PlaceTilesContext(tilePlacements: [
            PlaceTile(metalTile: childMetalTile,
                      placeIn: VisibleTile(tile: childTile),
                      lodKind: .exact)
        ])

        let context = TilePlacementPlanner.buildPlacements(
            targets: [VisibleTile(tile: targetTile)],
            readyTilesBySource: [
                targetTile: nil,
                readyParentTile: readyParentMetalTile
            ],
            zoom: 6,
            previousContext: previousContext,
            backdropZoomLevel: 3
        )

        // A parent more detailed than the backdrop still wins over holey detail.
        XCTAssertEqual(context.tilePlacements.count, 1)
        XCTAssertEqual(context.tilePlacements.first?.metalTile.tile, readyParentTile)
        XCTAssertEqual(context.tilePlacements.first?.placeIn.tile, targetTile)
    }

    func testBuildPlacementsLeavesUncoveredTargetToBackdropUnderlay() throws {
        let backdropTile = Tile(x: 2, y: 1, z: 3)
        let targetTile = Tile(x: 34, y: 22, z: 6)
        let backdropMetalTile = MetalTile(tile: backdropTile, tileBuffers: try makeTileBuffers())

        let context = TilePlacementPlanner.buildPlacements(
            targets: [VisibleTile(tile: targetTile)],
            readyTilesBySource: [
                targetTile: nil,
                backdropTile: backdropMetalTile
            ],
            zoom: 6,
            previousContext: .empty,
            backdropZoomLevel: 3
        )

        // No content at all: no point drawing a copy of the backdrop over the backdrop.
        XCTAssertTrue(context.tilePlacements.isEmpty)
    }

    func testBuildPlacementsBackdropLevelRetainedSourceDoesNotPoisonPartialCoverage() throws {
        // Zoom-out regression: a slot that fell to backdrop zoom in the previous
        // frame does not count as coverage (source outside the target) and must
        // not clobber detailed partial slots again via bestFullReplacement.
        let backdropTile = Tile(x: 4, y: 2, z: 3)
        let detailedChildTiles = [
            Tile(x: 34, y: 22, z: 6),
            Tile(x: 35, y: 22, z: 6),
            Tile(x: 34, y: 23, z: 6)
        ]
        let poisonedChildSlot = Tile(x: 35, y: 23, z: 6)
        let targetTile = Tile(x: 17, y: 11, z: 5)
        var previousPlacements = try detailedChildTiles.map { childTile in
            PlaceTile(metalTile: MetalTile(tile: childTile, tileBuffers: try makeTileBuffers()),
                      placeIn: VisibleTile(tile: childTile),
                      lodKind: .exact)
        }
        previousPlacements.append(PlaceTile(metalTile: MetalTile(tile: backdropTile,
                                                                 tileBuffers: try makeTileBuffers()),
                                            placeIn: VisibleTile(tile: poisonedChildSlot),
                                            lodKind: .retainedReplacement))
        let previousContext = PlaceTilesContext(tilePlacements: previousPlacements)

        let context = TilePlacementPlanner.buildPlacements(
            targets: [VisibleTile(tile: targetTile)],
            readyTilesBySource: [targetTile: nil],
            zoom: 5,
            previousContext: previousContext,
            backdropZoomLevel: 3
        )

        XCTAssertEqual(context.tilePlacements.count, 3)
        XCTAssertEqual(Set(context.tilePlacements.map(\.metalTile.tile)), Set(detailedChildTiles))
        XCTAssertTrue(context.tilePlacements.allSatisfy { $0.lodKind == .retainedReplacement })
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
                                               verticesCount: 0,
                                               indexType: .uint32)
        let extruded = TileBuffers.Extruded(verticesBuffer: buffer,
                                            indicesBuffer: buffer,
                                            stylesBuffer: buffer,
                                            indicesCount: 0,
                                            verticesCount: 0,
                                            indexType: .uint32)
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
