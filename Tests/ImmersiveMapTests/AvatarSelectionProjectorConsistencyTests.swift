// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// Avatars must be projected with the same math as tiles and SwiftUI markers
/// (GeoScreenProjectionMath). Regression: with the old uniform lerp without
/// the morph wave, the Moscow avatar "drifted" across the screen and flew off
/// it with the camera over Dubai at high tilt mid-morph.
final class AvatarSelectionProjectorConsistencyTests: XCTestCase {
    private let drawSize = CGSize(width: 1800, height: 900)
    private let presentationSettings = ImmersiveMapSettings.default.presentation

    func testProjectionMatchesSharedProjectorMidMorphAtHighTilt() throws {
        let dubai = GeoCoordinate(latitude: 25.1972, longitude: 55.2744)
        let latitudeExtension = log2(1.0 / cos(dubai.latitude * .pi / 180.0))
        let midMorphZoom = presentationSettings.automaticTransitionStartZoom
            + (presentationSettings.automaticTransitionSpan + latitudeExtension) * 0.45
        let cameraState = makeCameraState(latitude: dubai.latitude,
                                          longitude: dubai.longitude,
                                          zoom: midMorphZoom,
                                          pitch: 1.28)
        let presentation = PresentationStateResolver.resolve(cameraState: cameraState,
                                                             settings: presentationSettings)
        XCTAssertEqual(presentation.screenSpaceProjectionMode, .globe)
        XCTAssertGreaterThan(presentation.globeRenderUniform.transition, 0.0)
        XCTAssertLessThan(presentation.globeRenderUniform.transition, 1.0)

        let camera = RenderCamera()
        camera.recalculateProjection(aspect: Float(drawSize.width / drawSize.height))
        let poseResolver = RenderCameraPoseResolver()
        poseResolver.updateIfNeeded(camera: camera, cameraState: cameraState)
        let cameraUniform = CameraUniform(matrix: try XCTUnwrap(camera.cameraMatrix),
                                          eye: camera.eye,
                                          padding: 0)
        let constants = GeoScreenProjectionMath.FrameConstants(drawSize: drawSize,
                                                               cameraUniform: cameraUniform,
                                                               resolvedPresentation: presentation)

        let coordinates: [(UInt64, GeoCoordinate)] = [
            (1, dubai),
            (2, GeoCoordinate(latitude: 55.7558, longitude: 37.6173)),
            (3, GeoCoordinate(latitude: -33.8688, longitude: 151.2093)),
            (4, GeoCoordinate(latitude: 35.6595, longitude: 139.7005))
        ]
        let markers = try coordinates.map { id, coordinate in
            PresentedAvatarMarker(marker: AvatarMarker(id: id,
                                                       coordinate: coordinate,
                                                       image: try Self.makeTestImage()),
                                  squashScale: SIMD2<Float>(1, 1),
                                  drawOrder: Int(id),
                                  projectionBasis: GeoProjectionBasis(coordinate: coordinate))
        }

        let projected = AvatarSelectionProjector().project(markers: markers,
                                                           drawSize: drawSize,
                                                           cameraUniform: cameraUniform,
                                                           resolvedPresentation: presentation,
                                                           cullMarginPx: 0)

        var expectedVisibleIDs = Set<UInt64>()
        for marker in markers {
            let point = GeoScreenProjectionMath.project(basis: marker.projectionBasis,
                                                        constants: constants)
            let insideViewport = point.position.x >= 0 && point.position.x <= constants.viewport.x
                && point.position.y >= 0 && point.position.y <= constants.viewport.y
            if point.visible != 0, point.visibilityAlpha > 0, insideViewport {
                expectedVisibleIDs.insert(marker.marker.id)
            }
        }
        XCTAssertEqual(Set(projected.map(\.marker.id)), expectedVisibleIDs,
                       "The set of visible avatars must match the shared projector")
        XCTAssertTrue(expectedVisibleIDs.contains(1), "Dubai, right under the camera, must be visible")

        for projectedMarker in projected {
            let source = try XCTUnwrap(markers.first { $0.marker.id == projectedMarker.marker.id })
            let expected = GeoScreenProjectionMath.project(basis: source.projectionBasis,
                                                           constants: constants)
            XCTAssertEqual(projectedMarker.screenPoint.position.x, expected.position.x)
            XCTAssertEqual(projectedMarker.screenPoint.position.y, expected.position.y)
            XCTAssertEqual(projectedMarker.screenPoint.visibilityAlpha, expected.visibilityAlpha)
        }
    }

    // MARK: - Helpers

    private func makeCameraState(latitude: Double,
                                 longitude: Double,
                                 zoom: Double,
                                 pitch: Float) -> ImmersiveMapCameraState {
        let center = ImmersiveMapProjection.worldMercator(latitude: latitude * .pi / 180.0,
                                                          longitude: longitude * .pi / 180.0)
        return ImmersiveMapCameraState(centerWorldMercator: center,
                                       zoom: zoom,
                                       bearing: 0,
                                       pitch: pitch)
    }

    private static func makeTestImage() throws -> CGImage {
        let bytesPerRow = 4
        var data = Data(repeating: 0xff, count: bytesPerRow)
        let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: 1,
                                          height: 1,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return context.makeImage()
        }
        return try XCTUnwrap(image)
    }
}
