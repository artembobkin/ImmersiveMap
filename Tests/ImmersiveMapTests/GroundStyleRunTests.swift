// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd
@testable import ImmersiveMap
import XCTest

/// The per-style runs of the ground index buffer: what the sphere drawer
/// layers the ground by. The parser's contract is one contiguous run per
/// style in ascending order; the scanner turns it into ranges and carries
/// the per-style opacity inputs.
final class GroundStyleRunTests: XCTestCase {
    private func vertex(_ style: UInt8) -> TileVertexIn {
        TileVertexIn(position: SIMD2<Int16>(0, 0), styleIndex: style, lineDistance: 0, lineParameter: 0)
    }

    private func makeGround(styleOfTriangle: [UInt8],
                            styles: [TilePolygonStyle],
                            masks: [Float]) -> PreparedTileCPU.GeometryLayer {
        var vertices: [TileVertexIn] = []
        var indices: [UInt32] = []
        for style in styleOfTriangle {
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: [vertex(style), vertex(style), vertex(style)])
            indices.append(contentsOf: [base, base + 1, base + 2])
        }
        return PreparedTileCPU.GeometryLayer(vertices: vertices,
                                             indices: indices,
                                             styles: styles,
                                             overviewStyleMasks: masks)
    }

    func testScannerSplitsContiguousStyleRuns() {
        let opaque = TilePolygonStyle(color: SIMD4<Float>(1, 0, 0, 1), streetColor: SIMD4<Float>(0, 1, 0, 1))
        let translucent = TilePolygonStyle(color: SIMD4<Float>(1, 0, 0, 0.5), streetColor: SIMD4<Float>(0, 1, 0, 1))
        let ground = makeGround(styleOfTriangle: [0, 0, 1, 2, 2, 2],
                                styles: [opaque, translucent, opaque],
                                masks: [0, 1, 3])
        let runs = GroundStyleRunScanner.scan(ground: ground)
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0], GroundStyleRun(indexStart: 0, indexCount: 6, fadeMask: 0, flags: 1))
        XCTAssertEqual(runs[1], GroundStyleRun(indexStart: 6, indexCount: 3, fadeMask: 1, flags: 0))
        XCTAssertEqual(runs[2], GroundStyleRun(indexStart: 9, indexCount: 9, fadeMask: 3, flags: 1))
    }

    func testScannerHandlesEmptyGround() {
        let ground = makeGround(styleOfTriangle: [], styles: [], masks: [])
        XCTAssertEqual(GroundStyleRunScanner.scan(ground: ground), [])
    }

    /// A style with a fully opaque palette is opaque only while its zoom
    /// fade is exactly 1; the CPU mirror must agree with the shader's
    /// tileStyleFade band for band.
    func testFadeIsOneMirrorsTheShaderBands() {
        let fade = TileOverviewFadeUniform(overviewAlpha: 1.0,
                                           roadAlpha: 0.5,
                                           landuseAlpha: 0.0,
                                           pixelsPerPoint: 2,
                                           cameraZoom: 4.0)
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(mask: 0, overviewFade: fade))
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(mask: 1, overviewFade: fade))
        XCTAssertFalse(TileStyleFadeMath.fadeIsOne(mask: 2, overviewFade: fade))
        XCTAssertFalse(TileStyleFadeMath.fadeIsOne(mask: 3, overviewFade: fade))
        // Class fade: mask 13 fades in from zoom 3, fully in at zoom 4.
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(mask: 13, overviewFade: fade))
        // Mask 14 fades in from zoom 4: not fully in yet at zoom 4.
        XCTAssertFalse(TileStyleFadeMath.fadeIsOne(mask: 14, overviewFade: fade))
    }
}
