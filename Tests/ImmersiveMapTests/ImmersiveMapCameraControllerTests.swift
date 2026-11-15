// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapCameraControllerTests: XCTestCase {
    func testNotifyCameraSnapshotChangedStoresAndPublishesSnapshot() {
        let controller = ImmersiveMapCameraController()
        let position = ImmersiveMapCameraPosition(latitudeDegrees: 55,
                                                  longitudeDegrees: 37,
                                                  zoom: 6,
                                                  bearing: 0.2,
                                                  pitch: 0.3)
        let snapshot = ImmersiveMapCameraSnapshot(position: position,
                                                  bearingLimits: ImmersiveMapCameraBearingLimits(maximumAbsoluteBearing: 1),
                                                  pitchLimits: ImmersiveMapCameraAngleLimits(minimum: 0,
                                                                                             maximum: 0.8),
                                                  isSphericalSurfaceActive: false)
        var receivedSnapshot: ImmersiveMapCameraSnapshot?

        controller.onCameraSnapshotChanged = { snapshot in
            receivedSnapshot = snapshot
        }
        controller.notifyCameraSnapshotChanged(snapshot)

        XCTAssertEqual(controller.currentCameraSnapshot(), snapshot)
        XCTAssertEqual(receivedSnapshot, snapshot)
    }
}
