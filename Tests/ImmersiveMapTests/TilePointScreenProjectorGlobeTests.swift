// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// A tile point on the globe is projected by the globe point every CPU
/// projection shares (GeoScreenProjectionMath), so a name stands where a pin
/// and a marker of the same place stand, which is where the ground is drawn.
/// Regression: the tile projector blended the sphere and the plane by a plain
/// lerp of its own, so through the morph its points left the unrolling ground,
/// most of all far from the view centre under a tilted camera.
final class TilePointScreenProjectorGlobeTests: XCTestCase {
    private let drawSize = CGSize(width: 1800, height: 900)
    private let presentationSettings = ImmersiveMapSettings.default.presentation
    private let tileZoom = 6

    private let places: [GeoCoordinate] = [
        GeoCoordinate(latitude: 25.1972, longitude: 55.2744),
        GeoCoordinate(latitude: 55.7558, longitude: 37.6173),
        GeoCoordinate(latitude: 41.0082, longitude: 28.9784),
        GeoCoordinate(latitude: 28.6139, longitude: 77.2090),
        GeoCoordinate(latitude: 9.0320, longitude: 38.7469),
        GeoCoordinate(latitude: 35.6595, longitude: 139.7005),
        GeoCoordinate(latitude: -33.8688, longitude: 151.2093)
    ]

    func testATilePointStandsWhereTheSharedProjectorPutsThePlace() throws {
        var comparedMidMorph = 0
        for morphShare in [-0.5, 0.2, 0.45, 0.7, 0.9] {
            for pitch: Float in [0, 0.7, 1.28] {
                // Past the globe's projection the flat path projects, which
                // is not this test's.
                guard let constants = try makeConstants(morphShare: morphShare, pitch: pitch) else {
                    continue
                }
                let transition = constants.globe.transition
                for place in places {
                    let shared = GeoScreenProjectionMath.project(basis: GeoProjectionBasis(coordinate: place),
                                                                 constants: constants)
                    let tilePoint = TilePointScreenProjector.projectGlobePoint(tilePointInput(for: place),
                                                                               constants: constants)

                    // The shared projector folds the ground's visibility
                    // into `visible`, and the tile projector reports it
                    // apart, so the two flags are compared by what each
                    // means: a point behind the camera has no position.
                    guard tilePoint.screenPoint.visible != 0 else {
                        XCTAssertEqual(shared.visible, 0, "A point behind the camera is visible to neither")
                        continue
                    }
                    XCTAssertEqual(tilePoint.screenPoint.position.x, shared.position.x, accuracy: 1.5,
                                   "x at transition \(transition), pitch \(pitch), \(place)")
                    XCTAssertEqual(tilePoint.screenPoint.position.y, shared.position.y, accuracy: 1.5,
                                   "y at transition \(transition), pitch \(pitch), \(place)")

                    // Away from the threshold itself, where the two differ by
                    // the precision of their trigonometry alone.
                    let threshold = TilePointScreenProjector.visibleGroundThreshold
                    if abs(shared.visibilityAlpha - threshold) > 0.1 {
                        XCTAssertEqual(tilePoint.isOnVisibleGround, shared.visibilityAlpha >= threshold,
                                       "ground visibility at transition \(transition), pitch \(pitch), \(place)")
                    }
                    if transition > 0, transition < 1 {
                        comparedMidMorph += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(comparedMidMorph, 20, "The morph itself is what the test is for")
    }

    /// On the resting sphere a point behind the horizon is not on visible
    /// ground, and the place under the camera is.
    func testTheRestingSphereHidesWhatIsBehindIt() throws {
        let constants = try XCTUnwrap(makeConstants(morphShare: -0.5, pitch: 0))
        XCTAssertEqual(constants.globe.transition, 0)

        let underCamera = TilePointScreenProjector.projectGlobePoint(tilePointInput(for: places[0]),
                                                                     constants: constants)
        XCTAssertTrue(underCamera.isOnVisibleGround)

        let farSide = GeoCoordinate(latitude: -25.1972, longitude: 55.2744 - 180)
        let behind = TilePointScreenProjector.projectGlobePoint(tilePointInput(for: farSide),
                                                                constants: constants)
        XCTAssertFalse(behind.isOnVisibleGround)
    }

    // MARK: - Helpers

    /// The camera over the first place, `morphShare` of the way through the
    /// automatic transition: below zero on the resting sphere. Nil once the
    /// frame is past the globe's projection.
    private func makeConstants(morphShare: Double,
                               pitch: Float) throws -> GeoScreenProjectionMath.FrameConstants? {
        let center = places[0]
        let zoom = presentationSettings.automaticTransitionStartZoom
            + presentationSettings.automaticTransitionSpan * morphShare
        let cameraState = ImmersiveMapCameraState(
            centerWorldMercator: ImmersiveMapProjection.worldMercator(latitude: center.latitude * .pi / 180.0,
                                                                      longitude: center.longitude * .pi / 180.0),
            zoom: zoom,
            bearing: 0,
            pitch: pitch)
        let presentation = PresentationStateResolver.resolve(cameraState: cameraState,
                                                             settings: presentationSettings)
        guard presentation.screenSpaceProjectionMode == .globe else {
            return nil
        }

        let camera = RenderCamera()
        camera.recalculateProjection(aspect: Float(drawSize.width / drawSize.height))
        RenderCameraPoseResolver().updateIfNeeded(camera: camera,
                                                  cameraState: cameraState,
                                                  transition: presentation.presentationState.transition)
        let cameraUniform = CameraUniform(matrix: try XCTUnwrap(camera.cameraMatrix),
                                          eye: camera.eye,
                                          padding: 0)
        return GeoScreenProjectionMath.FrameConstants(drawSize: drawSize,
                                                      cameraUniform: cameraUniform,
                                                      resolvedPresentation: presentation)
    }

    /// The place as a point of the tile it lies in, at `tileZoom`.
    private func tilePointInput(for place: GeoCoordinate) -> TilePointInput {
        let tilesPerSide = Double(1 << tileZoom)
        let latitude = place.latitude * .pi / 180.0
        let worldX = (place.longitude + 180.0) / 360.0 * tilesPerSide
        let worldY = (1.0 - asinh(tan(latitude)) / .pi) * 0.5 * tilesPerSide
        let tileX = min(max(worldX.rounded(.down), 0), tilesPerSide - 1)
        let tileY = min(max(worldY.rounded(.down), 0), tilesPerSide - 1)
        return TilePointInput(uv: SIMD2<Float>(Float(worldX - tileX), Float(worldY - tileY)),
                              tile: SIMD3<Int32>(Int32(tileX), Int32(tileY), Int32(tileZoom)))
    }
}
