// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TerrainTileStorePlanTests: XCTestCase {
    func testRequestPlanUsesParentTileWhenTerrainZoomIsLowerThanVisibleZoom() throws {
        let settings = terrainSettings(sourceMaximumZoom: 14,
                                       settingsMaximumZoom: 12,
                                       meshResolution: 33,
                                       exaggeration: 1.5)
        let visibleTile = VisibleTile(x: 34_931, y: 22_544, z: 16, loop: 1)

        let plan = try XCTUnwrap(
            TerrainTileRequestPlanner.plan(
                visibleTile: visibleTile,
                terrain: settings.terrain,
                renderSurfaceMode: .flat,
                globeRadius: 512,
                heightScale: 0.25
            )
        )

        XCTAssertEqual(plan.sourceTile, Tile(x: 2_183, y: 1_409, z: 12))
        XCTAssertEqual(plan.visibleTile, visibleTile)
        XCTAssertEqual(plan.cacheKey.tile, Tile(x: 2_183, y: 1_409, z: 12))
    }

    func testRequestPlanClampsToTerrainSourceMaximumZoom() throws {
        let settings = terrainSettings(sourceMaximumZoom: 10,
                                       settingsMaximumZoom: 14,
                                       meshResolution: 65,
                                       exaggeration: 1)

        let plan = try XCTUnwrap(
            TerrainTileRequestPlanner.plan(
                visibleTile: VisibleTile(x: 4_500, y: 3_200, z: 13),
                terrain: settings.terrain,
                renderSurfaceMode: .spherical,
                globeRadius: 1_024,
                heightScale: 1
            )
        )

        XCTAssertEqual(plan.sourceTile, Tile(x: 562, y: 400, z: 10))
    }

    func testUniquePlansDeduplicateVisibleChildrenSharingOneTerrainParent() {
        let settings = terrainSettings(sourceMaximumZoom: 12,
                                       settingsMaximumZoom: 12,
                                       meshResolution: 17,
                                       exaggeration: 1)
        let visibleTiles = [
            VisibleTile(x: 40, y: 80, z: 14),
            VisibleTile(x: 41, y: 80, z: 14),
            VisibleTile(x: 42, y: 80, z: 14),
            VisibleTile(x: 56, y: 80, z: 14)
        ]

        let plans = TerrainTileRequestPlanner.uniquePlans(
            visibleTiles: visibleTiles,
            terrain: settings.terrain,
            renderSurfaceMode: .flat,
            globeRadius: 256,
            heightScale: 1
        )

        XCTAssertEqual(plans.map(\.sourceTile), [
            Tile(x: 10, y: 20, z: 12),
            Tile(x: 14, y: 20, z: 12)
        ])
    }

    func testDrawPlansPreserveDuplicateTerrainTileAcrossFlatWorldLoops() {
        let settings = terrainSettings(sourceMaximumZoom: 12,
                                       settingsMaximumZoom: 12,
                                       meshResolution: 17,
                                       exaggeration: 1)
        let visibleTiles = [
            VisibleTile(x: 40, y: 80, z: 14, loop: -1),
            VisibleTile(x: 40, y: 80, z: 14, loop: 0),
            VisibleTile(x: 41, y: 80, z: 14, loop: 0)
        ]

        let plans = TerrainTileRequestPlanner.drawPlans(
            visibleTiles: visibleTiles,
            terrain: settings.terrain,
            renderSurfaceMode: .flat,
            globeRadius: 256,
            heightScale: 1
        )

        XCTAssertEqual(plans.map(\.visibleTile.loop), [-1, 0])
        XCTAssertEqual(plans.map(\.sourceTile), [
            Tile(x: 10, y: 20, z: 12),
            Tile(x: 10, y: 20, z: 12)
        ])
    }

    func testCacheKeyIncludesSurfaceModeMeshAndHeightInputs() {
        let settings = terrainSettings(sourceMaximumZoom: 14,
                                       settingsMaximumZoom: 14,
                                       meshResolution: 33,
                                       exaggeration: 1.25)
        let visibleTile = VisibleTile(x: 12, y: 5, z: 8)
        let flat = TerrainTileRequestPlanner.plan(visibleTile: visibleTile,
                                                  terrain: settings.terrain,
                                                  renderSurfaceMode: .flat,
                                                  globeRadius: 128,
                                                  heightScale: 0.5)?.cacheKey
        let spherical = TerrainTileRequestPlanner.plan(visibleTile: visibleTile,
                                                       terrain: settings.terrain,
                                                       renderSurfaceMode: .spherical,
                                                       globeRadius: 128,
                                                       heightScale: 0.5)?.cacheKey
        let changedResolution = TerrainTileRequestPlanner.plan(
            visibleTile: visibleTile,
            terrain: settings.terrain.withMeshResolution(65),
            renderSurfaceMode: .flat,
            globeRadius: 128,
            heightScale: 0.5
        )?.cacheKey
        let changedHeightScale = TerrainTileRequestPlanner.plan(visibleTile: visibleTile,
                                                                terrain: settings.terrain,
                                                                renderSurfaceMode: .flat,
                                                                globeRadius: 128,
                                                                heightScale: 1)?.cacheKey

        XCTAssertNotEqual(flat, spherical)
        XCTAssertNotEqual(flat, changedResolution)
        XCTAssertNotEqual(flat, changedHeightScale)
    }

    func testFlatCacheKeyIgnoresGlobeRadiusButSphericalKeyIncludesIt() {
        let settings = terrainSettings(sourceMaximumZoom: 14,
                                       settingsMaximumZoom: 14,
                                       meshResolution: 33,
                                       exaggeration: 1)
        let visibleTile = VisibleTile(x: 12, y: 5, z: 8)

        let flatA = TerrainTileRequestPlanner.plan(visibleTile: visibleTile,
                                                   terrain: settings.terrain,
                                                   renderSurfaceMode: .flat,
                                                   globeRadius: 128,
                                                   heightScale: 1)?.cacheKey
        let flatB = TerrainTileRequestPlanner.plan(visibleTile: visibleTile,
                                                   terrain: settings.terrain,
                                                   renderSurfaceMode: .flat,
                                                   globeRadius: 256,
                                                   heightScale: 1)?.cacheKey
        let sphericalA = TerrainTileRequestPlanner.plan(visibleTile: visibleTile,
                                                        terrain: settings.terrain,
                                                        renderSurfaceMode: .spherical,
                                                        globeRadius: 128,
                                                        heightScale: 1)?.cacheKey
        let sphericalB = TerrainTileRequestPlanner.plan(visibleTile: visibleTile,
                                                        terrain: settings.terrain,
                                                        renderSurfaceMode: .spherical,
                                                        globeRadius: 256,
                                                        heightScale: 1)?.cacheKey

        XCTAssertEqual(flatA, flatB)
        XCTAssertNotEqual(sphericalA, sphericalB)
    }

    func testCacheKeyIncludesSourceMaterialFieldsEvenWhenIDMatches() {
        let sourceA = ImmersiveMapTerrainSource(id: "same",
                                                baseURL: URL(string: "https://example.com/a")!,
                                                encoding: .mapboxTerrainRGB,
                                                datum: .elevation,
                                                maximumZoomLevel: 14)
        let sourceB = ImmersiveMapTerrainSource(id: "same",
                                                baseURL: URL(string: "https://example.com/b")!,
                                                encoding: .terrarium,
                                                datum: .ellipsoid,
                                                maximumZoomLevel: 14)
        let terrainA = ImmersiveMapSettings.default
            .terrainSource(sourceA)
            .terrainRendering(isEnabled: true)
            .terrain
        let terrainB = ImmersiveMapSettings.default
            .terrainSource(sourceB)
            .terrainRendering(isEnabled: true)
            .terrain
        let visibleTile = VisibleTile(x: 12, y: 5, z: 8)

        let keyA = TerrainTileRequestPlanner.plan(visibleTile: visibleTile,
                                                  terrain: terrainA,
                                                  renderSurfaceMode: .flat,
                                                  globeRadius: 128,
                                                  heightScale: 1)?.cacheKey
        let keyB = TerrainTileRequestPlanner.plan(visibleTile: visibleTile,
                                                  terrain: terrainB,
                                                  renderSurfaceMode: .flat,
                                                  globeRadius: 128,
                                                  heightScale: 1)?.cacheKey

        XCTAssertNotEqual(keyA, keyB)
    }

    func testInFlightRegistryAllowsRetryWhenRequestFinishesBeforeTaskAttach() {
        let registry = TerrainTileInFlightRegistry()
        let key = cacheKey()
        let token = tryReserve(registry, key: key)

        XCTAssertTrue(registry.finish(key: key, token: token))
        let task = Task<Void, Never> {}
        XCTAssertFalse(registry.attach(task, for: key, token: token))
        XCTAssertNotNil(registry.reserve(key: key))
    }

    func testMemoryCacheEvictsLeastRecentlyUsedMeshesByCost() {
        let cache = TerrainMeshMemoryCache<String>(maxCost: 10)
        let first = cacheKey(tile: Tile(x: 0, y: 0, z: 1))
        let second = cacheKey(tile: Tile(x: 1, y: 0, z: 1))
        let third = cacheKey(tile: Tile(x: 0, y: 1, z: 1))

        cache.set("first", for: first, cost: 4)
        cache.set("second", for: second, cost: 4)
        XCTAssertEqual(cache.mesh(for: first), "first")
        cache.set("third", for: third, cost: 4)

        XCTAssertEqual(cache.mesh(for: first), "first")
        XCTAssertNil(cache.mesh(for: second))
        XCTAssertEqual(cache.mesh(for: third), "third")
        XCTAssertLessThanOrEqual(cache.totalCost, 10)
    }

    private func terrainSettings(sourceMaximumZoom: Int,
                                 settingsMaximumZoom: Int,
                                 meshResolution: Int,
                                 exaggeration: Float) -> ImmersiveMapSettings {
        ImmersiveMapSettings.default
            .terrainSource(
                ImmersiveMapTerrainSource(
                    id: "terrain-source",
                    baseURL: URL(string: "https://example.com/terrain")!,
                    encoding: .mapboxTerrainRGB,
                    datum: .elevation,
                    maximumZoomLevel: sourceMaximumZoom
                )
            )
            .terrainRendering(isEnabled: true,
                              exaggeration: exaggeration,
                              maximumZoomLevel: settingsMaximumZoom,
                              meshResolution: meshResolution)
    }

    private func cacheKey(tile: Tile = Tile(x: 0, y: 0, z: 1)) -> TerrainTileCacheKey {
        TerrainTileCacheKey(source: ImmersiveMapTerrainSource.reEarth(),
                            tile: tile,
                            renderSurfaceMode: .flat,
                            meshResolution: 17,
                            exaggeration: 1,
                            heightScale: 1,
                            globeRadius: 128)
    }

    private func tryReserve(_ registry: TerrainTileInFlightRegistry,
                            key: TerrainTileCacheKey,
                            file: StaticString = #filePath,
                            line: UInt = #line) -> TerrainTileInFlightToken {
        guard let token = registry.reserve(key: key) else {
            XCTFail("Expected reservation", file: file, line: line)
            return TerrainTileInFlightToken()
        }
        return token
    }
}

private extension ImmersiveMapSettings.TerrainSettings {
    func withMeshResolution(_ meshResolution: Int) -> ImmersiveMapSettings.TerrainSettings {
        var copy = self
        copy.meshResolution = meshResolution
        return copy
    }
}
