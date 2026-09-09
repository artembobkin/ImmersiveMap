// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import MetalKit
import XCTest

/// The base label source entries: one entry per owner tile whatever the
/// slots it is placed in, exact sources before substitutes, and the cache
/// reading the tile's one label set.
final class BaseLabelSourceEntryTests: XCTestCase {
    func testDuplicateOwnerKeysCollapseToOneEntry() throws {
        let metalTile = MetalTile(tile: Tile(x: 8, y: 8, z: 4),
                                  tileBuffers: try makeTileBuffers())
        let nearPlaceTile = PlaceTile(metalTile: metalTile,
                                      placeIn: VisibleTile(x: 32, y: 32, z: 6),
                                      lodKind: .retainedReplacement)
        let farPlaceTile = PlaceTile(metalTile: metalTile,
                                     placeIn: VisibleTile(x: 48, y: 48, z: 6),
                                     lodKind: .retainedReplacement)

        let nearFirstEntries = BaseLabelSourceEntry.build(from: [nearPlaceTile, farPlaceTile])
        let farFirstEntries = BaseLabelSourceEntry.build(from: [farPlaceTile, nearPlaceTile])

        XCTAssertEqual(nearFirstEntries.count, 1)
        XCTAssertEqual(farFirstEntries.count, 1)
        XCTAssertEqual(BaseLabelSourceEntry.makeHash(nearFirstEntries), BaseLabelSourceEntry.makeHash(farFirstEntries),
                       "The order the slots come in does not change the source set")
    }

    func testExactSourcesSortBeforeSubstitutesThenByOwner() throws {
        let lowerOwnerTile = MetalTile(tile: Tile(x: 8, y: 8, z: 4), tileBuffers: try makeTileBuffers())
        let higherOwnerTile = MetalTile(tile: Tile(x: 9, y: 8, z: 4), tileBuffers: try makeTileBuffers())
        let substitute = PlaceTile(metalTile: lowerOwnerTile,
                                   placeIn: VisibleTile(x: 48, y: 48, z: 6),
                                   lodKind: .retainedReplacement)
        let exact = PlaceTile(metalTile: higherOwnerTile,
                              placeIn: VisibleTile(x: 9, y: 8, z: 4),
                              lodKind: .exact)

        let entries = BaseLabelSourceEntry.build(from: [substitute, exact])

        XCTAssertEqual(entries.map(\.ownerKey.x), [9, 8], "The exact source leads, the substitute follows")
        XCTAssertNotEqual(BaseLabelSourceEntry.makeHash(entries),
                          BaseLabelSourceEntry.makeHash(BaseLabelSourceEntry.build(from: [substitute])))
    }

    func testBaseLabelCacheReadsTheTileLabelSet() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for BaseLabelCache test fixture.")
        }

        let ownerKey = VisibleTile(x: 8, y: 8, z: 4)
        let metalTile = MetalTile(tile: ownerKey.tile,
                                  tileBuffers: try makeTileBuffers(textLabels: makeTextLabelSet(keys: [10, 11, 12])))
        let tileIndexAllocator = VisibleTileIndexAllocator(indexedTiles: [ownerKey])
        let cache = BaseLabelCache(metalDevice: device)

        cache.rebuild(sourceEntries: [
            BaseLabelSourceEntry(ownerKey: ownerKey,
                                 metalTile: metalTile,
                                 isRetained: false,
                                 lodKind: .exact)
        ], tileIndexAllocator: tileIndexAllocator)

        XCTAssertEqual(cache.labelInputsCount, 3)
        XCTAssertEqual(cache.presentationInputs.prefix(3).map(\.labelKey), [10, 11, 12])
    }

    func testBaseLabelCacheWritesStableCollisionMetadata() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for BaseLabelCache test fixture.")
        }

        let ownerKey = VisibleTile(x: 8, y: 8, z: 4)
        let metalTile = MetalTile(tile: ownerKey.tile,
                                  tileBuffers: try makeTileBuffers(textLabels: makeTextLabelSet(keys: [10, 11])))
        let cache = BaseLabelCache(metalDevice: device)
        cache.rebuild(sourceEntries: [
            BaseLabelSourceEntry(ownerKey: ownerKey,
                                 metalTile: metalTile,
                                 isRetained: false,
                                 lodKind: .exact)
        ], tileIndexAllocator: VisibleTileIndexAllocator(indexedTiles: [ownerKey]))

        let candidates = cache.labelCollisionAABBInputs

        XCTAssertEqual(candidates[0].stableOrderKey, 10)
        XCTAssertEqual(candidates[0].groupId, 10)
        XCTAssertEqual(candidates[0].sortPriority, 0)
        XCTAssertEqual(candidates[1].stableOrderKey, 11)
        XCTAssertEqual(candidates[1].groupId, 11)
        XCTAssertEqual(candidates[1].sortPriority, 1)
    }

    private func makeTileBuffers(textLabels: TileBuffers.TextLabelSet? = nil) throws -> TileBuffers {
        try TileBuffersFixtures.makeEmptyTileBuffers(textLabels: textLabels)
    }

    private func makeTextLabelSet(keys: [UInt64]) -> TileBuffers.TextLabelSet {
        let placementInputs = keys.enumerated().map { index, key in
            TextLabelPlacementInput(pointInput: TilePointInput(uv: SIMD2<Float>(Float(index), Float(index)),
                                                               tile: SIMD3<Int32>(8, 8, 4)),
                                    placementMeta: LabelPlacementMeta(key: key,
                                                                      sortKey: index,
                                                                      collisionPriority: index,
                                                                      labelSizePoints: SIMD2<Float>(10 + Float(index), 6),
                                                                      minCameraZoom: 0))
        }
        return TileBuffers.TextLabelSet(placementInputs: placementInputs,
                                        labelsByStyleRuns: [],
                                        poiIconRuns: [])
    }
}
