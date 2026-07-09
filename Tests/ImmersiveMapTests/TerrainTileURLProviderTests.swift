// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TerrainTileURLProviderTests: XCTestCase {
    func testReEarthMapboxElevationURLUsesXYZPNGPath() {
        let source = ImmersiveMapTerrainSource.reEarth(datum: .elevation)
        let provider = TerrainTileURLProvider(source: source)

        let url = provider.url(for: Tile(x: 145, y: 99, z: 8))

        XCTAssertEqual(url.absoluteString,
                       "https://terrain.reearth.land/mapbox/elevation/8/145/99.png")
    }

    func testReEarthMapboxEllipsoidURLUsesDatumPath() {
        let source = ImmersiveMapTerrainSource.reEarth(datum: .ellipsoid)
        let provider = TerrainTileURLProvider(source: source)

        let url = provider.url(for: Tile(x: 145, y: 99, z: 8))

        XCTAssertEqual(url.absoluteString,
                       "https://terrain.reearth.land/mapbox/ellipsoid/8/145/99.png")
    }

    func testTerrariumURLUsesTerrariumPath() {
        let source = ImmersiveMapTerrainSource.reEarth(encoding: .terrarium, datum: .elevation)
        let provider = TerrainTileURLProvider(source: source)

        let url = provider.url(for: Tile(x: 1, y: 2, z: 3))

        XCTAssertEqual(url.absoluteString,
                       "https://terrain.reearth.land/terrarium/elevation/3/1/2.png")
    }
}
