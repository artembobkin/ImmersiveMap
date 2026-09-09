// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The distance LOD of the roads: a fade ring about the look-at point in
/// camera distances, a tile entirely beyond the outer radius draws no
/// roads, a tile touching the ring keeps its draws (the shader fades and
/// clips them), and the ring scales with the camera distance.
final class RoadDistanceLODTests: XCTestCase {
    func testTheBandIsAMultipleOfTheCameraDistance() {
        let band = RoadDistanceLOD.fadeWorldDistances(cameraDistance: 2)
        XCTAssertEqual(band.start, 2 * RoadDistanceLOD.fadeStartCameraDistances, accuracy: 1e-5)
        XCTAssertEqual(band.end, 2 * RoadDistanceLOD.fadeEndCameraDistances, accuracy: 1e-5)
        let farther = RoadDistanceLOD.fadeWorldDistances(cameraDistance: 4)
        XCTAssertEqual(farther.end, 2 * band.end, accuracy: 1e-5, "Twice the camera distance, twice the reach")
        XCTAssertLessThan(RoadDistanceLOD.fadeStartCameraDistances, RoadDistanceLOD.fadeEndCameraDistances)
    }

    func testTheFloorInMetersHoldsTheRingOpenCloseUp() {
        // Camera distance 1 world unit, 100 units per metre: the knobs
        // alone give 2 and 8 units, far under an 800 m floor (80000 units).
        let floored = RoadDistanceLOD.fadeWorldDistances(cameraDistance: 1, unitsPerMeter: 100,
                                                         startCameraDistances: 2, endCameraDistances: 8,
                                                         minimumEndMeters: 800)
        XCTAssertEqual(floored.end, 80000, accuracy: 1e-2, "The outer radius is the floor")
        XCTAssertEqual(floored.start, 20000, accuracy: 1e-2, "The inner radius keeps its share, a quarter")
        // Zoomed out, the knobs win and the floor is not felt.
        let free = RoadDistanceLOD.fadeWorldDistances(cameraDistance: 100000, unitsPerMeter: 100,
                                                      startCameraDistances: 2, endCameraDistances: 8,
                                                      minimumEndMeters: 800)
        XCTAssertEqual(free.end, 800000, accuracy: 1e-1)
        XCTAssertEqual(free.start, 200000, accuracy: 1e-1)
        // No metre scale (the default), no floor.
        XCTAssertEqual(RoadDistanceLOD.fadeWorldDistances(cameraDistance: 1, startCameraDistances: 2, endCameraDistances: 8).end, 8, accuracy: 1e-6)
        XCTAssertEqual(RoadDistanceLOD.clampMinimumFadeEndMeters(-5), 0)
        XCTAssertEqual(RoadDistanceLOD.clampMinimumFadeEndMeters(.infinity), RoadDistanceLOD.minimumFadeEndMeters)
        XCTAssertTrue(RoadDistanceLOD.minimumFadeEndMetersRange.contains(RoadDistanceLOD.minimumFadeEndMeters))
    }

    func testTheKnobsScaleTheBandAndTheEndNeverFallsBelowTheStart() {
        let band = RoadDistanceLOD.fadeWorldDistances(cameraDistance: 2, startCameraDistances: 1, endCameraDistances: 4)
        XCTAssertEqual(band.start, 2, accuracy: 1e-6)
        XCTAssertEqual(band.end, 8, accuracy: 1e-6)
        let inverted = RoadDistanceLOD.fadeWorldDistances(cameraDistance: 2, startCameraDistances: 4, endCameraDistances: 1)
        XCTAssertEqual(inverted.start, 8, accuracy: 1e-6)
        XCTAssertEqual(inverted.end, 8, accuracy: 1e-6, "An end below the start is a hard cut at the start")
    }

    func testADegenerateCameraDistanceDisablesTheFade() {
        let band = RoadDistanceLOD.fadeWorldDistances(cameraDistance: 0)
        XCTAssertEqual(band.start, .infinity)
        XCTAssertEqual(band.end, .infinity)
        XCTAssertEqual(RoadDistanceLOD.fadeWorldDistances(cameraDistance: .nan).end, .infinity)
        XCTAssertFalse(RoadDistanceLOD.tileBeyondCutoff(centerWorld: .zero,
                                                        tileOriginAndSize: SIMD3<Float>(1000, 1000, 10),
                                                        cutoffWorldDistance: .infinity))
        XCTAssertEqual(TileRoadDistanceFadeUniform.disabled.enabled, 0)
        XCTAssertEqual(TileRoadDistanceFadeUniform.fade(centerWorld: .zero, startWorld: 1, endWorld: 2).enabled, 1)
    }

    func testTheNearestPointOfTheTileToTheLookAtDecidesTheSkip() {
        let lookAt = SIMD2<Float>(10, -20)
        let cutoff = RoadDistanceLOD.fadeWorldDistances(cameraDistance: 1).end
        // The tile's near edge lies inside the ring, its far corner far
        // beyond: the draws stay (the shader fades and clips them).
        let straddling = SIMD3<Float>(lookAt.x + cutoff - 1, lookAt.y - 5, 100)
        XCTAssertFalse(RoadDistanceLOD.tileBeyondCutoff(centerWorld: lookAt,
                                                        tileOriginAndSize: straddling,
                                                        cutoffWorldDistance: cutoff))
        // The whole tile past the outer radius: no draws.
        let beyond = SIMD3<Float>(lookAt.x + cutoff + 1, lookAt.y - 5, 100)
        XCTAssertTrue(RoadDistanceLOD.tileBeyondCutoff(centerWorld: lookAt,
                                                       tileOriginAndSize: beyond,
                                                       cutoffWorldDistance: cutoff))
        // The tile under the look-at point is nearest of all, and the
        // measure is on the ground plane: the eye's height plays no part.
        XCTAssertFalse(RoadDistanceLOD.tileBeyondCutoff(centerWorld: lookAt,
                                                        tileOriginAndSize: SIMD3<Float>(lookAt.x - 5, lookAt.y - 5, 10),
                                                        cutoffWorldDistance: cutoff))
        // Diagonally past the corner: the corner is the nearest point.
        let cornerTile = SIMD3<Float>(lookAt.x + cutoff * 0.8, lookAt.y + cutoff * 0.8, 100)
        XCTAssertTrue(RoadDistanceLOD.tileBeyondCutoff(centerWorld: lookAt,
                                                       tileOriginAndSize: cornerTile,
                                                       cutoffWorldDistance: cutoff))
    }

    func testTheKnobsAreClamped() {
        XCTAssertEqual(RoadDistanceLOD.clampCameraDistances(100, fallback: 1), RoadDistanceLOD.cameraDistancesRange.upperBound)
        XCTAssertEqual(RoadDistanceLOD.clampCameraDistances(0, fallback: 1), RoadDistanceLOD.cameraDistancesRange.lowerBound)
        XCTAssertEqual(RoadDistanceLOD.clampCameraDistances(.nan, fallback: 1), 1)
        XCTAssertTrue(RoadDistanceLOD.cameraDistancesRange.contains(RoadDistanceLOD.fadeStartCameraDistances))
        XCTAssertTrue(RoadDistanceLOD.cameraDistancesRange.contains(RoadDistanceLOD.fadeEndCameraDistances))
    }

    func testTheDebugControlsCarryTheBandInOrder() {
        let controls = DebugOverlayControlState()
        XCTAssertEqual(controls.snapshot().roadFadeStartCameraDistances, RoadDistanceLOD.fadeStartCameraDistances)
        XCTAssertEqual(controls.snapshot().roadFadeEndCameraDistances, RoadDistanceLOD.fadeEndCameraDistances)
        controls.setRoadFadeStartCameraDistances(2)
        controls.setRoadFadeEndCameraDistances(6)
        XCTAssertEqual(controls.snapshot().roadFadeStartCameraDistances, 2)
        XCTAssertEqual(controls.snapshot().roadFadeEndCameraDistances, 6)
        controls.setRoadFadeStartCameraDistances(8)
        XCTAssertEqual(controls.snapshot().roadFadeEndCameraDistances, 8, "The snapshot's end never falls below its start")
        controls.setRoadFadeEndCameraDistances(1000)
        XCTAssertEqual(controls.snapshot().roadFadeEndCameraDistances, RoadDistanceLOD.cameraDistancesRange.upperBound)
        XCTAssertEqual(controls.snapshot().roadFadeMinimumEndMeters, RoadDistanceLOD.minimumFadeEndMeters)
        controls.setRoadFadeMinimumEndMeters(1200)
        XCTAssertEqual(controls.snapshot().roadFadeMinimumEndMeters, 1200)
    }
}
