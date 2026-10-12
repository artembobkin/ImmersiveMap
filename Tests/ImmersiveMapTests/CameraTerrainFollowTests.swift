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
        XCTAssertEqual(follow.maximumZoom(center: centre, pitch: 0, bearing: 0, range: 0 ... 22), 22)
        XCTAssertEqual(follow.maximumZoom(center: centre, pitch: 1, bearing: 2, range: 0 ... 22), 22)
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
        let flatLimit = follow.maximumZoom(center: centre, pitch: 0, bearing: 0, range: 0 ... 22)
        let pitchedLimit = follow.maximumZoom(center: centre, pitch: Float.pi / 3, bearing: 0, range: 0 ... 22)
        XCTAssertLessThan(pitchedLimit, flatLimit - 1, "The hill under the pitched eye stops it far sooner")
    }

    func testUnknownTerrainStopsNothing() {
        let follow = follow(terrainMetres: { _ in nil })
        XCTAssertEqual(follow.maximumZoom(center: centre, pitch: 0, bearing: 0, range: 0 ... 22), 22)
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

    func testTheControllerClampsAZoomInToTheLimitAndLetsAZoomOutThrough() {
        var settings = ImmersiveMapSettings.default
        settings.camera.maximumZoom = 22
        let controller = CameraStateController(settings: settings.camera)
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: centre, zoom: 10, bearing: 0, pitch: 0))
        let follow = follow(terrainMetres: { _ in 1000 })
        controller.terrainFollow = follow
        let limit = follow.maximumZoom(center: centre, pitch: 0, bearing: 0, range: 0 ... 22)

        controller.zoom(delta: 12)
        XCTAssertEqual(controller.zoom, limit, accuracy: 1e-6, "The zoom in stops at the terrain")
        controller.zoom(delta: -3)
        XCTAssertEqual(controller.zoom, limit - 3, accuracy: 1e-6, "A zoom out is free")
    }
}
