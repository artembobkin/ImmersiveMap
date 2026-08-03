// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Deterministic with injected times: animations are pure functions of
/// (snapshot, apply time, query time).
final class SceneModelPresentationStateStoreTests: XCTestCase {
    private func makeModel(id: UInt64,
                           latitude: Double = 0,
                           longitude: Double = 0,
                           headingDegrees: Double = 0,
                           scale: Double = 1,
                           altitudeMeters: Double = 0) -> ImmersiveMapSceneModel {
        ImmersiveMapSceneModel(id: id,
                               source: ImmersiveMapSceneModel.Source(url: URL(fileURLWithPath: "/tmp/m.usdz")),
                               coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                               altitudeMeters: altitudeMeters,
                               headingDegrees: headingDegrees,
                               scale: scale)
    }

    private func makeSnapshot(_ models: [ImmersiveMapSceneModel],
                              durations: [UInt64: TimeInterval] = [:]) -> SceneModelsSnapshot {
        SceneModelsSnapshot(models: models,
                            transformAnimationDurationsById: durations,
                            removedIds: [],
                            version: 1)
    }

    func testFreshModelPresentsAtTargetWithoutAnimations() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel(id: 1, latitude: 5, longitude: 6)]), time: 0)

        let presented = store.presentedEntries(at: 0)
        XCTAssertEqual(presented.count, 1)
        XCTAssertEqual(presented[0].projectionBasis,
                       GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 5, longitude: 6)))
        XCTAssertFalse(store.hasActiveAnimations)
    }

    func testCoordinateChangeAnimatesAlongGreatCircleAndSettles() {
        let store = SceneModelPresentationStateStore()
        let start = GeoCoordinate(latitude: 0, longitude: 0)
        let target = GeoCoordinate(latitude: 0, longitude: 0.002)
        store.apply(snapshot: makeSnapshot([makeModel(id: 1)]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel(id: 1, longitude: target.longitude)]), time: 10)
        XCTAssertTrue(store.hasActiveAnimations)

        let duration = SceneModelAnimationMath.positionAnimationDuration(from: start, to: target)
        XCTAssertGreaterThan(duration, 0)

        let mid = store.presentedEntries(at: 10 + duration * 0.5)[0]
        let midLongitude = ImmersiveMapProjection.longitude(fromNormalizedWorldX: mid.projectionBasis.normalizedWorldX) * 180.0 / .pi
        XCTAssertGreaterThan(midLongitude, 0)
        XCTAssertLessThan(midLongitude, target.longitude)

        let settled = store.presentedEntries(at: 10 + duration + 0.01)[0]
        XCTAssertEqual(settled.projectionBasis,
                       GeoProjectionBasis(coordinate: target))
        XCTAssertFalse(store.hasActiveAnimations)
    }

    func testTransformChangeAnimatesWithEasedProgress() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel(id: 1, scale: 1, altitudeMeters: 0)]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel(id: 1, headingDegrees: 90, scale: 3, altitudeMeters: 40)],
                                           durations: [1: 1.0]),
                    time: 100)
        XCTAssertTrue(store.hasActiveAnimations)

        let atStart = store.presentedEntries(at: 100)[0]
        XCTAssertEqual(atStart.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(atStart.altitudeMeters, 0, accuracy: 1e-9)

        // Cubic ease-out at raw progress 0.5 is 0.875.
        let eased = SceneModelAnimationMath.easedProgress(for: 0.5)
        let mid = store.presentedEntries(at: 100.5)[0]
        XCTAssertEqual(mid.scale, 1 + 2 * eased, accuracy: 1e-6)
        XCTAssertEqual(mid.altitudeMeters, 40 * eased, accuracy: 1e-6)
        let expectedMidOrientation = SceneModelAnimationMath.orientation(
            from: SceneModelAnimationMath.orientationQuaternion(headingDegrees: 0, pitchDegrees: 0, rollDegrees: 0),
            to: SceneModelAnimationMath.orientationQuaternion(headingDegrees: 90, pitchDegrees: 0, rollDegrees: 0),
            progress: eased)
        XCTAssertEqual(abs(simd_dot(mid.orientation.vector, expectedMidOrientation.vector)), 1, accuracy: 1e-5)

        let settled = store.presentedEntries(at: 101.01)[0]
        XCTAssertEqual(settled.scale, 3, accuracy: 1e-9)
        XCTAssertEqual(settled.altitudeMeters, 40, accuracy: 1e-9)
        XCTAssertFalse(store.hasActiveAnimations)
    }

    func testTransformSnapWithZeroDuration() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel(id: 1, scale: 1)]), time: 0)
        store.apply(snapshot: makeSnapshot([makeModel(id: 1, scale: 5)]), time: 1)

        let presented = store.presentedEntries(at: 1)[0]
        XCTAssertEqual(presented.scale, 5, accuracy: 1e-9)
        XCTAssertFalse(store.hasActiveAnimations)
    }

    func testRemovedModelDisappearsFromPresentation() {
        let store = SceneModelPresentationStateStore()
        store.apply(snapshot: makeSnapshot([makeModel(id: 1), makeModel(id: 2)]), time: 0)
        XCTAssertEqual(store.presentedEntries(at: 0).count, 2)

        store.apply(snapshot: makeSnapshot([makeModel(id: 2)]), time: 1)
        XCTAssertEqual(store.presentedEntries(at: 1).map(\.id), [2])
        XCTAssertFalse(store.isEmpty)

        store.apply(snapshot: makeSnapshot([]), time: 2)
        XCTAssertTrue(store.isEmpty)
    }
}
