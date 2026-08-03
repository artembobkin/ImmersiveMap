// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class SceneModelMetersScaleTests: XCTestCase {
    func testUnitsPerMeterScalesLinearlyWithRenderMapSize() {
        let base = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: 0.5,
                                                             renderMapSize: 1000)
        let doubled = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: 0.5,
                                                                renderMapSize: 2000)
        XCTAssertEqual(doubled / base, 2, accuracy: 1e-12)
    }

    func testUnitsPerMeterFollowsMercatorLatitudeInflation() {
        let equator = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: 0,
                                                                renderMapSize: 1000)
        let sixty = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: .pi / 3,
                                                              renderMapSize: 1000)
        // Mercator inflates ground distances by 1/cos(60°) == 2.
        XCTAssertEqual(sixty / equator, 2, accuracy: 1e-9)

        XCTAssertEqual(equator, 1000 / ImmersiveMapProjection.earthCircumferenceMeters,
                       accuracy: 1e-15)
    }

    func testUnitsPerMeterClampsBeyondMercatorLatitudeLimit() {
        let atLimit = ImmersiveMapProjection.worldUnitsPerMeter(
            latitudeRadians: ImmersiveMapProjection.maxMercatorLatitude,
            renderMapSize: 1000)
        let beyondLimit = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: 89.0 * .pi / 180.0,
                                                                    renderMapSize: 1000)
        XCTAssertEqual(beyondLimit, atLimit, accuracy: 1e-12)
    }

    /// Render units re-normalize per integer zoom: the map size doubles, so a
    /// meter-sized model doubles with it and stays glued to the map geometry.
    func testRenderMapSizeDoublesAcrossIntegerZoom() {
        let settings = ImmersiveMapSettings.default.presentation
        let center = ImmersiveMapProjection.worldMercator(latitude: 0.6, longitude: 0.4)
        let atFive = PresentationStateResolver.resolve(
            cameraState: ImmersiveMapCameraState(centerWorldMercator: center, zoom: 5.0, bearing: 0, pitch: 0),
            settings: settings)
        let atSix = PresentationStateResolver.resolve(
            cameraState: ImmersiveMapCameraState(centerWorldMercator: center, zoom: 6.0, bearing: 0, pitch: 0),
            settings: settings)

        XCTAssertEqual(atSix.flatRenderState.renderMapSize / atFive.flatRenderState.renderMapSize,
                       2,
                       accuracy: 1e-9)
    }
}
