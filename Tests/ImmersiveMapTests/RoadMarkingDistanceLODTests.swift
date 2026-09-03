// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The distance LOD of road paint: past the cutoff the thinnest marking is
/// under the resolvable width, so skipping a tile's marking draws there is
/// invisible by construction, and a tile that touches the resolvable zone
/// keeps its paint whole.
final class RoadMarkingDistanceLODTests: XCTestCase {
    func testCutoffPutsTheThinnestMarkingAtTheResolvableWidth() {
        let heightPx: Float = 2796
        let unitsPerMeter: Float = 1.5
        let cutoff = RoadMarkingDistanceLOD.cutoffWorldDistance(drawableHeightPx: heightPx,
                                                                unitsPerMeter: unitsPerMeter)
        // Project the marking width at the cutoff distance through the same
        // camera: it must land exactly on the resolvability threshold.
        let focalPx = (heightPx * 0.5) / tan(RenderCamera.verticalFovRadians * 0.5)
        let widthWorld = RoadMarkingDistanceLOD.thinnestMarkingMetres * unitsPerMeter
        let widthPx = widthWorld * focalPx / cutoff
        XCTAssertEqual(widthPx, RoadMarkingDistanceLOD.minimumResolvablePixels, accuracy: 1e-4)
    }

    func testDegenerateInputsDisableTheCutoff() {
        XCTAssertEqual(RoadMarkingDistanceLOD.cutoffWorldDistance(drawableHeightPx: 0, unitsPerMeter: 1), .infinity)
        XCTAssertEqual(RoadMarkingDistanceLOD.cutoffWorldDistance(drawableHeightPx: 100, unitsPerMeter: 0), .infinity)
        XCTAssertFalse(RoadMarkingDistanceLOD.tileBeyondCutoff(cameraEye: SIMD3<Float>(0, 0, 1),
                                                               tileOriginAndSize: SIMD3<Float>(1000, 1000, 10),
                                                               cutoffWorldDistance: .infinity),
                       "An infinite cutoff keeps every tile's paint")
    }

    func testNearestPointOfTheTileDecides() {
        let eye = SIMD3<Float>(0, 0, 10)
        // A tile whose near edge is inside the cutoff keeps its paint even
        // though its far corner is beyond it.
        let straddling = SIMD3<Float>(50, -5, 100)
        XCTAssertFalse(RoadMarkingDistanceLOD.tileBeyondCutoff(cameraEye: eye,
                                                               tileOriginAndSize: straddling,
                                                               cutoffWorldDistance: 60))
        // A tile entirely past the cutoff drops its paint.
        let far = SIMD3<Float>(100, 100, 10)
        XCTAssertTrue(RoadMarkingDistanceLOD.tileBeyondCutoff(cameraEye: eye,
                                                              tileOriginAndSize: far,
                                                              cutoffWorldDistance: 60))
        // The camera above the tile: the vertical distance alone decides.
        let underCamera = SIMD3<Float>(-5, -5, 10)
        XCTAssertTrue(RoadMarkingDistanceLOD.tileBeyondCutoff(cameraEye: SIMD3<Float>(0, 0, 100),
                                                              tileOriginAndSize: underCamera,
                                                              cutoffWorldDistance: 60))
        XCTAssertFalse(RoadMarkingDistanceLOD.tileBeyondCutoff(cameraEye: SIMD3<Float>(0, 0, 30),
                                                               tileOriginAndSize: underCamera,
                                                               cutoffWorldDistance: 60))
    }

    func testMarkingBandMatchesOnlyTheMarkingMask() {
        XCTAssertTrue(TileStyleFadeMath.isMarkingBand(mask: 4))
        XCTAssertFalse(TileStyleFadeMath.isMarkingBand(mask: 0))
        XCTAssertFalse(TileStyleFadeMath.isMarkingBand(mask: 1))
        XCTAssertFalse(TileStyleFadeMath.isMarkingBand(mask: 2))
        XCTAssertFalse(TileStyleFadeMath.isMarkingBand(mask: 3))
        XCTAssertFalse(TileStyleFadeMath.isMarkingBand(mask: 14),
                       "A class fade mask (10 + startZoom) is never road paint")
    }
}
