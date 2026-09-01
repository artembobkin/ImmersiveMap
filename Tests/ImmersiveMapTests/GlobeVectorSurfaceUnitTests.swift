// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Pins the Swift mirror of `GlobeSurfaceTile` in TileSphere.metal.
final class GlobeVectorSurfaceUniformLayoutTests: XCTestCase {
    func testSurfaceTileUniformMatchesMetalLayout() {
        // float2 + float + float in Metal: 16 bytes, the float2 8-aligned at 0.
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.stride, 16)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.uvOrigin), 0)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.uvScale), 8)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.referenceWorldX), 12)
        let uniform = GlobeSurfaceTileUniform(tile: Tile(x: 3, y: 5, z: 4))
        XCTAssertEqual(uniform.uvOrigin, SIMD2<Float>(3.0 / 16.0, 5.0 / 16.0))
        XCTAssertEqual(uniform.uvScale, 1.0 / 16.0)
        XCTAssertEqual(uniform.referenceWorldX, 3.5 / 16.0)
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
