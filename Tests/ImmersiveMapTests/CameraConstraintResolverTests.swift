// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class CameraConstraintResolverTests: XCTestCase {
    private let settings = ImmersiveMapSettings.default.camera

    func testFlatPitchLimitIsAlwaysSeventyFiveDegrees() {
        XCTAssertEqual(flatMaximumPitch(at: 0), degrees(75), accuracy: 0.0001)
        XCTAssertEqual(flatMaximumPitch(at: 12), degrees(75), accuracy: 0.0001)
        XCTAssertEqual(flatMaximumPitch(at: 20), degrees(75), accuracy: 0.0001)
    }

    func testGlobePitchLimitUnlocksLinearlyUntilZoomThree() {
        XCTAssertEqual(globeMaximumPitch(at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(globeMaximumPitch(at: 1.5), degrees(37.5), accuracy: 0.0001)
        XCTAssertEqual(globeMaximumPitch(at: 3), degrees(75), accuracy: 0.0001)
        XCTAssertEqual(globeMaximumPitch(at: 20), degrees(75), accuracy: 0.0001)
    }

    private func flatMaximumPitch(at zoom: Double) -> Float {
        maximumPitch(at: zoom, renderSurfaceMode: .flat)
    }

    private func globeMaximumPitch(at zoom: Double) -> Float {
        maximumPitch(at: zoom, renderSurfaceMode: .spherical)
    }

    private func maximumPitch(at zoom: Double, renderSurfaceMode: ViewMode) -> Float {
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                  zoom: zoom,
                                                  bearing: 0,
                                                  pitch: 0)
        return CameraConstraintResolver.resolve(cameraState: cameraState,
                                                cameraSettings: settings,
                                                renderSurfaceMode: renderSurfaceMode)
            .pitch
            .maximumPitch
    }

    private func degrees(_ value: Float) -> Float {
        value * .pi / 180
    }
}
