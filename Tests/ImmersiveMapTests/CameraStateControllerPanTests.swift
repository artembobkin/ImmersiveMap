// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Пан на глобусе должен сохранять угловую скорость на любой широте: меркаторная
/// дельта компенсируется на `cos(широты)`. Вертикальная компенсация полная на
/// любом зуме; горизонтальная включается по зуму (на низких зумах виден весь
/// глобус, и компенсированный горизонтальный свайп крутил бы его волчком).
/// На плоской карте (transition = 1) дельта от широты не зависит.
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

    func testGlobePanCompensatesLatitudeAtLocalZoom() {
        let equator = panDelta(latitudeDegrees: 0, zoom: 5.5, transition: 0)
        let lat60 = panDelta(latitudeDegrees: 60, zoom: 5.5, transition: 0)

        // cos(60°) = 0.5: на широте 60° меркаторная дельта вдвое больше экваторной.
        XCTAssertEqual(lat60.x / equator.x, 2.0, accuracy: 1e-6)
        XCTAssertEqual(lat60.y / equator.y, 2.0, accuracy: 1e-6)
    }

    func testGlobePanSkipsHorizontalCompensationAtGlobeOverviewZoom() {
        let equator = panDelta(latitudeDegrees: 0, zoom: 1.5, transition: 0)
        let lat60 = panDelta(latitudeDegrees: 60, zoom: 1.5, transition: 0)

        // Обзорный зум: вертикаль компенсируется, горизонталь крутит глобус
        // с той же угловой скоростью, что и на экваторе.
        XCTAssertEqual(lat60.x / equator.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(lat60.y / equator.y, 2.0, accuracy: 1e-6)
    }

    func testGlobePanKeepsAngularLatitudeSpeed() {
        let equatorLatitude = angularLatitudeDelta(latitudeDegrees: 0)
        let polarLatitude = angularLatitudeDelta(latitudeDegrees: 82.8)

        XCTAssertEqual(polarLatitude / equatorLatitude, 1.0, accuracy: 0.05)
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

    /// Угловая дельта широты от маленького вертикального пана на глобусе.
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
