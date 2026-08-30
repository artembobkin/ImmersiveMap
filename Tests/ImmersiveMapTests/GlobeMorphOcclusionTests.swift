// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The invariant behind the globe surface's clip: while the sphere unfurls
/// into the plane, no patch of the surface is drawn where the planet stands
/// between it and the eye. The globe drawers do not depth-test, the far side
/// of the planet is placed as soon as the morph starts, and its chords
/// through the planet's interior turn front-facing before they are out, so
/// back-face culling alone let them paint over the near ground (12 to 18 per
/// cent of the far side mid-morph in this very sweep). The sphere occlusion
/// clip (`GlobeOcclusionMath`, the mirror of GlobeOcclusion.h) must cut every
/// such patch: over a grid of the whole sphere, at the zooms of the morph and
/// at two camera pitches, a patch that is front-facing and hidden by the
/// planet must have a negative clearance.
final class GlobeMorphOcclusionTests: XCTestCase {
    private let drawSize = CGSize(width: 1600, height: 900)
    private static let latitude = 55.75
    private static let longitude = 37.61
    private let gridStepDegrees = 3.0

    private struct Scene {
        let constants: GeoScreenProjectionMath.FrameConstants
        let eye: SIMD3<Float>
        let radius: Float
        let transition: Float
    }

    private func makeScene(zoom: Double, pitch: Float) throws -> Scene {
        let center = ImmersiveMapProjection.worldMercator(latitude: Self.latitude * .pi / 180.0,
                                                          longitude: Self.longitude * .pi / 180.0)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: center, zoom: zoom, bearing: 0, pitch: pitch)
        let presentation = PresentationStateResolver.resolve(cameraState: cameraState,
                                                             settings: ImmersiveMapSettings.default.presentation)
        let camera = RenderCamera()
        camera.recalculateProjection(aspect: Float(drawSize.width / drawSize.height))
        let poseResolver = RenderCameraPoseResolver()
        poseResolver.updateIfNeeded(camera: camera, cameraState: cameraState)
        let cameraUniform = CameraUniform(matrix: try XCTUnwrap(camera.cameraMatrix), eye: camera.eye, padding: 0)
        let constants = GeoScreenProjectionMath.FrameConstants(drawSize: drawSize,
                                                               cameraUniform: cameraUniform,
                                                               resolvedPresentation: presentation)
        return Scene(constants: constants,
                     eye: camera.eye,
                     radius: presentation.globeRenderUniform.radius,
                     transition: presentation.globeRenderUniform.transition)
    }

    /// The morphed world position of a geographic point, exactly as
    /// `GeoScreenProjectionMath.projectGlobe` and the shaders compute it.
    private func morphedPosition(latitude: Double, longitude: Double, scene: Scene) -> SIMD3<Float> {
        let basis = GeoProjectionBasis(coordinate: GeoCoordinate(latitude: latitude, longitude: longitude))
        let sphere = scene.constants.rotatedSphereWorldPosition(sphereUnit: basis.sphereUnit)
        let flat = scene.constants.globeFlatWorldPosition(basis: basis)
        let frontDot = (sphere.z + scene.radius) / max(scene.radius, 1e-6)
        let phase = GeoScreenProjectionMath.transitionLocalPhase(scene.transition, frontDot: frontDot)
        return sphere + (flat - sphere) * phase
    }

    private func spherePosition(latitude: Double, longitude: Double, scene: Scene) -> SIMD3<Float> {
        let basis = GeoProjectionBasis(coordinate: GeoCoordinate(latitude: latitude, longitude: longitude))
        return scene.constants.rotatedSphereWorldPosition(sphereUnit: basis.sphereUnit)
    }

    /// Whether the segment from the eye to `position` enters the (slightly
    /// shrunk, as the clip's own margin) sphere before reaching the point.
    private func isHiddenByThePlanet(_ position: SIMD3<Float>, scene: Scene) -> Bool {
        let radius = scene.radius * (1.0 - GlobeOcclusionMath.radiusMargin)
        let center = SIMD3<Float>(0, 0, -scene.radius)
        let direction = position - scene.eye
        let toEye = scene.eye - center
        let a = simd_dot(direction, direction)
        let b = 2 * simd_dot(direction, toEye)
        let c = simd_dot(toEye, toEye) - radius * radius
        let discriminant = b * b - 4 * a * c
        guard a > 0, discriminant > 0 else { return false }
        let entry = (-b - discriminant.squareRoot()) / (2 * a)
        return entry > 0 && entry < 1 - 1e-5
    }

    /// Whether the patch around the point faces the eye: east across north is
    /// the surface normal of a counter-clockwise tile triangle.
    private func isFrontFacing(latitude: Double, longitude: Double, scene: Scene) -> Bool {
        let step = 0.05
        let position = morphedPosition(latitude: latitude, longitude: longitude, scene: scene)
        let east = morphedPosition(latitude: latitude, longitude: longitude + step, scene: scene) - position
        let north = morphedPosition(latitude: latitude + step, longitude: longitude, scene: scene) - position
        return simd_dot(simd_cross(east, north), scene.eye - position) > 0
    }

    private func forEachGridPoint(_ body: (Double, Double) -> Void) {
        for latitude in stride(from: -84.0, through: 84.0, by: gridStepDegrees) {
            for longitude in stride(from: -180.0, to: 180.0, by: gridStepDegrees) {
                body(latitude, longitude)
            }
        }
    }

    func testNothingHiddenByThePlanetSurvivesTheClipMidMorph() throws {
        // Where culling alone falls short: hidden patches that face the eye.
        // They cluster around the last third of the morph (a few per cent of
        // the sphere at zoom 7 over Moscow), which is the sweep's premise.
        var hiddenAndFrontFacing = 0
        for zoom in [6.3, 6.6, 6.9, 7.15, 7.4] {
            for pitch: Float in [0, 1.309] {
                let scene = try makeScene(zoom: zoom, pitch: pitch)
                XCTAssertGreaterThan(scene.transition, 0, "zoom \(zoom): the premise is a sphere unfurling")
                XCTAssertLessThan(scene.transition, 1, "zoom \(zoom): and not finished")
                var leaks = 0
                var firstLeak = ""
                forEachGridPoint { latitude, longitude in
                    let position = morphedPosition(latitude: latitude, longitude: longitude, scene: scene)
                    guard isHiddenByThePlanet(position, scene: scene),
                          isFrontFacing(latitude: latitude, longitude: longitude, scene: scene) else { return }
                    hiddenAndFrontFacing += 1
                    let clearance = GlobeOcclusionMath.clearance(position: position, eye: scene.eye, radius: scene.radius)
                    if clearance > 0 {
                        leaks += 1
                        if firstLeak.isEmpty {
                            firstLeak = "lat \(latitude) lon \(longitude) clearance \(clearance)"
                        }
                    }
                }
                XCTAssertEqual(leaks, 0, "zoom \(zoom) pitch \(pitch): \(leaks) hidden front-facing patches pass the clip, first \(firstLeak)")
            }
        }
        XCTAssertGreaterThan(hiddenAndFrontFacing, 100, "The sweep must exercise what culling misses")
    }

    func testOnThePureSphereTheClipIsTheHorizon() throws {
        let scene = try makeScene(zoom: 5.0, pitch: 1.309)
        XCTAssertEqual(scene.transition, 0)
        let center = SIMD3<Float>(0, 0, -scene.radius)
        let toEye = scene.eye - center
        let radiusSquared = scene.radius * scene.radius
        var mismatches = 0
        var checked = 0
        forEachGridPoint { latitude, longitude in
            let sphere = spherePosition(latitude: latitude, longitude: longitude, scene: scene)
            let horizon = simd_dot(sphere - center, toEye) - radiusSquared
            // Away from the limb itself, where both predicates cross zero.
            guard abs(horizon) > 0.02 * radiusSquared else { return }
            checked += 1
            let clearance = GlobeOcclusionMath.clearance(position: sphere, eye: scene.eye, radius: scene.radius)
            if (clearance > 0) != (horizon > 0) {
                mismatches += 1
            }
        }
        XCTAssertGreaterThan(checked, 1000)
        XCTAssertEqual(mismatches, 0, "\(mismatches) of \(checked) sphere points disagree with the horizon predicate")
    }

    func testOnTheFinishedPlaneNothingIsClipped() throws {
        // Past the morph window's geometry completion the surface is the
        // plane while the presentation is still spherical: the clip must let
        // every point through, the way the forced pass used to.
        let scene = try makeScene(zoom: 7.75, pitch: 1.309)
        XCTAssertEqual(scene.transition, 1)
        var clipped = 0
        forEachGridPoint { latitude, longitude in
            let position = morphedPosition(latitude: latitude, longitude: longitude, scene: scene)
            if GlobeOcclusionMath.clearance(position: position, eye: scene.eye, radius: scene.radius) <= 0 {
                clipped += 1
            }
        }
        XCTAssertEqual(clipped, 0, "\(clipped) plane points would be clipped by the sphere below the plane")
    }
}
