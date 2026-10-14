// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The camera over a terrain looks at a point on it: the zoom stops where
/// the eye would come nearer than the clearance to that point or to the
/// terrain under the eye, and a pan keeps the eye's height by the zoom.
final class CameraTerrainFollowTests: XCTestCase {
    private let centre = SIMD2<Double>(0.3, 0.4)
    private let globeRadiusScale = ImmersiveMapSettings.default.presentation.globeRadiusScale

    private func follow(terrainMetres: @escaping (SIMD2<Double>) -> Float?, clearance: Double = 30) -> CameraTerrainFollow {
        CameraTerrainFollow(terrainMetres: terrainMetres, clearanceMetres: clearance, globeRadiusScale: globeRadiusScale)
    }

    func testTheEyeComesDownAsTheZoomGrows() {
        let follow = follow(terrainMetres: { _ in 0 })
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centre.y)
        var previous = Double.infinity
        for step in 0 ... 60 {
            let height = follow.eyeHeightMetres(zoom: Double(step) * 0.25, pitch: 0, latitude: latitude)
            XCTAssertLessThan(height, previous, "The height falls through zoom \(Double(step) * 0.25)")
            previous = height
        }
    }

    /// The point looked at lies on the plateau, level with the ground
    /// under the eye: nothing holds the eye off it, and the zoom goes to
    /// its own limit, however high the plateau.
    func testAPlateauDoesNotStopTheZoom() {
        let follow = follow(terrainMetres: { _ in 1000 })
        XCTAssertEqual(follow.clearZoom(below: 22, center: centre, pitch: 0, bearing: 0, range: 0 ... 22), 22)
        XCTAssertEqual(follow.clearZoom(below: 22, center: centre, pitch: 1, bearing: 2, range: 0 ... 22), 22)
        XCTAssertTrue(follow.isClear(center: centre, zoom: 22, pitch: 1, bearing: 2))
    }

    /// The margin grows with the ridge's rise over the point: none for a
    /// ridge level with it, the whole clearance a clearance up, smoothly
    /// between, and none at all without a clearance, the default: the
    /// eye then stops at the ridge's own surface.
    func testTheMarginGrowsWithTheRidge() {
        XCTAssertEqual(ImmersiveMapSettings.TileSettings.GroundReliefSettings().cameraClearanceMetres, 0)
        XCTAssertEqual(CameraTerrainFollow.clearanceMargin(rise: 500, clearance: 0), 0, "Right up to the ridge")
        XCTAssertEqual(CameraTerrainFollow.clearanceMargin(rise: 0, clearance: 30), 0)
        XCTAssertEqual(CameraTerrainFollow.clearanceMargin(rise: -100, clearance: 30), 0)
        XCTAssertEqual(CameraTerrainFollow.clearanceMargin(rise: 30, clearance: 30), 30)
        XCTAssertEqual(CameraTerrainFollow.clearanceMargin(rise: 500, clearance: 30), 30)
        XCTAssertEqual(CameraTerrainFollow.clearanceMargin(rise: 15, clearance: 30), 15, accuracy: 1e-9)
        var previous = 0.0
        for step in 1 ... 30 {
            let margin = CameraTerrainFollow.clearanceMargin(rise: Double(step), clearance: 30)
            XCTAssertGreaterThanOrEqual(margin, previous)
            previous = margin
        }
    }

    /// At a pitch the eye stands behind the point it looks at: a hill
    /// there, and nowhere else, is what stops the zoom.
    func testTheTerrainUnderTheEyeIsWhatCounts() {
        let follow = follow(terrainMetres: { [centre] point in
            // A hill right behind the centre to the south, where a camera
            // looking north stands at any zoom.
            point.y > centre.y + 1e-9 ? 500 : 0
        })
        let flatLimit = follow.clearZoom(below: 22, center: centre, pitch: 0, bearing: 0, range: 0 ... 22)
        let pitchedLimit = follow.clearZoom(below: 22, center: centre, pitch: Float.pi / 3, bearing: 0, range: 0 ... 22)
        XCTAssertLessThan(pitchedLimit, flatLimit - 1, "The hill under the pitched eye stops it far sooner")
    }

    func testUnknownTerrainStopsNothing() {
        let follow = follow(terrainMetres: { _ in nil })
        XCTAssertEqual(follow.clearZoom(below: 22, center: centre, pitch: 0, bearing: 0, range: 0 ... 22), 22)
    }

    /// A pan onto higher ground keeps the eye's altitude: the point looked
    /// at rises with the terrain and the zoom shortens the arm to it, so
    /// the eye's altitude is what it was, and the eye's place over the
    /// map moved by the pan, no more and no less, the point having come
    /// nearer along the view by the shorter arm.
    func testAPanOntoHigherGroundKeepsTheEyesAltitude() {
        var settings = ImmersiveMapSettings.default
        settings.camera.maximumZoom = 22
        let controller = CameraStateController(settings: settings.camera)
        let pitch = Float.pi / 4
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: centre, zoom: 14, bearing: 0, pitch: pitch))
        // A ramp rising north at two metres a metre, steeper than the
        // ray's one, from 30 m short of where the pan would put the point:
        // the ray meets its face, and the point stops on it.
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centre.y)
        let metresPerWorld = ImmersiveMapProjection.earthCircumferenceMeters * cos(latitude)
        let rampY = centre.y - 1e-5 + 30 / metresPerWorld
        let terrain: (SIMD2<Double>) -> Float? = { point in Float(max(0, (rampY - point.y) * metresPerWorld * 2)) }
        let follow = follow(terrainMetres: terrain)
        controller.terrainFollow = follow
        let altitudeBefore = follow.eyeHeightMetres(zoom: 14, pitch: pitch, latitude: latitude)
        let eyeBefore = follow.eyeGround(center: centre, zoom: 14, pitch: pitch, bearing: 0, latitude: latitude)

        let target = centre + SIMD2<Double>(0, -1e-5)
        let followed = controller.followTerrain(from: centre, to: target, follow: follow)
        XCTAssertGreaterThan(followed.zoom, 14, "The arm shortens: a deeper zoom")
        let heightAfter = Double(terrain(followed.center) ?? 0)
        XCTAssertGreaterThan(heightAfter, 1, "The point is on the ramp")
        let altitudeAfter = heightAfter + follow.eyeHeightMetres(zoom: followed.zoom, pitch: pitch, latitude: latitude)
        XCTAssertEqual(altitudeAfter, altitudeBefore, accuracy: 0.5)
        let eyeAfter = follow.eyeGround(center: followed.center, zoom: followed.zoom, pitch: pitch, bearing: 0, latitude: latitude)
        XCTAssertEqual((eyeAfter.y - eyeBefore.y) * metresPerWorld, (target.y - centre.y) * metresPerWorld, accuracy: 0.2,
                       "The eye moved over the map by the pan")
    }

    /// Onto a mountain higher than the eye, the eye rises: the point looked
    /// at keeps the clearance under the eye.
    func testAPanOntoAMountainLiftsTheEyeToTheClearance() {
        var settings = ImmersiveMapSettings.default
        settings.camera.maximumZoom = 22
        let controller = CameraStateController(settings: settings.camera)
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: centre, zoom: 16, bearing: 0, pitch: 0))
        let follow = follow(terrainMetres: { [centre] point in point.y < centre.y - 1e-9 ? 3000 : 0 })
        let followed = controller.followTerrain(from: centre, to: centre + SIMD2<Double>(0, -1e-5), follow: follow)
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centre.y)
        XCTAssertEqual(follow.eyeHeightMetres(zoom: followed.zoom, pitch: 0, latitude: latitude), 30, accuracy: 0.1)
    }

    /// A zoom out that crosses onto a coarser terrain map, which reads
    /// the ground under the point higher than the finer one did, keeps
    /// the eye where the zoom put it: the point moves up the ray to where
    /// it meets the higher ground, the arm shortens, and the eye's
    /// altitude is the old ground plus the new zoom's height, no jump.
    func testAZoomOntoAnotherTerrainMapKeepsTheEye() {
        var settings = ImmersiveMapSettings.default
        settings.camera.maximumZoom = 22
        let controller = CameraStateController(settings: settings.camera)
        let pitch = Float.pi / 4
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: centre, zoom: 12.5, bearing: 0, pitch: pitch))
        // The finer map, read at zoom 12 and deeper, has the ground at
        // 1000 m. The coarser one, read below 12, has it at 1300 m.
        let terrain: (SIMD2<Double>) -> Float? = { [unowned controller] _ in controller.zoom >= 12 ? 1000 : 1300 }
        let follow = follow(terrainMetres: terrain)
        controller.terrainFollow = follow
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centre.y)
        let expectedAltitude = 1000 + follow.eyeHeightMetres(zoom: 11.5, pitch: pitch, latitude: latitude)
        let expectedEye = follow.eyeGround(center: centre, zoom: 11.5, pitch: pitch, bearing: 0, latitude: latitude)

        controller.zoom(delta: -1)
        XCTAssertGreaterThan(controller.zoom, 11.5, "The point met higher ground sooner: a shorter arm")
        let altitude = 1300 + follow.eyeHeightMetres(zoom: controller.zoom, pitch: pitch, latitude: latitude)
        XCTAssertEqual(altitude, expectedAltitude, accuracy: 0.5, "The eye is where the zoom put it")
        let eye = follow.eyeGround(center: controller.cameraState.centerWorldMercator, zoom: controller.zoom, pitch: pitch, bearing: 0, latitude: latitude)
        let metresPerWorld = ImmersiveMapProjection.earthCircumferenceMeters * cos(latitude)
        XCTAssertEqual((eye.y - expectedEye.y) * metresPerWorld, 0, accuracy: 0.5, "And over the same ground")
        XCTAssertNotEqual(controller.cameraState.centerWorldMercator, centre, "The point moved along the ray")
    }

    /// A pan that brings a ridge under the eye, higher than the eye is,
    /// backs the eye off along its view ray by the zoom, to where it keeps
    /// the clearance over the ridge: the frame never lifts the camera off
    /// its pose.
    func testAPanUnderARidgeBacksTheEyeOffByTheZoom() {
        var settings = ImmersiveMapSettings.default
        settings.camera.maximumZoom = 22
        let controller = CameraStateController(settings: settings.camera)
        let pitch = Float.pi / 4
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: centre, zoom: 16, bearing: 0, pitch: pitch))
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centre.y)
        let eyeHeight = follow(terrainMetres: { _ in 0 }).eyeHeightMetres(zoom: 16, pitch: pitch, latitude: latitude)
        // Level ground at the point and north of it, a plateau twice the
        // eye's height just south of it: under the eye of a pitched
        // camera looking north, which stands south of the point.
        let terrain: (SIMD2<Double>) -> Float? = { [centre] point in point.y > centre.y + 1e-7 ? Float(eyeHeight * 2) : 0 }
        let follow = follow(terrainMetres: terrain, clearance: 30)
        controller.terrainFollow = follow
        controller.pan(deltaX: 0, deltaY: 1, transition: 1)
        XCTAssertLessThan(controller.zoom, 16, "The arm lengthened: the eye backed off")
        XCTAssertTrue(follow.isClear(center: controller.cameraState.centerWorldMercator,
                                     zoom: controller.zoom, pitch: pitch, bearing: 0),
                      "And it is clear of the ridge")
    }

    /// The anchor compensation of a zoom slides the point over the
    /// ground: onto a ramp, the eye keeps the altitude the zoom gave it
    /// and the arm shortens, as for a pan. Without a terrain the center
    /// is simply set.
    func testAnAnchoredZoomsSlideOntoARampKeepsTheEye() {
        var settings = ImmersiveMapSettings.default
        settings.camera.maximumZoom = 22
        let controller = CameraStateController(settings: settings.camera)
        let pitch = Float.pi / 4
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: centre, zoom: 14, bearing: 0, pitch: pitch))
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centre.y)
        let metresPerWorld = ImmersiveMapProjection.earthCircumferenceMeters * cos(latitude)
        let rampY = centre.y - 1e-5 + 30 / metresPerWorld
        let terrain: (SIMD2<Double>) -> Float? = { point in Float(max(0, (rampY - point.y) * metresPerWorld * 2)) }
        let follow = follow(terrainMetres: terrain)
        controller.terrainFollow = follow
        let altitudeBefore = follow.eyeHeightMetres(zoom: 14, pitch: pitch, latitude: latitude)

        controller.setCenterWorldMercatorOverTerrain(centre + SIMD2<Double>(0, -1e-5))
        XCTAssertGreaterThan(controller.zoom, 14, "The arm shortened onto the ramp")
        let height = Double(terrain(controller.cameraState.centerWorldMercator) ?? 0)
        XCTAssertGreaterThan(height, 1, "The point is on the ramp")
        XCTAssertEqual(height + follow.eyeHeightMetres(zoom: controller.zoom, pitch: pitch, latitude: latitude), altitudeBefore,
                       accuracy: 0.5, "The eye kept its altitude")

        controller.terrainFollow = nil
        controller.setCenterWorldMercatorOverTerrain(centre)
        XCTAssertEqual(controller.cameraState.centerWorldMercator, centre, "Plainly set without a terrain")
    }

    /// A zoom that stays on one terrain map moves nothing but the zoom.
    func testAZoomOnOneTerrainMapKeepsThePoint() {
        var settings = ImmersiveMapSettings.default
        settings.camera.maximumZoom = 22
        let controller = CameraStateController(settings: settings.camera)
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: centre, zoom: 12.5, bearing: 0, pitch: .pi / 4))
        controller.terrainFollow = follow(terrainMetres: { _ in 1000 })
        controller.zoom(delta: -1)
        XCTAssertEqual(controller.zoom, 11.5, accuracy: 1e-9)
        XCTAssertEqual(controller.cameraState.centerWorldMercator, centre)
    }

    func testTheControllerClampsAZoomInToTheLimitAndLetsAZoomOutThrough() {
        var settings = ImmersiveMapSettings.default
        settings.camera.maximumZoom = 22
        let controller = CameraStateController(settings: settings.camera)
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: centre, zoom: 10, bearing: 0, pitch: 0))
        let follow = follow(terrainMetres: { _ in 1000 })
        controller.terrainFollow = follow
        let limit = follow.clearZoom(below: 22, center: centre, pitch: 0, bearing: 0, range: 0 ... 22)

        controller.zoom(delta: 12)
        XCTAssertEqual(controller.zoom, limit, accuracy: 1e-6, "The zoom in stops at the terrain")
        controller.zoom(delta: -3)
        XCTAssertEqual(controller.zoom, limit - 3, accuracy: 1e-6, "A zoom out is free")
    }
}

