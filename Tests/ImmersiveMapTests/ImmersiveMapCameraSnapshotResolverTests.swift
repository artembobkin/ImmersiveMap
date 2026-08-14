// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapCameraSnapshotResolverTests: XCTestCase {
    func testResolverExposesSphericalBearingAndPitchLimits() {
        let position = ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                  longitudeDegrees: 0,
                                                  zoom: 1,
                                                  bearing: Float.pi / 2,
                                                  pitch: Float.pi / 2)
        let constraints = CameraConstraints(bearing: CameraBearingConstraint(maximumAbsoluteBearing: Float.pi / 12),
                                            pitch: CameraPitchConstraint(minimumPitch: 0, maximumPitch: Float.pi / 8))

        let snapshot = ImmersiveMapCameraSnapshotResolver.resolve(position: position,
                                                                  constraints: constraints,
                                                                  isSphericalSurfaceActive: true)

        XCTAssertEqual(snapshot.bearingLimits.minimum, -Float.pi / 12, accuracy: 0.0001)
        XCTAssertEqual(snapshot.bearingLimits.maximum, Float.pi / 12, accuracy: 0.0001)
        XCTAssertEqual(snapshot.bearingLimits.maximumAbsoluteBearing, Float.pi / 12, accuracy: 0.0001)
        XCTAssertEqual(snapshot.pitchLimits.minimum, 0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.pitchLimits.maximum, Float.pi / 8, accuracy: 0.0001)
        XCTAssertTrue(snapshot.isSphericalSurfaceActive)
        XCTAssertEqual(snapshot.position.bearing, Float.pi / 12, accuracy: 0.0001)
        XCTAssertEqual(snapshot.position.pitch, Float.pi / 8, accuracy: 0.0001)
    }

    func testResolverExposesFlatBearingAsFullRotation() {
        let position = ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                  longitudeDegrees: 0,
                                                  zoom: 8,
                                                  bearing: -Float.pi / 2,
                                                  pitch: Float.pi / 5)
        let constraints = CameraConstraints(bearing: CameraBearingConstraint(maximumAbsoluteBearing: nil),
                                            pitch: CameraPitchConstraint(minimumPitch: 0, maximumPitch: Float.pi / 3))

        let snapshot = ImmersiveMapCameraSnapshotResolver.resolve(position: position,
                                                                  constraints: constraints,
                                                                  isSphericalSurfaceActive: false)

        XCTAssertEqual(snapshot.bearingLimits.minimum, -Float.pi, accuracy: 0.0001)
        XCTAssertEqual(snapshot.bearingLimits.maximum, Float.pi, accuracy: 0.0001)
        XCTAssertEqual(snapshot.bearingLimits.maximumAbsoluteBearing, Float.pi, accuracy: 0.0001)
        XCTAssertEqual(snapshot.pitchLimits.maximum, Float.pi / 3, accuracy: 0.0001)
        XCTAssertFalse(snapshot.isSphericalSurfaceActive)
        XCTAssertEqual(snapshot.position.bearing, -Float.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(snapshot.position.pitch, Float.pi / 5, accuracy: 0.0001)
    }

    func testResolverExposesPitchFloorAndLiftsThePosition() {
        // The snapshot is what a custom control panel sizes its sliders from,
        // so a configured floor must be visible there and the reported
        // position must already sit on it.
        let position = ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                  longitudeDegrees: 0,
                                                  zoom: 8,
                                                  bearing: 0,
                                                  pitch: 0)
        let constraints = CameraConstraints(bearing: CameraBearingConstraint(maximumAbsoluteBearing: nil),
                                            pitch: CameraPitchConstraint(minimumPitch: 0.3, maximumPitch: 0.9))

        let snapshot = ImmersiveMapCameraSnapshotResolver.resolve(position: position,
                                                                  constraints: constraints,
                                                                  isSphericalSurfaceActive: false)

        XCTAssertEqual(snapshot.pitchLimits.minimum, 0.3, accuracy: 0.0001)
        XCTAssertEqual(snapshot.pitchLimits.maximum, 0.9, accuracy: 0.0001)
        XCTAssertEqual(snapshot.position.pitch, 0.3, accuracy: 0.0001)
    }
}
