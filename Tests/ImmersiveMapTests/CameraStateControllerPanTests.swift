// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Panning the globe must preserve angular speed at any latitude: the mercator
/// delta is compensated by `cos(latitude)`. Vertical compensation is full at
/// any zoom; horizontal ramps in by zoom (at low zooms the whole globe is
/// visible, and a compensated horizontal swipe would spin it like a top).
/// On the flat map (transition = 1) the delta does not depend on latitude.
final class CameraStateControllerPanTests: XCTestCase {
    private func panDelta(latitudeDegrees: Double,
                          zoom: Double,
                          transition: Float) -> SIMD2<Double> {
        let controller = CameraStateController(settings: ImmersiveMapSettings.default.camera)
        controller.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitudeDegrees,
                                                                longitudeDegrees: 0,
                                                                zoom: zoom,
                                                                bearing: 0,
                                                                pitch: 0))
        let before = controller.cameraState.centerWorldMercator
        controller.pan(deltaX: 10, deltaY: 10, transition: transition)
        return controller.cameraState.centerWorldMercator - before
    }

    func testGlobePanMovesTheSameMercatorAtLocalZoom() {
        let equator = panDelta(latitudeDegrees: 0, zoom: 5.5, transition: 0)
        let lat60 = panDelta(latitudeDegrees: 60, zoom: 5.5, transition: 0)

        // At local zoom the camera has moved in by cos(60°) = 0.5
        // (GlobeCameraProximity), so the screen shows the Mercator scale and
        // a swipe moves the same Mercator delta as at the equator.
        XCTAssertEqual(lat60.x / equator.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(lat60.y / equator.y, 1.0, accuracy: 1e-6)
    }

    func testGlobePanCompensatesLatitudeBelowTheProximityActivation() {
        let equator = panDelta(latitudeDegrees: 0, zoom: 2, transition: 0)
        let lat60 = panDelta(latitudeDegrees: 60, zoom: 2, transition: 0)

        // Below the activation zoom the camera stays at the zoom's distance:
        // cos(60°) = 0.5, so the vertical Mercator delta is twice the
        // equatorial one (the horizontal one ramps in separately).
        XCTAssertEqual(lat60.y / equator.y, 2.0, accuracy: 1e-6)
    }

    func testGlobePanSkipsHorizontalCompensationAtGlobeOverviewZoom() {
        let equator = panDelta(latitudeDegrees: 0, zoom: 1.5, transition: 0)
        let lat60 = panDelta(latitudeDegrees: 60, zoom: 1.5, transition: 0)

        // Overview zoom: the vertical is compensated, the horizontal spins the globe
        // at the same angular speed as at the equator.
        XCTAssertEqual(lat60.x / equator.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(lat60.y / equator.y, 2.0, accuracy: 1e-6)
    }

    /// The ground under the finger follows the finger: with the camera
    /// moved in by the surface scale, the angular pan per screen point
    /// shrinks by that same scale, exactly as the ground on screen did.
    func testGlobePanAngularSpeedFollowsTheCameraProximity() {
        let equatorLatitude = angularLatitudeDelta(latitudeDegrees: 0)
        let polarLatitude = angularLatitudeDelta(latitudeDegrees: 82.8)
        let proximity = GlobeCameraProximity.distanceFactor(latitude: 82.8 * .pi / 180, transition: 0, zoom: 4)

        XCTAssertEqual(polarLatitude / equatorLatitude, proximity, accuracy: 0.05 * proximity)
    }

    func testFlatPanIgnoresLatitude() {
        let equator = panDelta(latitudeDegrees: 0, zoom: 8, transition: 1)
        let lat60 = panDelta(latitudeDegrees: 60, zoom: 8, transition: 1)

        XCTAssertEqual(lat60.x, equator.x, accuracy: 1e-12)
        XCTAssertEqual(lat60.y, equator.y, accuracy: 1e-12)
    }

    func testGlobePanStaysFiniteNearMercatorLatitudeLimit() {
        let nearLimit = panDelta(latitudeDegrees: 85, zoom: 5.5, transition: 0)

        XCTAssertTrue(nearLimit.x.isFinite)
        XCTAssertTrue(nearLimit.y.isFinite)
    }

    /// Angular latitude delta from a small vertical pan on the globe.
    private func angularLatitudeDelta(latitudeDegrees: Double) -> Double {
        let controller = CameraStateController(settings: ImmersiveMapSettings.default.camera)
        controller.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitudeDegrees,
                                                                longitudeDegrees: 0,
                                                                zoom: 4,
                                                                bearing: 0,
                                                                pitch: 0))
        let latitudeBefore = controller.getLatLonRad().latRad
        controller.pan(deltaX: 0, deltaY: 1, transition: 0)
        return abs(controller.getLatLonRad().latRad - latitudeBefore)
    }
}
