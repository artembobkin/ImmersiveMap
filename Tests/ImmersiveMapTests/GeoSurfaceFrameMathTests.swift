// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// `GeoSurfaceFrameMath` is the single CPU evaluation of the sphere-plane morph,
/// shared by scene model anchors and route tessellation. It must agree with
/// `GeoScreenProjectionMath` (the CPU mirror of the globe shaders), and, unlike
/// the anchor path it was extracted from, it must keep a CHAIN of points
/// continuous across the antimeridian.
final class GeoSurfaceFrameMathTests: XCTestCase {
    private let drawSize = CGSize(width: 800, height: 600)
    private let presentationSettings = ImmersiveMapSettings.default.presentation

    // MARK: - Agreement with the geo projector

    func testGlobeFrameMatchesGeoProjectorAtTransitionZero() throws {
        let constants = try makeConstants(latitude: 10, longitude: 20, zoom: 1.0)
        XCTAssertEqual(constants.mode, .globe)
        XCTAssertEqual(constants.globe.transition, 0)

        for (latitude, longitude) in [(10.0, 20.0), (14.0, 26.0), (-3.0, 12.0)] {
            let basis = GeoProjectionBasis(coordinate: GeoCoordinate(latitude: latitude, longitude: longitude))
            let frame = GeoSurfaceFrameMath.resolve(basis: basis, constants: constants)
            let projected = GeoScreenProjectionMath.project(basis: basis, constants: constants)
            let screen = try XCTUnwrap(screenPoint(worldPosition: frame.worldPosition, constants: constants))

            XCTAssertNotEqual(projected.visible, 0)
            XCTAssertEqual(screen.x, projected.position.x, accuracy: 0.01)
            XCTAssertEqual(screen.y, projected.position.y, accuracy: 0.01)
        }
    }

    func testMidMorphFrameRidesTheUnroll() throws {
        let constants = try makeConstants(latitude: 0, longitude: 0, zoom: 6.3)
        XCTAssertEqual(constants.mode, .globe)
        XCTAssertGreaterThan(constants.globe.transition, 0)
        XCTAssertLessThan(constants.globe.transition, 1)

        let basis = GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 0.4, longitude: 0.6))
        let frame = GeoSurfaceFrameMath.resolve(basis: basis, constants: constants)

        let sphere = constants.rotatedSphereWorldPosition(sphereUnit: basis.sphereUnit)
        let flat = constants.globeFlatWorldPosition(basis: basis)
        let expected = GlobeUnrollMath.worldPosition(sphereWorldPosition: sphere,
                                                     flatWorldPosition: SIMD2<Float>(flat.x, flat.y),
                                                     transition: constants.globe.transition,
                                                     radius: constants.globe.radius)

        XCTAssertEqual(frame.localTransition, constants.globe.transition, accuracy: 1e-6)
        assertPosition(frame.worldPosition, expected)
    }

    func testFlatFrameMatchesGeoProjector() throws {
        let constants = try makeConstants(latitude: 55.75, longitude: 37.61, zoom: 15.0)
        XCTAssertEqual(constants.mode, .flat)

        let basis = GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 55.79, longitude: 37.55))
        let frame = GeoSurfaceFrameMath.resolve(basis: basis, constants: constants)
        let projected = GeoScreenProjectionMath.project(basis: basis, constants: constants)
        let screen = try XCTUnwrap(screenPoint(worldPosition: frame.worldPosition, constants: constants))

        XCTAssertEqual(screen.x, projected.position.x, accuracy: 0.01)
        XCTAssertEqual(screen.y, projected.position.y, accuracy: 0.01)
        assertDirection(frame.up, SIMD3<Float>(0, 0, 1))
    }

    // MARK: - Tangent frame

    func testTangentFrameIsOrthonormalAndRightHanded() throws {
        for zoom in [1.0, 6.3, 6.7, 15.0] {
            let constants = try makeConstants(latitude: 20, longitude: -30, zoom: zoom)
            for (latitude, longitude) in [(0.0, 0.0), (80.0, 179.9), (-80.0, -179.9), (45.0, 90.0)] {
                let basis = GeoProjectionBasis(coordinate: GeoCoordinate(latitude: latitude, longitude: longitude))
                let frame = GeoSurfaceFrameMath.resolve(basis: basis, constants: constants)

                XCTAssertEqual(simd_length(frame.east), 1, accuracy: 1e-4)
                XCTAssertEqual(simd_length(frame.north), 1, accuracy: 1e-4)
                XCTAssertEqual(simd_length(frame.up), 1, accuracy: 1e-4)
                XCTAssertEqual(simd_dot(frame.east, frame.north), 0, accuracy: 1e-4)
                XCTAssertEqual(simd_dot(frame.north, frame.up), 0, accuracy: 1e-4)
                XCTAssertEqual(simd_dot(frame.up, frame.east), 0, accuracy: 1e-4)
                assertDirection(simd_cross(frame.east, frame.north), frame.up)
            }
        }
    }

    // MARK: - Meter scale

    func testUnitsPerMeterMatchesTheAnalyticScaleAtBothEnds() throws {
        let circumference = Float(ImmersiveMapProjection.earthCircumferenceMeters)

        let globeConstants = try makeConstants(latitude: 0, longitude: 0, zoom: 1.0)
        let globeFrame = GeoSurfaceFrameMath.resolve(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 10, longitude: 10)),
            constants: globeConstants)
        XCTAssertEqual(globeFrame.unitsPerMeter,
                       2 * Float.pi * globeConstants.globe.radius / circumference,
                       accuracy: 1e-9)

        let latitude = 55.75
        let flatConstants = try makeConstants(latitude: latitude, longitude: 37.61, zoom: 15.0)
        let flatFrame = GeoSurfaceFrameMath.resolve(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: latitude, longitude: 37.61)),
            constants: flatConstants)
        let expected = Float(flatConstants.flatRenderMapSize)
            / (circumference * Float(cos(latitude * .pi / 180.0)))
        XCTAssertEqual(Double(flatFrame.unitsPerMeter), Double(expected), accuracy: Double(expected) * 1e-4)
    }

    // MARK: - Antimeridian continuity

    /// The flat morph target wraps into one map width, so two neighbours on
    /// opposite sides of the seam jump by a whole world unless the chain is
    /// unwrapped against the previous point. Anchoring a single model never hit
    /// this; a ribbon does.
    func testChainedResolveKeepsTheFlatTermContinuousAcrossTheAntimeridian() throws {
        // The wrap folds X into one map width centred on the camera, so the
        // seam sits opposite the camera: centring at longitude 0 puts it on the
        // antimeridian, where the pair below straddles it.
        let constants = try makeConstants(latitude: 0, longitude: 0, zoom: 6.5)
        XCTAssertEqual(constants.mode, .globe)
        XCTAssertGreaterThan(constants.globe.transition, 0)

        let west = GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 0, longitude: 179.95))
        let east = GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 0, longitude: -179.95))

        let first = GeoSurfaceFrameMath.resolve(basis: west, constants: constants)
        let unchained = GeoSurfaceFrameMath.resolve(basis: east, constants: constants)
        let chained = GeoSurfaceFrameMath.resolve(basis: east,
                                                  constants: constants,
                                                  flatWorldXReference: first.flatWorldX)

        XCTAssertEqual(abs(unchained.flatWorldX - first.flatWorldX),
                       constants.globeMapSize,
                       accuracy: constants.globeMapSize * 0.05)
        XCTAssertLessThan(abs(chained.flatWorldX - first.flatWorldX), constants.globeMapSize * 0.01)
    }

    // MARK: - Helpers

    private func makeConstants(latitude: Double,
                               longitude: Double,
                               zoom: Double) throws -> GeoScreenProjectionMath.FrameConstants {
        let center = ImmersiveMapProjection.worldMercator(latitude: latitude * .pi / 180.0,
                                                          longitude: longitude * .pi / 180.0)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: center,
                                                  zoom: zoom,
                                                  bearing: 0,
                                                  pitch: 0)
        let presentation = PresentationStateResolver.resolve(cameraState: cameraState,
                                                             settings: presentationSettings)
        let camera = RenderCamera()
        camera.recalculateProjection(aspect: Float(drawSize.width / drawSize.height))
        let poseResolver = RenderCameraPoseResolver()
        poseResolver.updateIfNeeded(camera: camera, cameraState: cameraState)
        let cameraMatrix = try XCTUnwrap(camera.cameraMatrix)
        return GeoScreenProjectionMath.FrameConstants(
            drawSize: drawSize,
            cameraUniform: CameraUniform(matrix: cameraMatrix, eye: camera.eye, padding: 0),
            resolvedPresentation: presentation)
    }

    private func screenPoint(worldPosition: SIMD3<Float>,
                             constants: GeoScreenProjectionMath.FrameConstants) -> SIMD2<Float>? {
        let clip = constants.cameraUniform.matrix * SIMD4<Float>(worldPosition, 1.0)
        guard clip.w > 0 else { return nil }
        let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
        return (ndc * 0.5 + 0.5) * constants.viewport
    }

    private func assertPosition(_ actual: SIMD3<Float>,
                                _ expected: SIMD3<Float>,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-5, file: file, line: line)
    }

    private func assertDirection(_ actual: SIMD3<Float>,
                                 _ expected: SIMD3<Float>,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-4, file: file, line: line)
    }
}
