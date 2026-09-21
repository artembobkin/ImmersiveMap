// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The raster zone on the sphere: the grid a picture is laid over, how a
/// tile is sorted against the zone, and what a picture holds.
final class TileSphereRasterTests: XCTestCase {
    /// A picture's grid is as fine as the parser's own split of a tile of
    /// that zoom, so its chords sag no more than the vector ground's, and
    /// never under four cells.
    func testTheGridFollowsTheGroundsSplit() {
        XCTAssertEqual(TileSphereRasterDrawer.gridCells(tileZoom: 0), 64)
        XCTAssertEqual(TileSphereRasterDrawer.gridCells(tileZoom: 3), 32)
        XCTAssertEqual(TileSphereRasterDrawer.gridCells(tileZoom: 5), 16)
        XCTAssertEqual(TileSphereRasterDrawer.gridCells(tileZoom: 6), 8)
        XCTAssertEqual(TileSphereRasterDrawer.gridCells(tileZoom: 9), 4)
        XCTAssertEqual(TileSphereRasterDrawer.gridCells(tileZoom: 14), 4)
        for zoom in 0 ... 9 {
            let step = GroundGeometrySubdivider.step(forTileZoom: zoom) ?? 0
            XCTAssertEqual(TileSphereRasterDrawer.gridCells(tileZoom: zoom) * step, 4096, "z\(zoom)")
        }
    }

    /// A tile is geometry while its whole bound is nearer than the zone's
    /// start, a picture once the whole bound is past the fade, and both in
    /// between.
    func testATileIsSortedByItsBound() {
        let span = RasterZone.Span(start: 10, end: 14)
        let eye = SIMD3<Float>(0, 0, 5)
        func draw(_ center: SIMD3<Float>, radius: Float, unfurling: Bool = false) -> RasterZone.TileDraw {
            GlobeVectorSurfaceRenderSubsystem.tileDraw(span: span, eye: eye, boundCenter: center,
                                                       boundRadius: radius, isUnfurling: unfurling)
        }
        XCTAssertEqual(draw(SIMD3(0, 0, 0), radius: 2), .vector)
        XCTAssertEqual(draw(SIMD3(0, 0, -4), radius: 2), .blended, "the far side of the bound is past the start")
        XCTAssertEqual(draw(SIMD3(0, 0, -12), radius: 2), .picture)
        XCTAssertEqual(draw(SIMD3(0, 0, -12), radius: 4), .blended, "the near side of the bound is inside the fade")
        XCTAssertEqual(draw(SIMD3(0, 0, 0), radius: 20), .blended, "a bound the eye is inside reaches past the start")
    }

    /// Through the unfurl the bound does not hold the surface: every tile
    /// is drawn both ways and the pixel's distance decides.
    func testThroughTheUnfurlEveryTileIsBlended() {
        let span = RasterZone.Span(start: 10, end: 14)
        let eye = SIMD3<Float>(0, 0, 5)
        for center in [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, -40)] {
            XCTAssertEqual(GlobeVectorSurfaceRenderSubsystem.tileDraw(span: span, eye: eye, boundCenter: center,
                                                                      boundRadius: 1, isUnfurling: true), .blended)
        }
    }

    /// A picture on the sphere holds every fill, and the lines by the
    /// zone's switch and the rule's.
    func testAPictureHoldsEveryFill() {
        func zone(footprints: Bool, lines: Bool) -> RasterZone {
            RasterZone(isEnabled: true, startCameraDistances: 1, transitionCameraDistances: 1,
                       rasterizesBuildingFootprints: footprints, rasterizesGroundLines: lines)
        }
        typealias Subsystem = GlobeVectorSurfaceRenderSubsystem
        XCTAssertEqual(Subsystem.pictureGroups(zone: zone(footprints: false, lines: false), drawsLines: true),
                       [.landFills, .buildingFootprints])
        XCTAssertEqual(Subsystem.pictureGroups(zone: zone(footprints: true, lines: true), drawsLines: true), .all)
        XCTAssertEqual(Subsystem.pictureGroups(zone: zone(footprints: true, lines: true), drawsLines: false),
                       [.landFills, .buildingFootprints])
    }

    /// The grid uniform's layout is the shader struct's.
    func testTheGridUniformMatchesTheShader() {
        XCTAssertEqual(MemoryLayout<TileSphereRasterGridUniform>.stride, 8)
        XCTAssertEqual(MemoryLayout<TileSphereRasterGridUniform>.offset(of: \.rankDepth), 4)
    }
}
