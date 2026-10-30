// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
@testable import ImmersiveMapDebug
import simd
import XCTest

final class DebugOverlaySunDialTests: XCTestCase {
    private let elevationRange = DebugOverlayShadowSettingsPlanner.elevationRange

    /// The camera turned by a bearing looks the opposite turn round the
    /// compass: a bearing of 90° east of north is a view to the west.
    func testTheViewIsTheBearingsOppositeTurn() {
        XCTAssertEqual(DebugOverlaySunDial.viewAzimuthDegrees(bearingRadians: 0), 0)
        XCTAssertEqual(DebugOverlaySunDial.viewAzimuthDegrees(bearingRadians: .pi / 2), 270, accuracy: 1e-9)
        XCTAssertEqual(DebugOverlaySunDial.viewAzimuthDegrees(bearingRadians: -.pi / 2), 90, accuracy: 1e-9)
    }

    /// Up the disc is the view: a sun in the direction the camera looks
    /// stands at the top, one behind it at the bottom, the zenith at the
    /// centre and the horizon on the rim.
    func testTheDiscTurnsWithTheView() {
        let ahead = DebugOverlaySunDial.point(azimuthDegrees: 120, elevationDegrees: 0, viewAzimuthDegrees: 120)
        XCTAssertEqual(ahead.x, 0, accuracy: 1e-9)
        XCTAssertEqual(ahead.y, 1, accuracy: 1e-9)
        let right = DebugOverlaySunDial.point(azimuthDegrees: 210, elevationDegrees: 45, viewAzimuthDegrees: 120)
        XCTAssertEqual(right.x, 0.5, accuracy: 1e-9, "A quarter turn clockwise of the view, halfway up the sky")
        XCTAssertEqual(right.y, 0, accuracy: 1e-9)
        XCTAssertEqual(simd_length(DebugOverlaySunDial.point(azimuthDegrees: 0, elevationDegrees: 90, viewAzimuthDegrees: 0)),
                       0, accuracy: 1e-9)
    }

    /// A drag reads back the sun it shows, and keeps the elevation to the
    /// panel's range.
    func testADragReadsBackTheSunItShows() {
        let point = DebugOverlaySunDial.point(azimuthDegrees: 195, elevationDegrees: 54, viewAzimuthDegrees: 300)
        let angles = DebugOverlaySunDial.angles(point: point, viewAzimuthDegrees: 300, azimuthDegrees: 0,
                                                elevationRange: elevationRange)
        XCTAssertEqual(angles.azimuthDegrees, 195, accuracy: 1e-9)
        XCTAssertEqual(angles.elevationDegrees, 54, accuracy: 1e-9)
        let pastTheRim = DebugOverlaySunDial.angles(point: SIMD2(0, 3), viewAzimuthDegrees: 0, azimuthDegrees: 0,
                                                    elevationRange: elevationRange)
        XCTAssertEqual(pastTheRim.elevationDegrees, elevationRange.lowerBound)
        let atTheCentre = DebugOverlaySunDial.angles(point: .zero, viewAzimuthDegrees: 0, azimuthDegrees: 77,
                                                     elevationRange: elevationRange)
        XCTAssertEqual(atTheCentre.azimuthDegrees, 77, "No direction at the zenith: the azimuth is kept")
        XCTAssertEqual(atTheCentre.elevationDegrees, elevationRange.upperBound)
    }

    /// From the side, the angle over the horizon either side of the
    /// ground's point.
    func testTheSideViewReadsTheElevation() {
        XCTAssertEqual(DebugOverlaySunDial.elevation(sidePoint: SIMD2(1, 1), elevationRange: elevationRange), 45, accuracy: 1e-9)
        XCTAssertEqual(DebugOverlaySunDial.elevation(sidePoint: SIMD2(-1, 1), elevationRange: elevationRange), 45, accuracy: 1e-9)
        XCTAssertEqual(DebugOverlaySunDial.elevation(sidePoint: SIMD2(1, -1), elevationRange: elevationRange),
                       elevationRange.lowerBound)
    }
}
