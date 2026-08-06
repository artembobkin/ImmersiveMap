// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import XCTest
import simd

/// The picking ray must be the exact inverse of the projection the scene model
/// vertex shader runs, and the box test must be oriented, not spherical: a
/// model is tappable where it is drawn and nowhere else.
final class SceneModelPickMathTests: XCTestCase {
    private let camera = PickCamera()
    private let unitBoxMin = SIMD3<Float>(repeating: -1)
    private let unitBoxMax = SIMD3<Float>(repeating: 1)

    // MARK: - Ray

    func testRayThroughScreenCenterHitsBoxAtItsNearFace() throws {
        let ray = try XCTUnwrap(camera.makeRay(at: camera.center))

        let distance = try XCTUnwrap(SceneModelPickMath.intersectionDistance(
            ray: ray,
            boundsMin: unitBoxMin,
            boundsMax: unitBoxMax,
            inverseModelMatrix: matrix_identity_float4x4))

        // Camera at z = 10 looking down -Z: the near face of a unit box at the
        // origin is 9 units away.
        XCTAssertEqual(distance, 9, accuracy: 1e-3)
    }

    func testRayThroughViewportCornerMissesCenteredBox() throws {
        let ray = try XCTUnwrap(camera.makeRay(at: CGPoint(x: 10, y: 10)))

        XCTAssertNil(SceneModelPickMath.intersectionDistance(ray: ray,
                                                             boundsMin: unitBoxMin,
                                                             boundsMax: unitBoxMax,
                                                             inverseModelMatrix: matrix_identity_float4x4))
    }

    /// The ray must agree with the projection to the pixel: whatever world
    /// point a tap is aimed at, the hit distance is the distance to that point.
    func testHitDistanceMatchesTheProjectedWorldPoint() throws {
        let target = SIMD3<Float>(0.5, -0.25, 1)
        let ray = try XCTUnwrap(camera.makeRay(at: camera.screenPoint(world: target)))

        let distance = try XCTUnwrap(SceneModelPickMath.intersectionDistance(
            ray: ray,
            boundsMin: unitBoxMin,
            boundsMax: unitBoxMax,
            inverseModelMatrix: matrix_identity_float4x4))

        XCTAssertEqual(distance, simd_distance(target, camera.eye), accuracy: 1e-2)
    }

    // MARK: - Oriented box

    /// The same ray against the same elongated model: a miss while the rod lies
    /// along X, a hit once it is turned to lie along Y. A bounding sphere (its
    /// radius is 5) would report a hit either way.
    func testElongatedModelIsTestedOrientedRatherThanAsASphere() throws {
        let rodMin = SIMD3<Float>(-5, -0.05, -0.05)
        let rodMax = SIMD3<Float>(5, 0.05, 0.05)
        let alongTheRodAxis = SIMD3<Float>(0, 3, 0)
        let ray = try XCTUnwrap(camera.makeRay(at: camera.screenPoint(world: alongTheRodAxis)))
        XCTAssertLessThan(simd_length(alongTheRodAxis), (rodMax - rodMin).max() * 0.5,
                          "The aimed point must be inside the model's bounding sphere")

        XCTAssertNil(SceneModelPickMath.intersectionDistance(ray: ray,
                                                             boundsMin: rodMin,
                                                             boundsMax: rodMax,
                                                             inverseModelMatrix: matrix_identity_float4x4))

        let turned = Matrix.rotationMatrixZ(.pi / 2)
        XCTAssertNotNil(SceneModelPickMath.intersectionDistance(
            ray: ray,
            boundsMin: rodMin,
            boundsMax: rodMax,
            inverseModelMatrix: simd_inverse(turned)))
    }

    func testBoxBehindTheCameraIsNotHit() throws {
        let ray = try XCTUnwrap(camera.makeRay(at: camera.center))
        let behind = Matrix.translationMatrix(x: 0, y: 0, z: 30)

        XCTAssertNil(SceneModelPickMath.intersectionDistance(
            ray: ray,
            boundsMin: unitBoxMin,
            boundsMax: unitBoxMax,
            inverseModelMatrix: simd_inverse(behind)))
    }

    /// A model scaled to nothing inverts to a matrix of infinities; the test
    /// must report a miss instead of a bogus hit.
    func testDegenerateModelMatrixIsNotHit() throws {
        let ray = try XCTUnwrap(camera.makeRay(at: camera.center))
        let collapsed = Matrix.scaleMatrix(sx: 0, sy: 0, sz: 0)

        XCTAssertNil(SceneModelPickMath.intersectionDistance(
            ray: ray,
            boundsMin: unitBoxMin,
            boundsMax: unitBoxMax,
            inverseModelMatrix: simd_inverse(collapsed)))
    }

    // MARK: - Screen bounds

    func testScreenBoundsSurroundTheProjectedBox() throws {
        let bounds = try XCTUnwrap(SceneModelPickMath.screenBounds(boundsMin: unitBoxMin,
                                                                   boundsMax: unitBoxMax,
                                                                   modelMatrix: matrix_identity_float4x4,
                                                                   projectionView: camera.projectionView,
                                                                   drawSize: camera.drawSize))

        XCTAssertTrue(bounds.contains(camera.center))
        for corner in [SIMD3<Float>(-1, -1, 1), SIMD3<Float>(1, 1, 1), SIMD3<Float>(-1, 1, -1)] {
            let projected = camera.screenPoint(world: corner)
            XCTAssertTrue(bounds.contains(projected), "Corner \(corner) fell outside the screen bounds")
        }
    }

    func testScreenBoundsRejectABoxSpanningTheCamera() {
        let around = Matrix.scaleMatrix(sx: 20, sy: 20, sz: 20)

        XCTAssertNil(SceneModelPickMath.screenBounds(boundsMin: unitBoxMin,
                                                     boundsMax: unitBoxMax,
                                                     modelMatrix: around,
                                                     projectionView: camera.projectionView,
                                                     drawSize: camera.drawSize))
    }
}

/// A perspective camera assembled exactly as `RenderCamera` does, with the
/// pixel conversion `GeoScreenProjectionMath` uses (origin bottom-left, y up).
struct PickCamera {
    let drawSize = CGSize(width: 800, height: 600)
    let eye = SIMD3<Float>(0, 0, 10)
    let projectionView: matrix_float4x4

    var center: CGPoint {
        CGPoint(x: drawSize.width * 0.5, y: drawSize.height * 0.5)
    }

    init() {
        let projection = Matrix.perspectiveMatrix(fovRadians: .pi / 4,
                                                  aspect: Float(drawSize.width / drawSize.height),
                                                  near: 0.01,
                                                  far: 200)
        projectionView = projection * Matrix.lookAt(eye: eye,
                                                    center: .zero,
                                                    up: SIMD3<Float>(0, 1, 0))
    }

    func makeRay(at pixelPoint: CGPoint) -> SceneModelPickMath.Ray? {
        SceneModelPickMath.makeRay(pixelPoint: pixelPoint,
                                   drawSize: drawSize,
                                   projectionView: projectionView,
                                   cameraEye: eye)
    }

    func screenPoint(world: SIMD3<Float>) -> CGPoint {
        let clip = projectionView * SIMD4<Float>(world, 1)
        let normalizedDevice = SIMD2<Float>(clip.x, clip.y) / clip.w
        return CGPoint(x: CGFloat((normalizedDevice.x * 0.5 + 0.5)) * drawSize.width,
                       y: CGFloat((normalizedDevice.y * 0.5 + 0.5)) * drawSize.height)
    }
}
