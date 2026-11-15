// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMap
import XCTest

final class ImmersiveMapCameraSnapshotTests: XCTestCase {
    func testAngleLimitsClampValuesIntoRange() {
        let limits = ImmersiveMapCameraAngleLimits(minimum: -0.25, maximum: 0.5)

        XCTAssertEqual(limits.clamped(-1), -0.25, accuracy: 0.0001)
        XCTAssertEqual(limits.clamped(0.25), 0.25, accuracy: 0.0001)
        XCTAssertEqual(limits.clamped(1), 0.5, accuracy: 0.0001)
    }

    func testBearingLimitsExposeSymmetricRangeAndClampNormalizedBearing() {
        let limits = ImmersiveMapCameraBearingLimits(maximumAbsoluteBearing: Float.pi / 4)

        XCTAssertEqual(limits.maximumAbsoluteBearing, Float.pi / 4, accuracy: 0.0001)
        XCTAssertEqual(limits.minimum, -Float.pi / 4, accuracy: 0.0001)
        XCTAssertEqual(limits.maximum, Float.pi / 4, accuracy: 0.0001)
        XCTAssertEqual(limits.clamped(Float.pi / 8), Float.pi / 8, accuracy: 0.0001)
        XCTAssertEqual(limits.clamped(Float.pi / 2), Float.pi / 4, accuracy: 0.0001)
        XCTAssertEqual(limits.clamped(Float.pi * 1.75), -Float.pi / 4, accuracy: 0.0001)
    }

    func testBearingLimitsClampMaximumAbsoluteBearingIntoSupportedRange() {
        let negativeLimits = ImmersiveMapCameraBearingLimits(maximumAbsoluteBearing: -1)
        let oversizedLimits = ImmersiveMapCameraBearingLimits(maximumAbsoluteBearing: Float.pi * 2)

        XCTAssertEqual(negativeLimits.maximumAbsoluteBearing, 0, accuracy: 0.0001)
        XCTAssertEqual(negativeLimits.minimum, 0, accuracy: 0.0001)
        XCTAssertEqual(negativeLimits.maximum, 0, accuracy: 0.0001)
        XCTAssertEqual(oversizedLimits.maximumAbsoluteBearing, Float.pi, accuracy: 0.0001)
        XCTAssertEqual(oversizedLimits.minimum, -Float.pi, accuracy: 0.0001)
        XCTAssertEqual(oversizedLimits.maximum, Float.pi, accuracy: 0.0001)
    }

    func testSnapshotClampsPositionPitchAndBearing() {
        let position = ImmersiveMapCameraPosition(latitudeDegrees: 55,
                                                  longitudeDegrees: 37,
                                                  zoom: 3,
                                                  bearing: Float.pi / 2,
                                                  pitch: Float.pi / 3)
        let snapshot = ImmersiveMapCameraSnapshot(position: position,
                                                  bearingLimits: ImmersiveMapCameraBearingLimits(maximumAbsoluteBearing: Float.pi / 12),
                                                  pitchLimits: ImmersiveMapCameraAngleLimits(minimum: 0,
                                                                                             maximum: Float.pi / 6),
                                                  isSphericalSurfaceActive: true)

        let clamped = snapshot.clampedPosition(position)

        XCTAssertEqual(clamped.latitudeDegrees, 55, accuracy: 0.0001)
        XCTAssertEqual(clamped.longitudeDegrees, 37, accuracy: 0.0001)
        XCTAssertEqual(clamped.zoom, 3, accuracy: 0.0001)
        XCTAssertEqual(clamped.bearing, Float.pi / 12, accuracy: 0.0001)
        XCTAssertEqual(clamped.pitch, Float.pi / 6, accuracy: 0.0001)
    }

    func testSnapshotNormalizesBearingBeforeClamping() {
        let position = ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                  longitudeDegrees: 0,
                                                  zoom: 1,
                                                  bearing: Float.pi * 1.75,
                                                  pitch: 0)
        let snapshot = ImmersiveMapCameraSnapshot(position: position,
                                                  bearingLimits: ImmersiveMapCameraBearingLimits(maximumAbsoluteBearing: Float.pi),
                                                  pitchLimits: ImmersiveMapCameraAngleLimits(minimum: 0,
                                                                                             maximum: Float.pi / 4),
                                                  isSphericalSurfaceActive: false)

        let clamped = snapshot.clampedPosition(position)

        XCTAssertEqual(clamped.bearing, -Float.pi / 4, accuracy: 0.0001)
    }
}
