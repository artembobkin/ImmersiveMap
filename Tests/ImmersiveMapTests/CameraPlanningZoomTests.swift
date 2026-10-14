// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The planning zoom (`CameraStateController.planningZoom`): the zoom the
/// tiles, the rings and the relief's thresholds are planned by. It moves
/// with a zoom set on purpose and with nothing else, and then takes the
/// camera's zoom: over the terrain the camera's own zoom follows the
/// ground under the point it looks at, the planning zoom stands through
/// every drag, and the next zoom brings the two together.
final class CameraPlanningZoomTests: XCTestCase {
    private let centre = SIMD2<Double>(0.3, 0.4)

    private func makeController(zoom: Double = 12, maximumZoom: Double = 22) -> CameraStateController {
        var settings = ImmersiveMapSettings.default.camera
        settings.maximumZoom = maximumZoom
        let controller = CameraStateController(settings: settings)
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: centre, zoom: zoom, bearing: 0, pitch: 0.6))
        return controller
    }

    private func slope(_ controller: CameraStateController) -> CameraTerrainFollow {
        // Level at the start, a slope rising to the north: a drag north
        // moves the point looked at uphill, and the camera's zoom with it.
        let origin = centre
        return CameraTerrainFollow(terrainMetres: { point in Float(max(0, (point.y - origin.y) * -4_000_000)) },
                                   clearanceMetres: 0,
                                   globeRadiusScale: ImmersiveMapSettings.default.presentation.globeRadiusScale)
    }

    func testAZoomSetOutrightSetsBothZooms() {
        let controller = makeController(zoom: 12)
        XCTAssertEqual(controller.planningZoom, 12)
        controller.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 46, longitudeDegrees: 7, zoom: 9, bearing: 0, pitch: 0))
        XCTAssertEqual(controller.planningZoom, 9)
        XCTAssertEqual(controller.zoom, 9)
        controller.setZoom(zoom: 14.5)
        XCTAssertEqual(controller.planningZoom, 14.5)
        XCTAssertEqual(controller.zoom, 14.5)
    }

    func testAZoomGestureBringsThePlanningZoomToTheCameras() {
        let controller = makeController(zoom: 12)
        controller.zoom(delta: 1.25)
        XCTAssertEqual(controller.planningZoom, 13.25, accuracy: 1e-9)
        XCTAssertEqual(controller.zoom, 13.25, accuracy: 1e-9)
        controller.zoom(delta: 20)
        XCTAssertEqual(controller.planningZoom, 22, "Clamped to the zoom range like the camera's")
        XCTAssertEqual(controller.zoom, 22)
    }

    /// A climb parts the two zooms, and the next zoom gesture closes the
    /// gap at the camera's zoom. Not by the gesture's delta: a zoom back
    /// by what the climb added would then leave the map planned levels
    /// below what the camera sees.
    func testADragOverTheTerrainMovesTheCameraZoomAndNotThePlanningZoom() {
        let controller = makeController(zoom: 12)
        controller.terrainFollow = slope(controller)
        controller.pan(deltaX: 0, deltaY: 1, transition: 1)
        controller.pan(deltaX: 0, deltaY: 1, transition: 1)
        controller.endPan()
        let climbed = controller.zoom
        XCTAssertNotEqual(climbed, 12, "Uphill the camera's zoom follows the ground")
        XCTAssertEqual(controller.planningZoom, 12, "The planning zoom stands")
        controller.zoom(delta: 12 - climbed)
        XCTAssertEqual(controller.zoom, 12, accuracy: 1e-6, "Zoomed back by the climb")
        XCTAssertEqual(controller.planningZoom, controller.zoom, accuracy: 1e-9, "And the map is planned by what the camera sees")
    }

    func testTheFrameCarriesThePlanningZoom() {
        let resolver = FrameCameraStateResolver(settings: .default)
        resolver.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 46, longitudeDegrees: 7, zoom: 11, bearing: 0, pitch: 0))
        XCTAssertEqual(resolver.planningZoom, 11)
        let state = resolver.makeFrameState(drawSize: CGSize(width: 400, height: 300), diagnostics: FrameDiagnostics(frameIndex: 1, frameDeltaTime: 1 / 60))
        XCTAssertEqual(state?.planningZoom, 11)
    }
}
