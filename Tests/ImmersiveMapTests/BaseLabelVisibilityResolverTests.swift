// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The per-label rules of the frame path: which labels reserve collision
/// space and which want to be shown, written in place.
final class BaseLabelVisibilityResolverTests: XCTestCase {
    private func input(key: UInt64 = 1, minZoom: Float = 0) -> BaseLabelPresentationInput {
        BaseLabelPresentationInput(labelKey: key, minCameraZoom: minZoom)
    }

    func testTargetVisibilityRequiresHorizonAndCollisionAndZoom() {
        let inputs = [input(key: 1), input(key: 2), input(key: 3), input(key: 4, minZoom: 15)]
        var target: [Bool] = []
        BaseLabelVisibilityResolver.targetVisibility(inputs: inputs,
                                                     collisionVisible: [true, true, false, true],
                                                     horizonVisibility: [true, false, true, true],
                                                     cameraZoom: 14,
                                                     into: &target)
        XCTAssertEqual(target, [true, false, false, false],
                       "Behind the horizon, lost the collision, below its zoom: each hides")
    }

    func testTargetVisibilityResizesTheOutputToTheInputs() {
        var target: [Bool] = [true, true, true, true, true, true]
        BaseLabelVisibilityResolver.targetVisibility(inputs: [input()],
                                                     collisionVisible: [true],
                                                     horizonVisibility: [true],
                                                     cameraZoom: 14,
                                                     into: &target)
        XCTAssertEqual(target, [true])
        BaseLabelVisibilityResolver.targetVisibility(inputs: [input(), input(key: 2)],
                                                     collisionVisible: [true],
                                                     horizonVisibility: [true, true],
                                                     cameraZoom: 14,
                                                     into: &target)
        XCTAssertEqual(target, [true, false], "A missing collision entry counts as hidden")
    }

    /// A label whose anchor a building hides is not shown, and a missing
    /// answer counts as in view: with the probe off nothing changes.
    func testTargetVisibilityHidesOccludedLabels() {
        let inputs = [input(key: 1), input(key: 2), input(key: 3)]
        var target: [Bool] = []
        BaseLabelVisibilityResolver.targetVisibility(inputs: inputs,
                                                     collisionVisible: [true, true, true],
                                                     horizonVisibility: [true, true, true],
                                                     occluded: [false, true],
                                                     cameraZoom: 14,
                                                     into: &target)
        XCTAssertEqual(target, [true, false, true])
    }

    /// Behind a building a label keeps its space only while it fades out,
    /// like one behind the horizon, so the labels around it do not jump.
    func testReservationBehindABuildingLastsTheFadeOut() {
        XCTAssertTrue(BaseLabelVisibilityResolver.reservesSpace(screenVisible: true, horizonVisible: true,
                                                                occluded: true, currentAlpha: 0.4, minCameraZoom: 0, cameraZoom: 14))
        XCTAssertFalse(BaseLabelVisibilityResolver.reservesSpace(screenVisible: true, horizonVisible: true,
                                                                 occluded: true, currentAlpha: 0, minCameraZoom: 0, cameraZoom: 14))
        XCTAssertTrue(BaseLabelVisibilityResolver.reservesSpace(screenVisible: true, horizonVisible: true,
                                                                occluded: false, currentAlpha: 0, minCameraZoom: 0, cameraZoom: 14))
    }

    /// Local detail (house numbers, plaques) keeps to the three by three
    /// tiles around the look-at tile, counted in its own tile's grid, and a
    /// coarser stand-in holding the look-at point counts as inside.
    func testLocalDetailKeepsToTheBlockAroundTheLookAtTile() {
        let local = BaseLabelPresentationInput(labelKey: 1, minCameraZoom: 0, isLocal: true)
        let plain = BaseLabelPresentationInput(labelKey: 2, minCameraZoom: 0, isLocal: false)
        let inputs = [local, local, local, plain, local]
        // The look-at point is in z15 tile (10, 20), inside z14 tile (5, 10).
        let mercator = SIMD2<Double>(10.5 / 32768, 20.5 / 32768)
        let pointInputs = [TilePointInput(uv: .zero, tile: SIMD3(10, 20, 15)),
                           TilePointInput(uv: .zero, tile: SIMD3(11, 21, 15)),
                           TilePointInput(uv: .zero, tile: SIMD3(12, 20, 15)),
                           TilePointInput(uv: .zero, tile: SIMD3(12, 20, 15)),
                           TilePointInput(uv: .zero, tile: SIMD3(5, 10, 14))]
        let anchors = [SIMD4<Float>](repeating: .zero, count: inputs.count)
        var suppressed: [Bool] = []
        let changed = BaseLabelVisibilityResolver.localSuppression(
            inputs: inputs,
            pointInputs: pointInputs,
            anchors: anchors,
            centerWorldMercator: mercator,
            reach: .init(eye: .zero, unitsPerMeter: nil, maximumDistanceMeters: 0),
            into: &suppressed)
        XCTAssertTrue(changed)
        XCTAssertEqual(suppressed, [false, false, true, false, false],
                       "The look-at tile, the diagonal beside it, two tiles away, not local, the coarser stand-in")

        var target: [Bool] = []
        BaseLabelVisibilityResolver.targetVisibility(inputs: inputs,
                                                     collisionVisible: [true, true, true, true, true],
                                                     horizonVisibility: [true, true, true, true, true],
                                                     localSuppressed: suppressed,
                                                     cameraZoom: 17,
                                                     into: &target)
        XCTAssertEqual(target, [true, true, false, true, true])
    }

    /// Inside the block, the distance from the camera decides, measured in
    /// metres through the look-at point's scale.
    func testLocalDetailKeepsToTheDistanceFromTheCamera() {
        let local = BaseLabelPresentationInput(labelKey: 1, minCameraZoom: 0, isLocal: true)
        let mercator = SIMD2<Double>(10.5 / 32768, 20.5 / 32768)
        let tile = TilePointInput(uv: .zero, tile: SIMD3(10, 20, 15))
        // Two units per metre: 300 m is 600 units.
        let reach = BaseLabelVisibilityResolver.LocalDetailReach(eye: SIMD3(0, 0, 100),
                                                                 unitsPerMeter: 2,
                                                                 maximumDistanceMeters: 300)
        var suppressed: [Bool] = []
        BaseLabelVisibilityResolver.localSuppression(inputs: [local, local],
                                                     pointInputs: [tile, tile],
                                                     anchors: [SIMD4(0, 500, 0, 0), SIMD4(0, 700, 0, 0)],
                                                     centerWorldMercator: mercator,
                                                     reach: reach,
                                                     into: &suppressed)
        XCTAssertEqual(suppressed, [false, true])

        let unchanged = BaseLabelVisibilityResolver.localSuppression(inputs: [local, local],
                                                                     pointInputs: [tile, tile],
                                                                     anchors: [SIMD4(0, 500, 0, 0), SIMD4(0, 700, 0, 0)],
                                                                     centerWorldMercator: mercator,
                                                                     reach: reach,
                                                                     into: &suppressed)
        XCTAssertFalse(unchanged, "The same pose answers the same, and asks for no new solve")
    }

    /// Outside the look-at tile a local label keeps its space only while
    /// it fades out, like one below its zoom.
    func testLocalDetailOutsideTheLookAtTileReservesNothingOnceInvisible() {
        XCTAssertTrue(BaseLabelVisibilityResolver.reservesSpace(screenVisible: true, horizonVisible: true,
                                                                localSuppressed: true, currentAlpha: 0.4, minCameraZoom: 0, cameraZoom: 17))
        XCTAssertFalse(BaseLabelVisibilityResolver.reservesSpace(screenVisible: true, horizonVisible: true,
                                                                 localSuppressed: true, currentAlpha: 0, minCameraZoom: 0, cameraZoom: 17))
    }

    func testReservationRemainsDuringFadeOutBehindHorizon() {
        XCTAssertTrue(BaseLabelVisibilityResolver.reservesSpace(screenVisible: true, horizonVisible: false,
                                                                currentAlpha: 0.4, minCameraZoom: 0, cameraZoom: 14),
                      "Still fading out behind the horizon: keeps its space so neighbours do not jump")
        XCTAssertFalse(BaseLabelVisibilityResolver.reservesSpace(screenVisible: true, horizonVisible: false,
                                                                 currentAlpha: 0, minCameraZoom: 0, cameraZoom: 14),
                       "Fully transparent behind the horizon: reserves nothing")
    }

    func testReservationNeedsADrawablePoint() {
        XCTAssertFalse(BaseLabelVisibilityResolver.reservesSpace(screenVisible: false, horizonVisible: true,
                                                                 currentAlpha: 1, minCameraZoom: 0, cameraZoom: 14))
    }

    /// The whole-set pass answers what the single rule answers, label by
    /// label, and a missing occlusion entry counts as in view.
    func testReservationPassMatchesTheRule() {
        let inputs = [input(key: 1), input(key: 2, minZoom: 15), input(key: 3)]
        let points = [ScreenPointOutput(position: .zero, depth: 0, visible: 1),
                      ScreenPointOutput(position: .zero, depth: 0, visible: 1),
                      ScreenPointOutput(position: .zero, depth: 0, visible: 0)]
        var reserves: [Bool] = []
        BaseLabelVisibilityResolver.reservesSpace(inputs: inputs,
                                                  screenPoints: points,
                                                  horizonVisibility: [true, true, true],
                                                  occluded: [],
                                                  localSuppressed: [],
                                                  currentAlphas: [0, 0, 1],
                                                  cameraZoom: 14,
                                                  into: &reserves)
        XCTAssertEqual(reserves, [true, false, false], "In view, below its zoom and invisible, no drawable point")
    }

    func testReservationIsSuppressedBelowMinCameraZoomWhileInvisible() {
        XCTAssertFalse(BaseLabelVisibilityResolver.reservesSpace(screenVisible: true, horizonVisible: true,
                                                                 currentAlpha: 0, minCameraZoom: 15, cameraZoom: 14),
                       "A zoom-hidden POI must not displace visible labels")
        XCTAssertTrue(BaseLabelVisibilityResolver.reservesSpace(screenVisible: true, horizonVisible: true,
                                                                currentAlpha: 0.5, minCameraZoom: 15, cameraZoom: 14),
                      "but one still fading out after crossing the zoom keeps its spot")
        XCTAssertTrue(BaseLabelVisibilityResolver.reservesSpace(screenVisible: true, horizonVisible: true,
                                                                currentAlpha: 0, minCameraZoom: 15, cameraZoom: 16))
    }
}
