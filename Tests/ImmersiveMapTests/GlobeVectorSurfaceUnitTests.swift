// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Pins the Swift mirror of `GlobeSurfaceTile` in TileSphere.metal.
final class GlobeVectorSurfaceUniformLayoutTests: XCTestCase {
    func testSurfaceTileUniformMatchesMetalLayout() {
        // float2 + float x4 in Metal: 24 bytes, the float2 8-aligned at 0
        // and an explicit trailing pad so both sides agree on the stride.
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.stride, 24)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.uvOrigin), 0)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.uvScale), 8)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.referenceWorldX), 12)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.depthBias), 16)
        let uniform = GlobeSurfaceTileUniform(tile: Tile(x: 3, y: 5, z: 4))
        XCTAssertEqual(uniform.uvOrigin, SIMD2<Float>(3.0 / 16.0, 5.0 / 16.0))
        XCTAssertEqual(uniform.uvScale, 1.0 / 16.0)
        XCTAssertEqual(uniform.referenceWorldX, 3.5 / 16.0)
        XCTAssertEqual(uniform.depthBias, GlobeSurfaceDepthRank.bias(sourceZoom: 4))
    }

    /// The depth bias orders sources finest-nearest and clamps to the
    /// sphere's zoom range, so a coarser substitute always loses the depth
    /// test to any finer tile that painted.
    func testDepthBiasOrdersFinerSourcesNearer() {
        XCTAssertGreaterThan(GlobeSurfaceDepthRank.bias(sourceZoom: 6),
                             GlobeSurfaceDepthRank.bias(sourceZoom: 5))
        XCTAssertGreaterThan(GlobeSurfaceDepthRank.bias(sourceZoom: 1),
                             GlobeSurfaceDepthRank.bias(sourceZoom: 0))
        XCTAssertEqual(GlobeSurfaceDepthRank.bias(sourceZoom: 9),
                       GlobeSurfaceDepthRank.bias(sourceZoom: 12))
        // The whole band stays far behind the sphere's own limb (z ~0.9954
        // at zoom 6): ten zoom bands of two classes each.
        XCTAssertLessThan(GlobeSurfaceDepthRank.bias(sourceZoom: 9)
                              + GlobeSurfaceDepthRank.classDepthBand
                              + 257 * GlobeSurfaceDepthRank.layerDepthStep,
                          0.0025)
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
