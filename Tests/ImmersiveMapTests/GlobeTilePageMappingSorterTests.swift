// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class GlobeTilePageMappingSorterTests: XCTestCase {
    func testDrawsFallbackBeforeExactTileForSameTargetRegardlessOfPage() {
        let targetTile = simd_int3(38, 19, 6)
        let fallback = makePageMapping(pageIndex: 1,
                                       position: 0,
                                       targetTile: targetTile,
                                       sourceTile: simd_int3(9, 4, 4))
        let exact = makePageMapping(pageIndex: 0,
                                    position: 0,
                                    targetTile: targetTile,
                                    sourceTile: targetTile)

        var pageMappings = [exact, fallback]
        GlobeTilePageMappingSorter.sort(&pageMappings)

        XCTAssertEqual(pageMappings.map { $0.mapping.sourceTile }, [fallback.mapping.sourceTile, exact.mapping.sourceTile])
    }

    func testDrawsMoreDetailedTargetAfterCoarserTargetRegardlessOfPage() {
        let coarse = makePageMapping(pageIndex: 1,
                                     position: 0,
                                     targetTile: simd_int3(19, 9, 5),
                                     sourceTile: simd_int3(19, 9, 5))
        let detailed = makePageMapping(pageIndex: 0,
                                       position: 0,
                                       targetTile: simd_int3(38, 19, 6),
                                       sourceTile: simd_int3(38, 19, 6))

        var pageMappings = [detailed, coarse]
        GlobeTilePageMappingSorter.sort(&pageMappings)

        XCTAssertEqual(pageMappings.map { $0.mapping.tile }, [coarse.mapping.tile, detailed.mapping.tile])
    }

    private func makePageMapping(pageIndex: Int,
                                 position: Int32,
                                 targetTile: simd_int3,
                                 sourceTile: simd_int3) -> GlobeTilePageMappingSorter.PageMapping {
        let mapping = GlobeTilesTexture.TileData(position: simd_int1(position),
                                                 textureSize: simd_int1(4096),
                                                 cellSize: simd_int1(1024),
                                                 tile: targetTile,
                                                 sourceTile: sourceTile)
        return (pageIndex: pageIndex, mapping: mapping)
    }
}
