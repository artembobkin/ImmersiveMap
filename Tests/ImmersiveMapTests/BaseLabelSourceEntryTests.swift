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
                                      placeIn: VisibleTile(x: 32, y: 32, z: 6))
        let farPlaceTile = PlaceTile(metalTile: metalTile,
                                     placeIn: VisibleTile(x: 48, y: 48, z: 6))

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
                                   placeIn: VisibleTile(x: 48, y: 48, z: 6))
        let exact = PlaceTile(metalTile: higherOwnerTile,
                              placeIn: VisibleTile(x: 9, y: 8, z: 4))

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
                                 inOwnSlot: true)
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
                                 inOwnSlot: true)
        ], tileIndexAllocator: VisibleTileIndexAllocator(indexedTiles: [ownerKey]))

        XCTAssertEqual(cache.labelRanks, [BaseLabelRank(priority: 0, sortPriority: 0, key: 10),
                                          BaseLabelRank(priority: 1, sortPriority: 1, key: 11)])
        XCTAssertEqual(cache.labelHalfSizes, [SIMD2<Float>(5, 3), SIMD2<Float>(5.5, 3)])
    }

    /// The set's rank order is its tiles' orders merged: the same order a
    /// sort of the whole set gives, ties to the earlier tile.
    func testTheSetsRankOrderIsItsTilesOrdersMerged() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for BaseLabelCache test fixture.")
        }
        let first = MetalTile(tile: Tile(x: 8, y: 8, z: 4),
                              tileBuffers: try makeTileBuffers(textLabels: makeTextLabelSet(keys: [1, 2, 3],
                                                                                            priorities: [5, 1, 3])))
        let second = MetalTile(tile: Tile(x: 9, y: 8, z: 4),
                               tileBuffers: try makeTileBuffers(textLabels: makeTextLabelSet(keys: [4, 5, 6],
                                                                                             priorities: [2, 4, 0])))
        let entries = BaseLabelSourceEntry.build(from: [
            PlaceTile(metalTile: first, placeIn: VisibleTile(x: 8, y: 8, z: 4)),
            PlaceTile(metalTile: second, placeIn: VisibleTile(x: 9, y: 8, z: 4))
        ])
        let cache = BaseLabelCache(metalDevice: device)
        cache.rebuild(sourceEntries: entries,
                      tileIndexAllocator: VisibleTileIndexAllocator(indexedTiles: entries.map(\.ownerKey)))

        XCTAssertEqual(cache.labelKeys, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(first.tileBuffers.textLabels.rankOrder, [1, 2, 0], "Each tile ranks its own labels once")
        XCTAssertEqual(cache.rankOrder, [5, 1, 3, 2, 4, 0])
        XCTAssertEqual(cache.rankOrder, BaseLabelRankOrder.sorted(cache.labelRanks))
    }

    /// The exact tile and the coarser one standing in beside it both bring
    /// feature 20: the set keeps the exact tile's copy, the source it
    /// prefers, and marks the stand-in's as its copy, wherever either draws.
    func testTheCacheKeepsOneCopyOfAFeatureFromThePreferredTile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for BaseLabelCache test fixture.")
        }
        let exactTile = MetalTile(tile: Tile(x: 9652, y: 12318, z: 15),
                                  tileBuffers: try makeTileBuffers(textLabels: makeTextLabelSet(keys: [10, 20])))
        let standIn = MetalTile(tile: Tile(x: 2413, y: 3079, z: 13),
                                tileBuffers: try makeTileBuffers(textLabels: makeTextLabelSet(keys: [20, 30, 0, 0])))
        let entries = BaseLabelSourceEntry.build(from: [
            PlaceTile(metalTile: standIn, placeIn: VisibleTile(x: 9653, y: 12318, z: 15)),
            PlaceTile(metalTile: exactTile, placeIn: VisibleTile(x: 9652, y: 12318, z: 15))
        ])
        let cache = BaseLabelCache(metalDevice: device)
        cache.rebuild(sourceEntries: entries,
                      tileIndexAllocator: VisibleTileIndexAllocator(indexedTiles: entries.map(\.ownerKey)))

        XCTAssertEqual(cache.labelKeys, [10, 20, 20, 30, 0, 0], "The exact tile leads the set")
        XCTAssertEqual(cache.labelCopyOf, [-1, -1, 1, -1, -1, -1],
                       "The stand-in's copy points at the exact tile's, a label without a key is nobody's copy")
        XCTAssertEqual(cache.copyIndices, [2])
        XCTAssertEqual(cache.presentationInputs.map(\.isCopy), [false, false, true, false, false, false])
    }

    /// When the exact tile leaves, the stand-in's copy is the one the set keeps.
    func testTheCopyIsKeptOnceThePreferredTileLeaves() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for BaseLabelCache test fixture.")
        }
        let exactTile = MetalTile(tile: Tile(x: 9652, y: 12318, z: 15),
                                  tileBuffers: try makeTileBuffers(textLabels: makeTextLabelSet(keys: [20])))
        let standIn = MetalTile(tile: Tile(x: 2413, y: 3079, z: 13),
                                tileBuffers: try makeTileBuffers(textLabels: makeTextLabelSet(keys: [20])))
        let both = BaseLabelSourceEntry.build(from: [
            PlaceTile(metalTile: exactTile, placeIn: VisibleTile(x: 9652, y: 12318, z: 15)),
            PlaceTile(metalTile: standIn, placeIn: VisibleTile(x: 9653, y: 12318, z: 15))
        ])
        let standInOnly = BaseLabelSourceEntry.build(from: [
            PlaceTile(metalTile: standIn, placeIn: VisibleTile(x: 9653, y: 12318, z: 15))
        ])
        let allocator = VisibleTileIndexAllocator(indexedTiles: both.map(\.ownerKey))
        let cache = BaseLabelCache(metalDevice: device)

        cache.rebuild(sourceEntries: both, tileIndexAllocator: allocator)
        XCTAssertEqual(cache.labelCopyOf, [-1, 0])
        cache.rebuild(sourceEntries: standInOnly, tileIndexAllocator: allocator)
        XCTAssertEqual(cache.labelCopyOf, [-1])
        XCTAssertEqual(cache.copyIndices, [])
    }

    /// One tile in two world wraps is one feature in two places: both kept.
    func testTheSameFeatureInTwoWorldWrapsIsNotACopy() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for BaseLabelCache test fixture.")
        }
        let metalTile = MetalTile(tile: Tile(x: 1, y: 1, z: 2),
                                  tileBuffers: try makeTileBuffers(textLabels: makeTextLabelSet(keys: [20])))
        let entries = BaseLabelSourceEntry.build(from: [
            PlaceTile(metalTile: metalTile, placeIn: VisibleTile(x: 1, y: 1, z: 2, worldWrap: 0)),
            PlaceTile(metalTile: metalTile, placeIn: VisibleTile(x: 1, y: 1, z: 2, worldWrap: 1))
        ])
        let cache = BaseLabelCache(metalDevice: device)
        cache.rebuild(sourceEntries: entries,
                      tileIndexAllocator: VisibleTileIndexAllocator(indexedTiles: entries.map(\.ownerKey)))

        XCTAssertEqual(cache.labelKeys, [20, 20])
        XCTAssertEqual(cache.labelCopyOf, [-1, -1])
    }

    private func makeTileBuffers(textLabels: TileBuffers.TextLabelSet? = nil) throws -> TileBuffers {
        try TileBuffersFixtures.makeEmptyTileBuffers(textLabels: textLabels)
    }

    private func makeTextLabelSet(keys: [UInt64], priorities: [Int]? = nil) -> TileBuffers.TextLabelSet {
        let placementInputs = keys.enumerated().map { index, key in
            TextLabelPlacementInput(pointInput: TilePointInput(uv: SIMD2<Float>(Float(index), Float(index)),
                                                               tile: SIMD3<Int32>(8, 8, 4)),
                                    placementMeta: LabelPlacementMeta(key: key,
                                                                      sortKey: index,
                                                                      collisionPriority: priorities?[index] ?? index,
                                                                      labelSizePoints: SIMD2<Float>(10 + Float(index), 6),
                                                                      minCameraZoom: 0))
        }
        return TileBuffers.TextLabelSet(placementInputs: placementInputs,
                                        labelsByStyleRuns: [],
                                        poiIconRuns: [])
    }
}
