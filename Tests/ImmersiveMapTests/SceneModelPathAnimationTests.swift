// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// A model flying along a path. Deterministic with injected times, like the
/// rest of the presentation store: the animation is a pure function of
/// (snapshot, apply time, query time).
final class SceneModelPathAnimationTests: XCTestCase {
    private let start = GeoCoordinate(latitude: 0, longitude: 0)
    private let end = GeoCoordinate(latitude: 0, longitude: 60)

    // MARK: - Trajectory

    func testModelTravelsFromTheFirstWaypointToTheLast() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel()], pathAnimations: [1: makeRequest(duration: 10)]),
                    time: 100)

        XCTAssertTrue(store.hasActiveAnimations)
        assertCoordinate(store.presentedEntries(at: 100)[0], start)
        assertCoordinate(store.presentedEntries(at: 110)[0], end)
        XCTAssertFalse(store.hasActiveAnimations)
    }

    func testAltitudeFollowsTheProfile() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel()],
                                           pathAnimations: [1: makeRequest(duration: 10,
                                                                           curve: .linear,
                                                                           peakAltitudeMeters: 400_000)]),
                    time: 0)

        XCTAssertEqual(store.presentedEntries(at: 0)[0].altitudeMeters, 0, accuracy: 1e-6)
        XCTAssertEqual(store.presentedEntries(at: 5)[0].altitudeMeters, 400_000, accuracy: 1e-3)
        XCTAssertEqual(store.presentedEntries(at: 10)[0].altitudeMeters, 0, accuracy: 1e-6)
    }

    func testLinearAndEaseOutCurvesDifferAtTheMidpoint() {
        let linear = SceneModelPresentationStateStore()
        linear.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        linear.apply(snapshot: makeSnapshot([makeModel()],
                                            pathAnimations: [1: makeRequest(duration: 10, curve: .linear)]),
                     time: 0)

        let eased = SceneModelPresentationStateStore()
        eased.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        eased.apply(snapshot: makeSnapshot([makeModel()],
                                           pathAnimations: [1: makeRequest(duration: 10, curve: .easeOut)]),
                    time: 0)

        // Cubic ease-out at raw progress 0.5 is 0.875.
        XCTAssertEqual(longitude(of: linear.presentedEntries(at: 5)[0]), 30, accuracy: 1e-4)
        XCTAssertEqual(longitude(of: eased.presentedEntries(at: 5)[0]), 52.5, accuracy: 1e-4)
    }

    // MARK: - Orientation

    func testHeadingFollowsTheTrajectoryWhenEnabled() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel()], pathAnimations: [1: makeRequest(duration: 10)]),
                    time: 0)

        // Eastbound along the equator: heading 90.
        let expected = SceneModelAnimationMath.orientationQuaternion(headingDegrees: 90,
                                                                     pitchDegrees: 0,
                                                                     rollDegrees: 0)
        assertOrientation(store.presentedEntries(at: 5)[0].orientation, expected)
    }

    func testHeadingIsLeftAloneWhenDisabled() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel(headingDegrees: 12)]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel(headingDegrees: 12)],
                                           pathAnimations: [1: makeRequest(duration: 10,
                                                                           appliesHeading: false)]),
                    time: 0)

        let expected = SceneModelAnimationMath.orientationQuaternion(headingDegrees: 12,
                                                                     pitchDegrees: 0,
                                                                     rollDegrees: 0)
        assertOrientation(store.presentedEntries(at: 5)[0].orientation, expected)
    }

    /// Positive pitch is nose up in the tangent frame, so a climbing model must
    /// tilt its forward axis away from the surface.
    func testClimbingPitchesTheModelNoseUp() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel()],
                                           pathAnimations: [1: makeRequest(duration: 10,
                                                                           curve: .linear,
                                                                           peakAltitudeMeters: 400_000)]),
                    time: 0)

        // Tangent frame: east +X, north +Y, up +Z. Heading 90 turns forward to
        // east, so the climb must lift the model's forward axis toward up.
        let climbing = store.presentedEntries(at: 1)[0].orientation
        let forward = climbing.act(SIMD3<Float>(0, 1, 0))
        XCTAssertGreaterThan(forward.z, 0)

        let descending = store.presentedEntries(at: 9)[0].orientation.act(SIMD3<Float>(0, 1, 0))
        XCTAssertLessThan(descending.z, 0)
    }

    // MARK: - Conflicts

    func testPathWinsOverAConcurrentMove() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel()],
                                           pathAnimations: [1: makeRequest(duration: 10, curve: .linear)]),
                    time: 0)

        // An unrelated mutation resends every model, here with a move target
        // far off the path: the path must keep the position.
        store.apply(snapshot: makeSnapshot([makeModel(latitude: 70, longitude: -140)]), time: 5)

        let presented = store.presentedEntries(at: 5)[0]
        XCTAssertEqual(longitude(of: presented), 30, accuracy: 1e-4)
        XCTAssertEqual(latitude(of: presented), 0, accuracy: 1e-4)
        XCTAssertTrue(store.hasActiveAnimations)
    }

    func testCancellationLeavesTheModelWhereItIs() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel()],
                                           pathAnimations: [1: makeRequest(duration: 10, curve: .linear)]),
                    time: 0)
        _ = store.presentedEntries(at: 5)

        store.apply(snapshot: makeSnapshot([makeModel()], cancelledPathAnimationIds: [1]), time: 5)

        XCTAssertFalse(store.hasActiveAnimations)
        XCTAssertEqual(longitude(of: store.presentedEntries(at: 9)[0]), 30, accuracy: 1e-4)
    }

    func testFinishedIdsAreReportedExactlyOnce() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel()], pathAnimations: [1: makeRequest(duration: 10)]),
                    time: 0)

        _ = store.presentedEntries(at: 5)
        XCTAssertTrue(store.consumePathAnimationResults().map(\.id).isEmpty)

        _ = store.presentedEntries(at: 10)
        XCTAssertEqual(store.consumePathAnimationResults().map(\.id), [1])

        _ = store.presentedEntries(at: 11)
        XCTAssertTrue(store.consumePathAnimationResults().map(\.id).isEmpty)
    }

    /// A cancellation reports where the flight stopped, so the controller's
    /// descriptor stops naming the destination, but it never reports success.
    func testCancelledAnimationReportsWhereItStoppedAndNotSuccess() throws {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel()],
                                           pathAnimations: [1: makeRequest(duration: 10, curve: .linear)]),
                    time: 0)
        _ = store.presentedEntries(at: 5)
        store.apply(snapshot: makeSnapshot([makeModel()], cancelledPathAnimationIds: [1]), time: 5)

        let result = try XCTUnwrap(store.consumePathAnimationResults().first)
        XCTAssertEqual(result.id, 1)
        XCTAssertFalse(result.finished)
        XCTAssertEqual(result.coordinate.longitude, 30, accuracy: 1e-4)

        _ = store.presentedEntries(at: 20)
        XCTAssertTrue(store.consumePathAnimationResults().isEmpty)
    }

    /// After the flight the descriptor already holds the destination, so a
    /// later unrelated snapshot must not start a move back.
    func testLandingDoesNotSnapBackOnALaterSnapshot() {
        let store = SceneModelPresentationStateStore()
        let landed = makeModel(latitude: end.latitude, longitude: end.longitude, headingDegrees: 90)
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([landed], pathAnimations: [1: makeRequest(duration: 10)]), time: 0)
        _ = store.presentedEntries(at: 10)

        store.apply(snapshot: makeSnapshot([landed]), time: 11)
        XCTAssertFalse(store.hasActiveAnimations)
        assertCoordinate(store.presentedEntries(at: 11)[0], end)
    }

    /// The natural app flow is `add` then `animate` before any frame runs, so
    /// the model and its path request arrive in the same snapshot.
    func testModelAddedAndAnimatedInTheSameSnapshotStartsAtThePathStart() {
        let store = SceneModelPresentationStateStore()
        let landed = makeModel(latitude: end.latitude, longitude: end.longitude)
        store.apply(snapshot: makeSnapshot([landed],
                                           pathAnimations: [1: makeRequest(duration: 10, curve: .linear)]),
                    time: 0)

        XCTAssertTrue(store.hasActiveAnimations)
        assertCoordinate(store.presentedEntries(at: 0)[0], start)
        XCTAssertEqual(longitude(of: store.presentedEntries(at: 5)[0]), 30, accuracy: 1e-4)
        assertCoordinate(store.presentedEntries(at: 10)[0], end)
    }

    func testZeroDurationLandsAndReportsOnTheFirstFrame() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel()], pathAnimations: [1: makeRequest(duration: 0)]),
                    time: 3)

        assertCoordinate(store.presentedEntries(at: 3)[0], end)
        XCTAssertEqual(store.consumePathAnimationResults().map(\.id), [1])
        XCTAssertFalse(store.hasActiveAnimations)
    }

    /// The path owns coordinate, altitude, heading and pitch; scale is not its
    /// business and must still animate, even when the change arrives in the very
    /// snapshot that starts the flight.
    func testScaleStillAppliesWhileFlying() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel(scale: 4)],
                                           durations: [1: 0],
                                           pathAnimations: [1: makeRequest(duration: 10, curve: .linear)]),
                    time: 0)

        XCTAssertEqual(store.presentedEntries(at: 1)[0].scale, 4, accuracy: 1e-9)

        store.apply(snapshot: makeSnapshot([makeModel(scale: 7)], durations: [1: 0]), time: 2)
        XCTAssertEqual(store.presentedEntries(at: 2)[0].scale, 7, accuracy: 1e-9)
        // The flight is untouched by the scale change.
        XCTAssertEqual(longitude(of: store.presentedEntries(at: 5)[0]), 30, accuracy: 1e-4)
    }

    /// A `move` issued mid-flight is ignored, not stored: storing it would make
    /// the next comparison see no change and drop it forever, leaving the
    /// descriptor and the model permanently disagreeing.
    func testMoveDuringAFlightIsIgnoredAndDoesNotResurfaceLater() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel()],
                                           pathAnimations: [1: makeRequest(duration: 10, curve: .linear)]),
                    time: 0)
        store.apply(snapshot: makeSnapshot([makeModel(latitude: 70, longitude: -140)]), time: 5)

        // Lands at the end of the path, not at the swallowed move target.
        _ = store.presentedEntries(at: 10)
        assertCoordinate(store.presentedEntries(at: 10)[0], end)

        // And a snapshot after the flight does not resurrect it either.
        store.apply(snapshot: makeSnapshot([makeModel(latitude: end.latitude, longitude: end.longitude)]),
                    time: 11)
        XCTAssertFalse(store.hasActiveAnimations)
        assertCoordinate(store.presentedEntries(at: 11)[0], end)
    }

    func testDegeneratePathStartsNoAnimation() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel()]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel()],
                                           pathAnimations: [1: SceneModelPathAnimationRequest(
                                               generation: 1,
                                               path: ImmersiveMapGeoPath(waypoints: [start]),
                                               duration: 10,
                                               curve: .linear,
                                               appliesHeading: true,
                                               appliesPitch: true)]),
                    time: 0)

        XCTAssertFalse(store.hasActiveAnimations)
        assertCoordinate(store.presentedEntries(at: 5)[0], start)
    }

    // MARK: - Helpers

    private func makeModel(id: UInt64 = 1,
                           latitude: Double = 0,
                           longitude: Double = 0,
                           headingDegrees: Double = 0,
                           scale: Double = 1) -> ImmersiveMapSceneModel {
        ImmersiveMapSceneModel(id: id,
                               source: ImmersiveMapSceneModel.Source(url: URL(fileURLWithPath: "/tmp/m.usdz")),
                               coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                               headingDegrees: headingDegrees,
                               scale: scale)
    }

    private func makeSnapshot(_ models: [ImmersiveMapSceneModel],
                              durations: [UInt64: TimeInterval] = [:],
                              pathAnimations: [UInt64: SceneModelPathAnimationRequest] = [:],
                              cancelledPathAnimationIds: [UInt64] = []) -> SceneModelsSnapshot {
        SceneModelsSnapshot(models: models,
                            transformAnimationDurationsById: durations,
                            pathAnimationsById: pathAnimations,
                            cancelledPathAnimationIds: cancelledPathAnimationIds,
                            removedIds: [],
                            version: 1)
    }

    private func makeRequest(duration: TimeInterval,
                             curve: ImmersiveMapPathAnimationCurve = .linear,
                             peakAltitudeMeters: Double = 0,
                             appliesHeading: Bool = true,
                             appliesPitch: Bool = true) -> SceneModelPathAnimationRequest {
        SceneModelPathAnimationRequest(generation: 1,
                                       path: ImmersiveMapGeoPath(waypoints: [start, end],
                                                                 peakAltitudeMeters: peakAltitudeMeters),
                                       duration: duration,
                                       curve: curve,
                                       appliesHeading: appliesHeading,
                                       appliesPitch: appliesPitch)
    }

    private func latitude(of presented: PresentedSceneModel) -> Double {
        asin(min(max(Double(presented.projectionBasis.sphereUnit.y), -1), 1)) * 180.0 / .pi
    }

    private func longitude(of presented: PresentedSceneModel) -> Double {
        ImmersiveMapProjection.longitude(fromNormalizedWorldX: presented.projectionBasis.normalizedWorldX)
            * 180.0 / .pi
    }

    private func assertCoordinate(_ presented: PresentedSceneModel,
                                  _ expected: GeoCoordinate,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertEqual(presented.projectionBasis,
                       GeoProjectionBasis(coordinate: expected),
                       file: file,
                       line: line)
    }

    private func assertOrientation(_ actual: simd_quatf,
                                   _ expected: simd_quatf,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        let axis = SIMD3<Float>(0, 1, 0)
        let actualForward = actual.act(axis)
        let expectedForward = expected.act(axis)
        XCTAssertEqual(actualForward.x, expectedForward.x, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(actualForward.y, expectedForward.y, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(actualForward.z, expectedForward.z, accuracy: 1e-4, file: file, line: line)
    }
}
