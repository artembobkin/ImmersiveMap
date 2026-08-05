// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapSceneModelsControllerTests: XCTestCase {
    private func makeModel(id: UInt64,
                           latitude: Double = 10,
                           longitude: Double = 20) -> ImmersiveMapSceneModel {
        ImmersiveMapSceneModel(id: id,
                               source: ImmersiveMapSceneModel.Source(url: URL(fileURLWithPath: "/tmp/m\(id).usdz")),
                               coordinate: GeoCoordinate(latitude: latitude, longitude: longitude))
    }

    func testConsumeSnapshotIsNilWithoutChangesAndDestructive() {
        let controller = ImmersiveMapSceneModelsController()
        XCTAssertNil(controller.consumeSnapshot())

        controller.add(makeModel(id: 1))
        let snapshot = controller.consumeSnapshot()
        XCTAssertEqual(snapshot?.models.map(\.id), [1])
        XCTAssertNil(controller.consumeSnapshot(), "Consume must be destructive")
    }

    func testRemoveDrainsIntoRemovedIdsOnce() {
        let controller = ImmersiveMapSceneModelsController()
        controller.add(makeModel(id: 1))
        _ = controller.consumeSnapshot()

        controller.remove(id: 1)
        let snapshot = controller.consumeSnapshot()
        XCTAssertEqual(snapshot?.models.count, 0)
        XCTAssertEqual(snapshot?.removedIds, [1])

        controller.markSnapshotDirty()
        XCTAssertEqual(controller.consumeSnapshot()?.removedIds, [])
    }

    func testSetFullyReplacesAndReportsVanishedIds() {
        let controller = ImmersiveMapSceneModelsController()
        controller.add([makeModel(id: 1), makeModel(id: 2)])
        _ = controller.consumeSnapshot()

        controller.set([makeModel(id: 2), makeModel(id: 3)])
        let snapshot = controller.consumeSnapshot()
        XCTAssertEqual(snapshot?.models.map(\.id).sorted(), [2, 3])
        XCTAssertEqual(snapshot?.removedIds, [1])
    }

    func testTransformMutationsCarryDurationsAndDrain() {
        let controller = ImmersiveMapSceneModelsController()
        controller.add(makeModel(id: 7))
        _ = controller.consumeSnapshot()

        controller.setScale(id: 7, 2.5, duration: 0.5)
        controller.setOrientation(id: 7, headingDegrees: 90, duration: 0.8)
        let snapshot = controller.consumeSnapshot()
        XCTAssertEqual(snapshot?.transformAnimationDurationsById[7], 0.8,
                       "The latest transform mutation duration wins")
        XCTAssertEqual(snapshot?.models.first?.scale, 2.5)
        XCTAssertEqual(snapshot?.models.first?.headingDegrees, 90)

        controller.markSnapshotDirty()
        XCTAssertEqual(controller.consumeSnapshot()?.transformAnimationDurationsById.isEmpty, true)
    }

    func testMoveUpdatesOnlyCoordinate() {
        let controller = ImmersiveMapSceneModelsController()
        controller.add(makeModel(id: 3, latitude: 10, longitude: 20))
        _ = controller.consumeSnapshot()

        controller.move(id: 3, latitude: 11, longitude: 21)
        let snapshot = controller.consumeSnapshot()
        XCTAssertEqual(snapshot?.models.first?.coordinate,
                       GeoCoordinate(latitude: 11, longitude: 21))
        XCTAssertEqual(snapshot?.transformAnimationDurationsById.isEmpty, true)
    }

    func testVersionGrowsMonotonically() {
        let controller = ImmersiveMapSceneModelsController()
        controller.add(makeModel(id: 1))
        let first = controller.consumeSnapshot()?.version ?? 0

        controller.move(id: 1, latitude: 12, longitude: 20)
        controller.setAltitude(id: 1, meters: 50, duration: 0)
        let second = controller.consumeSnapshot()?.version ?? 0
        XCTAssertGreaterThan(second, first)
    }

    func testChangeHandlerIsOwnerScoped() {
        final class Owner {}
        final class Counter {
            var value = 0
        }
        let controller = ImmersiveMapSceneModelsController()
        let ownerA = Owner()
        let ownerB = Owner()
        let counter = Counter()
        controller.setChangeHandler({ counter.value += 1 }, owner: ownerA)

        controller.add(makeModel(id: 1))
        XCTAssertEqual(counter.value, 1)

        // A stale owner must not detach the handler installed by another owner.
        controller.clearChangeHandler(ownedBy: ownerB)
        controller.add(makeModel(id: 2))
        XCTAssertEqual(counter.value, 2)

        controller.clearChangeHandler(ownedBy: ownerA)
        controller.add(makeModel(id: 3))
        XCTAssertEqual(counter.value, 2)
    }

    // MARK: - Path animation completions

    /// The documented contract is exactly once, on the main thread, and a newer
    /// animation must own the completion from the moment it starts.
    @MainActor
    func testSupersedingAnAnimationCompletesTheOldOneOnceWithFalse() {
        let controller = ImmersiveMapSceneModelsController()
        controller.add(makeAnimatableModel())
        var calls: [Bool] = []

        controller.animate(id: 1, along: straightPath, duration: 5) { calls.append($0) }
        controller.animate(id: 1, along: straightPath, duration: 5)

        XCTAssertEqual(calls, [false])
    }

    /// Cancelling before the renderer ever saw the request must leave the model
    /// where it was, not aimed at the destination it never flew to.
    @MainActor
    func testCancellingBeforeTheFirstFrameRestoresTheDescriptor() throws {
        let controller = ImmersiveMapSceneModelsController()
        controller.add(makeAnimatableModel())
        _ = controller.consumeSnapshot()

        var completed: Bool?
        controller.animate(id: 1, along: straightPath, duration: 5) { completed = $0 }
        controller.cancelPathAnimation(id: 1)

        let snapshot = try XCTUnwrap(controller.consumeSnapshot())
        let model = try XCTUnwrap(snapshot.models.first)
        XCTAssertEqual(model.coordinate.longitude, 0, accuracy: 1e-9)
        XCTAssertTrue(snapshot.pathAnimationsById.isEmpty)
        XCTAssertEqual(completed, false)
    }

    /// A result from a superseded animation must not resolve the newer one.
    @MainActor
    func testStaleResultDoesNotCompleteANewerAnimation() throws {
        let controller = ImmersiveMapSceneModelsController()
        controller.add(makeAnimatableModel())

        controller.animate(id: 1, along: straightPath, duration: 5)
        let stale = try XCTUnwrap(try XCTUnwrap(controller.consumeSnapshot()).pathAnimationsById[1])

        var newer: Bool?
        controller.animate(id: 1, along: straightPath, duration: 5) { newer = $0 }
        controller.applyPathAnimationResults([
            SceneModelPathAnimationResult(id: 1,
                                          generation: stale.generation,
                                          finished: true,
                                          coordinate: GeoCoordinate(latitude: 0, longitude: 20),
                                          altitudeMeters: 0,
                                          headingDegrees: 90,
                                          pitchDegrees: 0)
        ])

        XCTAssertNil(newer, "the completion belongs to the newer animation")
    }

    /// The result is where the flight actually stopped, and the descriptor has
    /// to adopt it silently: resending it would fight the renderer.
    @MainActor
    func testResultUpdatesTheDescriptorWithoutDirtyingTheSnapshot() throws {
        let controller = ImmersiveMapSceneModelsController()
        controller.add(makeAnimatableModel())

        var completed: Bool?
        controller.animate(id: 1, along: straightPath, duration: 5) { completed = $0 }
        let request = try XCTUnwrap(try XCTUnwrap(controller.consumeSnapshot()).pathAnimationsById[1])

        controller.applyPathAnimationResults([
            SceneModelPathAnimationResult(id: 1,
                                          generation: request.generation,
                                          finished: false,
                                          coordinate: GeoCoordinate(latitude: 0, longitude: 17),
                                          altitudeMeters: 1_234,
                                          headingDegrees: 90,
                                          pitchDegrees: 0)
        ])

        XCTAssertEqual(completed, false)
        XCTAssertNil(controller.consumeSnapshot(), "adopting a result must not mark the snapshot dirty")

        controller.markSnapshotDirty()
        let model = try XCTUnwrap(try XCTUnwrap(controller.consumeSnapshot()).models.first)
        XCTAssertEqual(model.coordinate.longitude, 17, accuracy: 1e-9)
        XCTAssertEqual(model.altitudeMeters, 1_234, accuracy: 1e-9)
    }

    private var straightPath: ImmersiveMapGeoPath {
        ImmersiveMapGeoPath(from: GeoCoordinate(latitude: 0, longitude: 0),
                            to: GeoCoordinate(latitude: 0, longitude: 40))
    }

    private func makeAnimatableModel() -> ImmersiveMapSceneModel {
        ImmersiveMapSceneModel(id: 1,
                               source: ImmersiveMapSceneModel.Source(url: URL(fileURLWithPath: "/tmp/m.usdz")),
                               coordinate: GeoCoordinate(latitude: 0, longitude: 0))
    }
}
