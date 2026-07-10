// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class PreparedTileDiskCachingCoordinatorTests: XCTestCase {
    func testLatestRootPolicyAppliesToWritesFromOlderCacheInstance() async {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PreparedTileDiskCache-policy-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: baseDirectory) }

        let relaxedConfig = ImmersiveMapSettings.default
            .tileSettings(preparedDiskCacheSizeInBytes: 1 * 1_024 * 1_024)
        let relaxedCache = PreparedTileDiskCaching(config: relaxedConfig,
                                                   cacheIdentity: makeCacheIdentity(),
                                                   baseCachesDirectory: baseDirectory)
        _ = await relaxedCache.requestPreparedDiskCached(tile: Tile(x: 90, y: 90, z: 9),
                                                          matchingETag: nil)

        let strictConfig = relaxedConfig.tileSettings(preparedDiskCacheSizeInBytes: 0)
        let strictCache = PreparedTileDiskCaching(config: strictConfig,
                                                  cacheIdentity: makeCacheIdentity(),
                                                  baseCachesDirectory: baseDirectory)
        _ = await strictCache.requestPreparedDiskCached(tile: Tile(x: 91, y: 91, z: 9),
                                                         matchingETag: nil)

        let tile = Tile(x: 1, y: 2, z: 3)
        await relaxedCache.saveOnDisk(tile: tile,
                                      preparedTile: makePreparedTile(tile: tile),
                                      sourceETag: nil)
        _ = await relaxedCache.requestPreparedDiskCached(tile: Tile(x: 92, y: 92, z: 9),
                                                          matchingETag: nil)

        XCTAssertFalse(fileManager.fileExists(atPath: relaxedCache.cachePathFor(tile: tile).path))
    }

    func testAwaitingSaveReturnsOnlyAfterFileIsPersisted() async throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PreparedTileDiskCache-await-save-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: baseDirectory) }

        // Keep the coordinator busy long enough to make the old fire-and-forget
        // behavior deterministic: an unbounded save returned before this scan.
        let root = baseDirectory.appendingPathComponent("MapPreparedTiles")
        for index in 0..<512 {
            let file = root.appendingPathComponent("v20/legacy-\(index)/tile.ptile")
            try fileManager.createDirectory(at: file.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try Data([0]).write(to: file)
        }

        let config = ImmersiveMapSettings.default
            .tileSettings(preparedDiskCacheSizeInBytes: 16 * 1_024 * 1_024)
        let cache = PreparedTileDiskCaching(config: config,
                                            cacheIdentity: makeCacheIdentity(),
                                            baseCachesDirectory: baseDirectory)
        let tile = Tile(x: 4, y: 5, z: 6)

        await cache.saveOnDisk(tile: tile,
                               preparedTile: makePreparedTile(tile: tile),
                               sourceETag: "persisted")

        XCTAssertTrue(fileManager.fileExists(atPath: cache.cachePathFor(tile: tile).path))
    }

    private func makeCacheIdentity() -> PreparedTileCacheIdentity {
        PreparedTileCacheIdentity(preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
                                  styleRevision: 1,
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
                                  addTestBorders: false)
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
                                                          bridge: emptyRoadPhases),
                               bridgeOverlay: emptyGeometry,
                               extruded: PreparedTileCPU.Extruded(vertices: [], indices: [], styles: []),
                               textLabels: PreparedTileCPU.TextLabels(full: emptyTextLabels,
                                                                     reduced: emptyTextLabels,
                                                                     minimal: emptyTextLabels),
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
