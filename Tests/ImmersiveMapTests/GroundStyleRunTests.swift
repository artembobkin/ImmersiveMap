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
                            masks: [SIMD2<Float>]) -> PreparedTileCPU.GeometryLayer {
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
                                             styleZoomFades: masks)
    }

    private let none = ImmersiveMapZoomFade.none.shaderPair
    private let fadeIn = ImmersiveMapZoomFade.fadeIn(from: 3, to: 4).shaderPair
    private let fadeOut = ImmersiveMapZoomFade.fadeOut(from: 7, to: 8).shaderPair

    func testScannerSplitsContiguousStyleRuns() {
        let opaque = TilePolygonStyle(color: SIMD4<Float>(1, 0, 0, 1))
        let translucent = TilePolygonStyle(color: SIMD4<Float>(1, 0, 0, 0.5))
        let ground = makeGround(styleOfTriangle: [0, 0, 1, 2, 2, 2],
                                styles: [opaque, translucent, opaque],
                                masks: [none, fadeIn, fadeOut])
        let runs = GroundStyleRunScanner.scan(ground: ground)
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0], GroundStyleRun(indexStart: 0, indexCount: 6, zoomFade: none, flags: 1))
        XCTAssertEqual(runs[1], GroundStyleRun(indexStart: 6, indexCount: 3, zoomFade: fadeIn, flags: 0))
        XCTAssertEqual(runs[2], GroundStyleRun(indexStart: 9, indexCount: 9, zoomFade: fadeOut, flags: 1))
    }

    /// The second segment: the ribbons, one run per style with the lines
    /// class flag, after the fills; the fill runs before it keep their
    /// class.
    func testScannerSplitsTheRibbonSegment() {
        let opaque = TilePolygonStyle(color: SIMD4<Float>(1, 0, 0, 1))
        var vertices: [TileVertexIn] = []
        var indices: [UInt32] = []
        // Two fills (styles 0 and 1), then one ribbon (style 1).
        for style: UInt8 in [0, 1] {
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: [vertex(style), vertex(style), vertex(style)])
            indices.append(contentsOf: [base, base + 1, base + 2])
        }
        let fillsIndexCount = indices.count
        let ribbonBase = UInt32(vertices.count)
        vertices.append(contentsOf: [vertex(1), vertex(1), vertex(1)])
        indices.append(contentsOf: [ribbonBase, ribbonBase + 1, ribbonBase + 2])
        let ground = PreparedTileCPU.GeometryLayer(vertices: vertices,
                                                   indices: indices,
                                                   styles: [opaque, opaque],
                                                   styleZoomFades: [none, fadeOut],
                                                   fillsIndexCount: fillsIndexCount)
        let runs = GroundStyleRunScanner.scan(ground: ground)
        XCTAssertEqual(runs, [
            GroundStyleRun(indexStart: 0, indexCount: 3, zoomFade: none, flags: 1),
            GroundStyleRun(indexStart: 3, indexCount: 3, zoomFade: fadeOut, flags: 1),
            GroundStyleRun(indexStart: 6, indexCount: 3, zoomFade: fadeOut, flags: 3)
        ])
        XCTAssertTrue(runs[0].isFillsClass)
        XCTAssertFalse(runs[0].isLinesClass)
        XCTAssertFalse(runs[2].isFillsClass)
        XCTAssertTrue(runs[2].isLinesClass)
    }

    func testScannerHandlesEmptyGround() {
        let ground = makeGround(styleOfTriangle: [], styles: [], masks: [])
        XCTAssertEqual(GroundStyleRunScanner.scan(ground: ground), [])
    }

    /// A style with a fully opaque palette is opaque only while its zoom
    /// fade is exactly 1, and its run is skipped while the fade is exactly
    /// 0. The CPU mirror must agree with the shader's tileStyleFade at the
    /// ends of every fade, in and out.
    func testTheFadeMirrorAgreesAtTheEndsOfAFade() {
        func uniform(_ zoom: Float) -> TileOverviewFadeUniform {
            TileOverviewFadeUniform(pixelsPerPoint: 2, cameraZoom: zoom)
        }
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(zoomFade: none, overviewFade: uniform(0)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsZero(zoomFade: none, overviewFade: uniform(0)))

        // In from 3 to 4.
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(zoomFade: fadeIn, overviewFade: uniform(3)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsOne(zoomFade: fadeIn, overviewFade: uniform(3.5)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsZero(zoomFade: fadeIn, overviewFade: uniform(3.5)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(zoomFade: fadeIn, overviewFade: uniform(4)))

        // Out from 7 to 8.
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(zoomFade: fadeOut, overviewFade: uniform(7)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsOne(zoomFade: fadeOut, overviewFade: uniform(7.5)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(zoomFade: fadeOut, overviewFade: uniform(8)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(zoomFade: fadeOut, overviewFade: uniform(12)))
    }
}
