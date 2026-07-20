// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class GlobeCapEdgeSamplerTests: XCTestCase {
    func testNorthEdgeSamplesMinimumVEdgeOfMatchingAtlasSlot() {
        let tileData = makeTileData(position: 0,
                                    textureSize: 4096,
                                    cellSize: 2048,
                                    tile: SIMD3<Int32>(0, 0, 1))

        let uv = GlobeCapEdgeSampler.atlasSampleUV(latitude: Float(WebMercatorMath.maxLatitudeRadians),
                                                  longitude: 0,
                                                  tileData: tileData)

        XCTAssertEqual(uv?.x ?? -1, 0.5 / 4096.0, accuracy: 0.0001)
        XCTAssertEqual(uv?.y ?? -1, 0.5 + 0.5 / 4096.0, accuracy: 0.0001)
    }

    func testSouthEdgeSamplesMaximumVEdgeOfMatchingAtlasSlot() {
        let tileData = makeTileData(position: 3,
                                    textureSize: 4096,
                                    cellSize: 2048,
                                    tile: SIMD3<Int32>(1, 1, 1))

        let uv = GlobeCapEdgeSampler.atlasSampleUV(latitude: -Float(WebMercatorMath.maxLatitudeRadians),
                                                  longitude: Float.pi,
                                                  tileData: tileData)

        XCTAssertEqual(uv?.x ?? -1, 0.5 + 0.5 / 4096.0, accuracy: 0.0001)
        XCTAssertEqual(uv?.y ?? -1, 0.5 - 0.5 / 4096.0, accuracy: 0.0001)
    }

    func testSampleReturnsNilForTileOutsideLongitudeRange() {
        let tileData = makeTileData(position: 0,
                                    textureSize: 4096,
                                    cellSize: 2048,
                                    tile: SIMD3<Int32>(1, 0, 1))

        let uv = GlobeCapEdgeSampler.atlasSampleUV(latitude: Float(WebMercatorMath.maxLatitudeRadians),
                                                  longitude: 0,
                                                  tileData: tileData)

        XCTAssertNil(uv)
    }

    private func makeTileData(position: Int32,
                              textureSize: Int32,
                              cellSize: Int32,
                              tile: SIMD3<Int32>) -> TileAtlasTexture.TileData {
        TileAtlasTexture.TileData(position: simd_int1(position),
                                   textureSize: simd_int1(textureSize),
                                   cellSize: simd_int1(cellSize),
                                   tile: tile,
                                   sourceTile: tile)
    }
}
