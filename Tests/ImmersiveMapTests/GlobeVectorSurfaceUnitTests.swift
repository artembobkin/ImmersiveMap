// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Pins the Swift mirror of `GlobeSurfaceTile` in TileSphere.metal.
final class GlobeVectorSurfaceUniformLayoutTests: XCTestCase {
    func testSurfaceTileUniformMatchesMetalLayout() {
        // int3 in Metal: 16 bytes, 16-aligned.
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.stride, 16)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.tile), 0)
        let uniform = GlobeSurfaceTileUniform(tile: Tile(x: 3, y: 5, z: 4))
        XCTAssertEqual(uniform.tile, SIMD3<Int32>(3, 5, 4))
    }
}

final class GlobeLineDashScaleTests: XCTestCase {
    func testCoarseTilesKeepTheZ1DashProportion() {
        XCTAssertEqual(GlobeLineDashScale.coarseTileDashScale(sourceTileZoom: 0), 0.7)
        XCTAssertEqual(GlobeLineDashScale.coarseTileDashScale(sourceTileZoom: 1), 0.7)
        XCTAssertEqual(GlobeLineDashScale.coarseTileDashScale(sourceTileZoom: 2), 0.9)
        XCTAssertEqual(GlobeLineDashScale.coarseTileDashScale(sourceTileZoom: 3), 1.0)
    }
}
