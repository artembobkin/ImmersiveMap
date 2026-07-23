// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import MetalKit
import XCTest

final class BaseLabelDetailTierTests: XCTestCase {
    func testTierSelectionUsesDistanceBands() {
        XCTAssertEqual(BaseLabelDetailTier.tier(forRelativeDistance: 0), .full)
        XCTAssertEqual(BaseLabelDetailTier.tier(forRelativeDistance: 2), .full)
        XCTAssertEqual(BaseLabelDetailTier.tier(forRelativeDistance: 3), .reduced)
        XCTAssertEqual(BaseLabelDetailTier.tier(forRelativeDistance: 7), .reduced)
        XCTAssertEqual(BaseLabelDetailTier.tier(forRelativeDistance: 8), .minimal)
    }

    func testTierBudgetsAreAbsoluteAndShrinkWithDistance() {
        // Абсолютные бюджеты: плотный тайл отдаёт ровно бюджет, разреженный
        // всё своё, поэтому экранная плотность не зависит от плотности данных.
        XCTAssertNil(BaseLabelDetailTier.anchorLabelBudget(tier: .full))
        XCTAssertNil(BaseLabelDetailTier.poiLabelBudget(tier: .full))

        XCTAssertEqual(BaseLabelDetailTier.anchorLabelBudget(tier: .reduced), 12)
        XCTAssertEqual(BaseLabelDetailTier.poiLabelBudget(tier: .reduced), 12)

        XCTAssertEqual(BaseLabelDetailTier.anchorLabelBudget(tier: .minimal), 4)
        XCTAssertEqual(BaseLabelDetailTier.poiLabelBudget(tier: .minimal), 0)
    }

    func testRelativeDistanceMatchesFlatLoopAwareDistance() {
        let tile = VisibleTile(x: 2, y: 5, z: 4, loop: 1)
        let center = Center(tileX: 17.2, tileY: 9.1)

        let distance = BaseLabelDetailTier.relativeDistance(tile: tile,
                                                            center: center,
                                                            renderSurfaceMode: .flat)

        XCTAssertEqual(distance, 4)
    }

    func testRelativeDistanceUsesSphericalWrappedSeamDistance() {
        let tile = VisibleTile(x: 0, y: 5, z: 4)
        let center = Center(tileX: 15.4, tileY: 5.0)

        let distance = BaseLabelDetailTier.relativeDistance(tile: tile,
                                                            center: center,
                                                            renderSurfaceMode: .spherical)

        XCTAssertEqual(distance, 1)
    }

    func testRelativeDistanceNormalizesCenterFromHigherZoom() {
        let tile = VisibleTile(x: 8, y: 8, z: 4)
        let center = Center(tileX: 32.4, tileY: 32.2)

        let distance = BaseLabelDetailTier.relativeDistance(tile: tile,
                                                            center: center,
                                                            centerZoom: 6,
                                                            renderSurfaceMode: .flat)

        XCTAssertEqual(distance, 0)
        XCTAssertEqual(BaseLabelDetailTier.tier(forRelativeDistance: distance), .full)
    }

    func testSourceEntryBuildKeepsFullerTierForDuplicateOwnerKey() throws {
        let metalTile = MetalTile(tile: Tile(x: 8, y: 8, z: 4),
                                  tileBuffers: try makeTileBuffers())
        let nearPlaceTile = PlaceTile(metalTile: metalTile,
                                      placeIn: VisibleTile(x: 32, y: 32, z: 6),
                                      lodKind: .retainedReplacement)
        let farPlaceTile = PlaceTile(metalTile: metalTile,
                                     placeIn: VisibleTile(x: 48, y: 48, z: 6),
                                     lodKind: .retainedReplacement)
        let center = Center(tileX: 32.4, tileY: 32.2)

        let nearFirstEntries = BaseLabelSourceEntry.build(from: [nearPlaceTile, farPlaceTile],
                                                          center: center,
                                                          centerZoom: 6,
                                                          renderSurfaceMode: .flat)
        let farFirstEntries = BaseLabelSourceEntry.build(from: [farPlaceTile, nearPlaceTile],
                                                         center: center,
                                                         centerZoom: 6,
                                                         renderSurfaceMode: .flat)

        XCTAssertEqual(nearFirstEntries.count, 1)
        XCTAssertEqual(farFirstEntries.count, 1)
        XCTAssertEqual(nearFirstEntries.first?.labelDetailTier, .full)
        XCTAssertEqual(farFirstEntries.first?.labelDetailTier, .full)
    }

    func testSourceEntryBuildKeepsDifferentOwnerOrderingIndependentFromTier() throws {
        let lowerOwnerTile = MetalTile(tile: Tile(x: 8, y: 8, z: 4),
                                       tileBuffers: try makeTileBuffers())
        let higherOwnerTile = MetalTile(tile: Tile(x: 9, y: 8, z: 4),
                                        tileBuffers: try makeTileBuffers())
        let lowerOwnerMinimal = PlaceTile(metalTile: lowerOwnerTile,
                                          placeIn: VisibleTile(x: 48, y: 48, z: 6),
                                          lodKind: .retainedReplacement)
        let higherOwnerFull = PlaceTile(metalTile: higherOwnerTile,
                                        placeIn: VisibleTile(x: 32, y: 32, z: 6),
                                        lodKind: .retainedReplacement)

        let entries = BaseLabelSourceEntry.build(from: [higherOwnerFull, lowerOwnerMinimal],
                                                 center: Center(tileX: 32.4, tileY: 32.2),
                                                 centerZoom: 6,
                                                 renderSurfaceMode: .flat)

        XCTAssertEqual(entries.map(\.ownerKey.x), [8, 9])
        XCTAssertEqual(entries.map(\.labelDetailTier), [.minimal, .full])
    }

    func testBaseLabelCacheRefreshesPayloadWhenSelectedTierChanges() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for BaseLabelCache test fixture.")
        }

        let ownerKey = VisibleTile(x: 8, y: 8, z: 4)
        let metalTile = MetalTile(tile: ownerKey.tile,
                                  tileBuffers: try makeTileBuffers(textLabels: TileBuffers.TextLabels(
                                      full: makeTextLabelSet(keys: [10, 11, 12]),
                                      reduced: makeTextLabelSet(keys: [20, 21]),
                                      minimal: makeTextLabelSet(keys: [30])
                                  )))
        let tileIndexAllocator = VisibleTileIndexAllocator(indexedTiles: [ownerKey])
        let cache = BaseLabelCache(metalDevice: device)

        cache.rebuild(sourceEntries: [
            BaseLabelSourceEntry(ownerKey: ownerKey,
                                 metalTile: metalTile,
                                 isRetained: false,
                                 lodKind: .exact,
                                 labelDetailTier: .full)
        ], tileIndexAllocator: tileIndexAllocator)

        XCTAssertEqual(cache.labelInputsCount, 3)
        XCTAssertEqual(cache.presentationInputs.prefix(3).map(\.labelKey), [10, 11, 12])

        cache.rebuild(sourceEntries: [
            BaseLabelSourceEntry(ownerKey: ownerKey,
                                 metalTile: metalTile,
                                 isRetained: false,
                                 lodKind: .exact,
                                 labelDetailTier: .minimal)
        ], tileIndexAllocator: tileIndexAllocator)

        XCTAssertEqual(cache.labelInputsCount, 1)
        XCTAssertEqual(cache.presentationInputs.prefix(1).map(\.labelKey), [30])
    }

    func testBaseLabelCacheWritesStableCollisionMetadata() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for BaseLabelCache test fixture.")
        }

        let ownerKey = VisibleTile(x: 8, y: 8, z: 4)
        let metalTile = MetalTile(tile: ownerKey.tile,
                                  tileBuffers: try makeTileBuffers(textLabels: TileBuffers.TextLabels(
                                      full: makeTextLabelSet(keys: [10, 11]),
                                      reduced: makeTextLabelSet(keys: [20]),
                                      minimal: makeTextLabelSet(keys: [30])
                                  )))
        let cache = BaseLabelCache(metalDevice: device)
        cache.rebuild(sourceEntries: [
            BaseLabelSourceEntry(ownerKey: ownerKey,
                                 metalTile: metalTile,
                                 isRetained: false,
                                 lodKind: .exact,
                                 labelDetailTier: .full)
        ], tileIndexAllocator: VisibleTileIndexAllocator(indexedTiles: [ownerKey]))

        let candidates = cache.labelCollisionAABBInputs

        XCTAssertEqual(candidates[0].stableOrderKey, 10)
        XCTAssertEqual(candidates[0].groupId, 10)
        XCTAssertEqual(candidates[0].sortPriority, 0)
        XCTAssertEqual(candidates[1].stableOrderKey, 11)
        XCTAssertEqual(candidates[1].groupId, 11)
        XCTAssertEqual(candidates[1].sortPriority, 1)
    }

    func testSourceEntryHashesKeepTierChangesScopedToBaseLabels() throws {
        let ownerKey = VisibleTile(x: 8, y: 8, z: 4)
        let metalTile = MetalTile(tile: ownerKey.tile,
                                  tileBuffers: try makeTileBuffers())
        let fullEntry = BaseLabelSourceEntry(ownerKey: ownerKey,
                                             metalTile: metalTile,
                                             isRetained: false,
                                             lodKind: .exact,
                                             labelDetailTier: .full)
        let minimalEntry = BaseLabelSourceEntry(ownerKey: ownerKey,
                                                metalTile: metalTile,
                                                isRetained: false,
                                                lodKind: .exact,
                                                labelDetailTier: .minimal)

        XCTAssertNotEqual(BaseLabelSourceEntry.makeBaseLabelHash([fullEntry]),
                          BaseLabelSourceEntry.makeBaseLabelHash([minimalEntry]))
        XCTAssertEqual(BaseLabelSourceEntry.makeRoadLabelHash([fullEntry]),
                       BaseLabelSourceEntry.makeRoadLabelHash([minimalEntry]))
    }

    private func makeTileBuffers(textLabels: TileBuffers.TextLabels? = nil) throws -> TileBuffers {
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
                           textLabels: textLabels ?? TileBuffers.TextLabels(full: emptyTextLabelSet(),
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

    private func makeTextLabelSet(keys: [UInt64]) -> TileBuffers.TextLabelSet {
        let placementInputs = keys.enumerated().map { index, key in
            TextLabelPlacementInput(pointInput: TilePointInput(uv: SIMD2<Float>(Float(index), Float(index)),
                                                               tile: SIMD3<Int32>(8, 8, 4)),
                                    placementMeta: LabelPlacementMeta(key: key,
                                                                      sortKey: index,
                                                                      collisionPriority: index,
                                                                      labelSizePx: SIMD2<Float>(10 + Float(index), 6),
                                                                      minCameraZoom: 0))
        }
        return TileBuffers.TextLabelSet(placementInputs: placementInputs,
                                        labelsByStyleRuns: [],
                                        poiIconRuns: [])
    }
}
