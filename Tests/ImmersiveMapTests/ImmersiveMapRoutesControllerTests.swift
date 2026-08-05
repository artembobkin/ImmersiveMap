// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The routes controller is the app-facing seam: snapshots are destructive, and
/// removals plus progress durations must survive exactly one consumption.
final class ImmersiveMapRoutesControllerTests: XCTestCase {

    func testSnapshotIsNilUntilSomethingChanges() {
        let controller = ImmersiveMapRoutesController()
        XCTAssertNil(controller.consumeSnapshot())

        controller.add(makeRoute(id: 1))
        XCTAssertNotNil(controller.consumeSnapshot())
        XCTAssertNil(controller.consumeSnapshot())
    }

    func testSnapshotCarriesEveryRouteSortedByNothingButIdentity() throws {
        let controller = ImmersiveMapRoutesController()
        controller.add([makeRoute(id: 2), makeRoute(id: 1)])

        let snapshot = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertEqual(Set(snapshot.routes.map(\.id)), [1, 2])
        XCTAssertTrue(snapshot.removedIds.isEmpty)
    }

    func testRemovalDrainsOnceIntoTheSnapshot() throws {
        let controller = ImmersiveMapRoutesController()
        controller.add(makeRoute(id: 7))
        _ = controller.consumeSnapshot()

        controller.remove(id: 7)
        let snapshot = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertEqual(snapshot.removedIds, [7])
        XCTAssertTrue(snapshot.routes.isEmpty)

        controller.add(makeRoute(id: 8))
        let next = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertTrue(next.removedIds.isEmpty)
    }

    func testSetReplacesContentAndReportsDroppedIds() throws {
        let controller = ImmersiveMapRoutesController()
        controller.add([makeRoute(id: 1), makeRoute(id: 2)])
        _ = controller.consumeSnapshot()

        controller.set([makeRoute(id: 2), makeRoute(id: 3)])
        let snapshot = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertEqual(Set(snapshot.routes.map(\.id)), [2, 3])
        XCTAssertEqual(snapshot.removedIds, [1])
    }

    func testProgressIsClampedAndCarriesItsDuration() throws {
        let controller = ImmersiveMapRoutesController()
        controller.add(makeRoute(id: 4))
        _ = controller.consumeSnapshot()

        controller.setProgress(id: 4, 1.7, duration: 2)
        let snapshot = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertEqual(try XCTUnwrap(snapshot.routes.first).progress, 1)
        XCTAssertEqual(snapshot.progressAnimationsById[4]?.duration, 2)

        controller.setProgress(id: 4, -3)
        let next = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertEqual(try XCTUnwrap(next.routes.first).progress, 0)
        XCTAssertEqual(next.progressAnimationsById[4]?.duration, 0)
    }

    /// The natural app flow is add + setProgress in the same tick, so the
    /// request has to carry where the animation starts: by then the descriptor
    /// already holds the target.
    func testProgressRequestCarriesTheStartTheRouteHadWhenAsked() throws {
        let controller = ImmersiveMapRoutesController()
        controller.add(ImmersiveMapRoute(id: 1,
                                         path: ImmersiveMapGeoPath(waypoints: [GeoCoordinate(latitude: 0, longitude: 0),
                                                                               GeoCoordinate(latitude: 0, longitude: 30)]),
                                         progress: 0))
        controller.setProgress(id: 1, 1, duration: 4)

        let snapshot = try XCTUnwrap(controller.consumeSnapshot())
        let request = try XCTUnwrap(snapshot.progressAnimationsById[1])
        XCTAssertEqual(request.startProgress, 0)
        XCTAssertEqual(request.duration, 4)
        XCTAssertEqual(try XCTUnwrap(snapshot.routes.first).progress, 1)
    }

    /// Two requests between frames animate once, from where the line was.
    func testSecondProgressRequestKeepsTheOriginalStart() throws {
        let controller = ImmersiveMapRoutesController()
        controller.add(makeRoute(id: 1))
        _ = controller.consumeSnapshot()

        controller.setProgress(id: 1, 0.5, duration: 2)
        controller.setProgress(id: 1, 0.9, duration: 3)

        let request = try XCTUnwrap(try XCTUnwrap(controller.consumeSnapshot()).progressAnimationsById[1])
        XCTAssertEqual(request.startProgress, 1, "the route was fully drawn when the first request landed")
        XCTAssertEqual(request.duration, 3)
    }

    func testProgressOnAnUnknownIdDoesNothing() {
        let controller = ImmersiveMapRoutesController()
        controller.setProgress(id: 99, 0.5, duration: 1)
        XCTAssertNil(controller.consumeSnapshot())
    }

    func testClearRemovesEverything() throws {
        let controller = ImmersiveMapRoutesController()
        controller.add([makeRoute(id: 1), makeRoute(id: 2)])
        _ = controller.consumeSnapshot()

        controller.clear()
        let snapshot = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertTrue(snapshot.routes.isEmpty)
        XCTAssertEqual(Set(snapshot.removedIds), [1, 2])
    }

    func testChangeHandlerDetachIsOwnerScoped() {
        let controller = ImmersiveMapRoutesController()
        let oldOwner = NSObject()
        let newOwner = NSObject()
        var calls = 0

        controller.setChangeHandler({ calls += 1 }, owner: oldOwner)
        controller.setChangeHandler({ calls += 1 }, owner: newOwner)
        // The outgoing view tears down after the incoming one rebound the
        // controller, and must not detach the new owner's handler.
        controller.clearChangeHandler(ownedBy: oldOwner)

        controller.add(makeRoute(id: 1))
        XCTAssertEqual(calls, 1)
    }

    private func makeRoute(id: UInt64) -> ImmersiveMapRoute {
        ImmersiveMapRoute(id: id,
                          path: ImmersiveMapGeoPath(waypoints: [GeoCoordinate(latitude: 0, longitude: 0),
                                                                GeoCoordinate(latitude: 0, longitude: 30)]))
    }
}
