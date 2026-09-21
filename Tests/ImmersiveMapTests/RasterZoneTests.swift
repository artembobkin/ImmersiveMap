// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The raster zone: where the flat ground turns from geometry into
/// pictures, measured from the camera and not on the tile grid, and which
/// ground families a picture holds.
final class RasterZoneTests: XCTestCase {
    private let eye = SIMD3<Float>(0, -300, 400)

    private func zone(start: Float = 2, transition: Float = 1,
                      footprints: Bool = true, lines: Bool = true) -> RasterZone {
        RasterZone(isEnabled: true,
                   startCameraDistances: start,
                   transitionCameraDistances: transition,
                   rasterizesBuildingFootprints: footprints,
                   rasterizesGroundLines: lines)
    }

    /// The zone is stated in camera distances, so it keeps its place on
    /// screen through a zoom.
    func testTheSpanScalesWithTheCameraDistance() {
        let span = zone().span(eye: eye)
        XCTAssertEqual(span.start, 1000, accuracy: 1e-3)
        XCTAssertEqual(span.end, 1500, accuracy: 1e-3)
        let closer = zone().span(eye: eye * 0.5)
        XCTAssertEqual(closer.start, 500, accuracy: 1e-3)
        XCTAssertEqual(closer.end, 750, accuracy: 1e-3)
    }

    /// Nothing of a picture nearer than the start, all of it past the end,
    /// and a rising share between.
    func testThePictureShareRampsAcrossTheSpan() {
        let span = RasterZone.Span(start: 1000, end: 1500)
        XCTAssertEqual(span.pictureShare(distance: 0), 0)
        XCTAssertEqual(span.pictureShare(distance: 1000), 0)
        XCTAssertEqual(span.pictureShare(distance: 1250), 0.5, accuracy: 1e-6)
        XCTAssertEqual(span.pictureShare(distance: 1500), 1)
        XCTAssertEqual(span.pictureShare(distance: 9000), 1)
        XCTAssertLessThan(span.pictureShare(distance: 1100), span.pictureShare(distance: 1200))
        let hard = RasterZone.Span(start: 1000, end: 1000)
        XCTAssertEqual(hard.pictureShare(distance: 999), 0)
        XCTAssertEqual(hard.pictureShare(distance: 1000), 1)
    }

    /// A tile is geometry alone while all of it is nearer than the start,
    /// a picture alone once all of it is past the end, and both when the
    /// zone's edge crosses it, wherever the edge falls inside it.
    func testATileDrawsByWhereTheZoneCrossesIt() {
        let span = RasterZone.Span(start: 1000, end: 1500)
        XCTAssertEqual(RasterZone.tileDraw(span: span, eye: eye, tileOriginAndSize: SIMD3(-100, -100, 200)), .vector)
        XCTAssertEqual(RasterZone.tileDraw(span: span, eye: eye, tileOriginAndSize: SIMD3(-100, 2000, 200)), .picture)
        XCTAssertEqual(RasterZone.tileDraw(span: span, eye: eye, tileOriginAndSize: SIMD3(-100, 500, 400)), .blended)
        // A large tile under the camera reaches into the zone with its far
        // corners: both.
        XCTAssertEqual(RasterZone.tileDraw(span: span, eye: eye, tileOriginAndSize: SIMD3(-4000, -4000, 8000)), .blended)
    }

    /// The near ground is never a picture: a tile is a picture alone only
    /// when its nearest point is past the fade.
    func testATileWithAPointNearerThanTheEndKeepsItsGeometry() {
        let span = RasterZone.Span(start: 1000, end: 1500)
        // The nearest point is just inside the fade.
        let nearestInsideFade = SIMD3<Float>(0, 1100, 5000)
        XCTAssertEqual(RasterZone.tileDraw(span: span, eye: eye, tileOriginAndSize: nearestInsideFade), .blended)
    }

    /// The plain fills are in every picture, the footprints and the lines
    /// by their switches, and a lineless rule's tile pictures no lines.
    func testThePictureHoldsTheChosenFamilies() {
        XCTAssertEqual(zone().pictureGroups(drawsLines: true), .all)
        XCTAssertEqual(zone().pictureGroups(drawsLines: false), [.landFills, .buildingFootprints])
        XCTAssertEqual(zone(footprints: false).pictureGroups(drawsLines: true), [.landFills, .groundLines])
        XCTAssertEqual(zone(footprints: false, lines: false).pictureGroups(drawsLines: true), .landFills)
    }

    /// A run's family: ribbons are the ground lines, a fill of the
    /// footprint fade band lies under a building, and a fill's outline
    /// follows its fill.
    func testARunBelongsToItsFamily() {
        func run(mask: Float, flags: UInt32) -> GroundStyleRun {
            GroundStyleRun(indexStart: 0, indexCount: 3, fadeMask: mask, flags: flags)
        }
        XCTAssertEqual(run(mask: 0, flags: 0).group, .landFills)
        XCTAssertEqual(run(mask: 3, flags: GroundStyleRun.alphaOpaqueFlag).group, .landFills)
        XCTAssertEqual(run(mask: LowZoomOverviewFade.footprintFadeMask, flags: 0).group, .buildingFootprints)
        XCTAssertEqual(run(mask: LowZoomOverviewFade.footprintFadeMask,
                           flags: GroundStyleRun.fillOutlineClassFlag).group, .buildingFootprints)
        XCTAssertEqual(run(mask: 0, flags: GroundStyleRun.linesClassFlag).group, .groundLines)
    }

    func testTheSettingsStayInsideTheirRanges() {
        let wild = RasterZone(isEnabled: true, startCameraDistances: -3, transitionCameraDistances: 99,
                              rasterizesBuildingFootprints: true, rasterizesGroundLines: true)
        XCTAssertEqual(wild.startCameraDistances, 0)
        XCTAssertEqual(wild.transitionCameraDistances, Float(RasterZone.transitionRange.upperBound))
    }

    /// The blended picture sits over every fill rank and under the first
    /// ribbon, and the picture that is the whole ground under every fill.
    func testThePictureDepthsBracketTheFillRanks() {
        let step = GlobeSurfaceDepthRank.layerDepthStep
        let firstFill: Float = 1 - step
        let lastFill: Float = 1 - 256 * step
        let firstRibbon: Float = 1 - GlobeSurfaceDepthRank.classDepthBand - step
        XCTAssertLessThan(TileRasterDrawer.groundRankDepth, 1)
        XCTAssertGreaterThan(TileRasterDrawer.groundRankDepth, firstFill)
        XCTAssertLessThan(TileRasterDrawer.overFillsRankDepth, lastFill)
        XCTAssertGreaterThan(TileRasterDrawer.overFillsRankDepth, firstRibbon)
    }
}
