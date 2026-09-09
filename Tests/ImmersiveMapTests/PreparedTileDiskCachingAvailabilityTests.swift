// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The prepared disk cache's availability index: seeded from the directory
/// when a cache instance starts, and kept current by every save and removal.
final class PreparedTileDiskCachingAvailabilityTests: XCTestCase {
    private let fileManager = FileManager.default
    private var baseDirectory: URL!

    override func setUp() {
        super.setUp()
        baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PreparedTileDiskCache-availability-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? fileManager.removeItem(at: baseDirectory)
        super.tearDown()
    }

    func testPrepareSeedsTheIndexFromTheDirectory() async throws {
        let identity = makeCacheIdentity()
        let directory = namespaceDirectory(identity: identity)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let pair = Tile(x: 1, y: 2, z: 3)
        try Data([1]).write(to: directory.appendingPathComponent("3_1_2.ptile"))
        try Data([1]).write(to: directory.appendingPathComponent("3_1_2.ptgeo"))
        try Data([1]).write(to: directory.appendingPathComponent("4_0_0.ptgeo"))
        try Data([1]).write(to: directory.appendingPathComponent("5_1_1.ptile.tmp-\(UUID().uuidString)"))
        let expiredPath = directory.appendingPathComponent("7_1_1.ptile")
        try Data([1]).write(to: expiredPath)
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
                                      ofItemAtPath: expiredPath.path)
        let foreignDirectory = directory.deletingLastPathComponent().appendingPathComponent("foreign-binl")
        try fileManager.createDirectory(at: foreignDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: foreignDirectory.appendingPathComponent("6_1_1.ptile"))

        let cache = makeCache(identity: identity)
        await drain(cache)

        XCTAssertTrue(cache.isPreparedOnDisk(pair))
        XCTAssertFalse(cache.isPreparedOnDisk(Tile(x: 0, y: 0, z: 4)), "a blob without its entry")
        XCTAssertFalse(cache.isPreparedOnDisk(Tile(x: 1, y: 1, z: 5)), "a staged file")
        XCTAssertFalse(cache.isPreparedOnDisk(Tile(x: 1, y: 1, z: 7)), "an expired entry")
        XCTAssertFalse(cache.isPreparedOnDisk(Tile(x: 1, y: 1, z: 6)), "another namespace")
        XCTAssertEqual(cache.availabilityIndex.count, 1)
    }

    /// `standardizedFileURL` strips a leading `/private` only for a path that
    /// exists, so a base under `/private` (every iPhone temporary directory)
    /// spells the namespace directory one way at init, before it exists, and
    /// another way once files land in it. The registry key must not care.
    func testABaseDirectoryUnderPrivateStillIndexes() async {
        let privateBase = URL(fileURLWithPath: "/private" + baseDirectory.path)
        let cache = PreparedTileDiskCaching(config: ImmersiveMapSettings.default,
                                            cacheIdentity: makeCacheIdentity(),
                                            baseCachesDirectory: privateBase)
        let tile = Tile(x: 4, y: 5, z: 6)
        await cache.saveOnDisk(tile: tile, preparedTile: makePreparedTile(tile: tile), sourceETag: nil)
        XCTAssertTrue(cache.isPreparedOnDisk(tile))
    }

    func testALostBlobTakesTheEntryOutOfTheIndex() async throws {
        let identity = makeCacheIdentity()
        let directory = namespaceDirectory(identity: identity)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appendingPathComponent("3_1_2.ptile"))
        try Data([1]).write(to: directory.appendingPathComponent("3_1_2.ptgeo"))
        let cache = makeCache(identity: identity)
        await drain(cache)
        XCTAssertTrue(cache.isPreparedOnDisk(Tile(x: 1, y: 2, z: 3)))

        // The blob goes (a quota prune takes it first, it sorts before the
        // entry): the entry alone cannot materialize, so the tile is gone.
        cache.removeBlobFromDiskForTesting(tile: Tile(x: 1, y: 2, z: 3))
        await drain(cache)
        XCTAssertFalse(cache.isPreparedOnDisk(Tile(x: 1, y: 2, z: 3)))
    }

    func testASaveMakesTheTileAvailableAndARemovalTakesItAway() async {
        let cache = makeCache(identity: makeCacheIdentity())
        let tile = Tile(x: 4, y: 5, z: 6)
        XCTAssertFalse(cache.isPreparedOnDisk(tile))

        await cache.saveOnDisk(tile: tile, preparedTile: makePreparedTile(tile: tile), sourceETag: nil)
        XCTAssertTrue(cache.isPreparedOnDisk(tile))

        cache.removeFromDisk(tile: tile)
        await drain(cache)
        XCTAssertFalse(cache.isPreparedOnDisk(tile))
    }

    func testClearingTheCacheEmptiesTheIndex() async throws {
        let cache = makeCache(identity: makeCacheIdentity())
        let tile = Tile(x: 4, y: 5, z: 6)
        await cache.saveOnDisk(tile: tile, preparedTile: makePreparedTile(tile: tile), sourceETag: nil)
        XCTAssertTrue(cache.isPreparedOnDisk(tile))

        try cache.clearAllCache()
        XCTAssertFalse(cache.isPreparedOnDisk(tile))
    }

    func testTwoInstancesOnOneNamespaceShareTheIndex() async {
        let identity = makeCacheIdentity()
        let first = makeCache(identity: identity)
        let second = makeCache(identity: identity)
        let tile = Tile(x: 4, y: 5, z: 6)

        await first.saveOnDisk(tile: tile, preparedTile: makePreparedTile(tile: tile), sourceETag: nil)

        XCTAssertTrue(second.isPreparedOnDisk(tile), "A save through one instance is visible through the other")
    }

    func testALaterInstanceForANewNamespaceIsSeeded() async throws {
        let firstIdentity = makeCacheIdentity(styleRevision: 1)
        let secondIdentity = makeCacheIdentity(styleRevision: 2)
        let secondDirectory = namespaceDirectory(identity: secondIdentity)
        try fileManager.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: secondDirectory.appendingPathComponent("8_3_4.ptile"))

        let first = makeCache(identity: firstIdentity)
        await drain(first)
        XCTAssertFalse(first.isPreparedOnDisk(Tile(x: 3, y: 4, z: 8)), "not its namespace")

        let second = makeCache(identity: secondIdentity)
        await drain(second)
        XCTAssertTrue(second.isPreparedOnDisk(Tile(x: 3, y: 4, z: 8)), "seeded from the root index the first instance built")
    }

    func testAQuotaPruneDropsTheEntryFromTheIndex() async {
        let strictConfig = ImmersiveMapSettings.default.tileSettings(preparedDiskCacheSizeInBytes: 0)
        let cache = PreparedTileDiskCaching(config: strictConfig,
                                            cacheIdentity: makeCacheIdentity(),
                                            baseCachesDirectory: baseDirectory)
        let first = Tile(x: 1, y: 2, z: 3)
        let second = Tile(x: 4, y: 5, z: 6)
        await cache.saveOnDisk(tile: first, preparedTile: makePreparedTile(tile: first), sourceETag: nil)
        await cache.saveOnDisk(tile: second, preparedTile: makePreparedTile(tile: second), sourceETag: nil)
        await drain(cache)

        XCTAssertFalse(cache.isPreparedOnDisk(first), "A zero quota prunes the entry the moment a later write lands")
    }

    // MARK: - Helpers

    private func makeCache(identity: PreparedTileCacheIdentity) -> PreparedTileDiskCaching {
        PreparedTileDiskCaching(config: ImmersiveMapSettings.default,
                                cacheIdentity: identity,
                                baseCachesDirectory: baseDirectory)
    }

    /// The IO queue is serial: a read that has been answered means everything
    /// enqueued before it (the prepare, a removal) has run.
    private func drain(_ cache: PreparedTileDiskCaching) async {
        _ = await cache.requestPreparedDiskCached(tile: Tile(x: 99, y: 99, z: 9), matchingETag: nil)
    }

    private func namespaceDirectory(identity: PreparedTileCacheIdentity) -> URL {
        baseDirectory
            .appendingPathComponent("MapPreparedTiles")
            .appendingPathComponent("v\(identity.preparedFormatVersion)")
            .appendingPathComponent("\(identity.namespaceComponent)-\(InlinePreparedTileGeometryTransport().cacheNamespaceMarker)")
    }

    private func makeCacheIdentity(styleRevision: UInt32 = 1) -> PreparedTileCacheIdentity {
        PreparedTileCacheIdentity(preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
                                  styleRevision: styleRevision,
                                  tileSourceRevision: 2,
                                  flatSeparateRoadRenderingMinimumZoom: 3,
                                  textRevision: 4,
                                  labelLanguage: .english,
                                  labelFallbackPolicy: .international,
                                  houseNumbersEnabled: true,
                                  houseNumbersMinimumZoom: 15,
                                  capitalMaximumZoom: 12,
                                  cityMaximumZoom: 12,
                                  smallSettlementMaximumZoom: 12,
                                  landmarkMinimumZoom: 13,
                                  addTestBorders: false,
                                  roofShapesEnabled: true,
                                  buildingExtrusionEnabled: true,
                                  labelsEnabled: true)
    }

    private func makePreparedTile(tile: Tile) -> PreparedTileCPU {
        let emptyGeometry = PreparedTileCPU.GeometryLayer(vertices: [],
                                                         indices: [],
                                                         styles: [],
                                                         overviewStyleMasks: [])
        let emptyRoadPhases = RoadGeometryPhases(shadow: emptyGeometry,
                                                 casing: emptyGeometry,
                                                 fill: emptyGeometry,
                                                 detail: emptyGeometry,
                                                 overlay: emptyGeometry)
        let emptyTextLabels = PreparedTileCPU.TextLabelSet(placementInputs: [],
                                                           glyphRuns: [],
                                                           poiIconRuns: [])
        return PreparedTileCPU(tile: tile,
                               ground: emptyGeometry,
                               roads: RoadStructureBuckets(tunnel: emptyRoadPhases,
                                                          ground: emptyRoadPhases,
                                                          automobileGround: emptyRoadPhases,
                                                          bridge: emptyRoadPhases),
                               bridgeOverlay: emptyGeometry,
                               extruded: PreparedTileCPU.Extruded(vertices: [], indices: [], styles: []),
                               textLabels: emptyTextLabels,
                               roadLabels: PreparedTileCPU.RoadLabels(pathInputs: [],
                                                                      pathRanges: [],
                                                                      pathLabels: [],
                                                                      labelStyle: nil,
                                                                      localGlyphVertices: [],
                                                                      glyphBounds: [],
                                                                      glyphBoundRanges: [],
                                                                      sizes: [],
                                                                      anchorRanges: [],
                                                                      anchors: []))
    }
}
