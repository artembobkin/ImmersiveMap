// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The surface's visible edge in one formula: the limb of the current
/// sphere, and the plane's horizon as its zero-curvature limit.
final class HorizonEdgeMathTests: XCTestCase {
    private let eye = SIMD3<Float>(0, 0, 1)
    private let radius: Float = 0.28

    func testThePlaneIsTheZeroCurvatureLimit() {
        let edge = HorizonEdgeMath.edge(eye: eye, curvature: 0)
        XCTAssertEqual(edge.up, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(edge.depression, 0)
        XCTAssertEqual(edge.limbDistance, .infinity)

        XCTAssertEqual(HorizonEdgeMath.angleAboveEdge(direction: SIMD3<Float>(0, 0, -1), edge: edge), -.pi / 2, accuracy: 1e-6)
        XCTAssertEqual(HorizonEdgeMath.angleAboveEdge(direction: SIMD3<Float>(1, 0, 0), edge: edge), 0, accuracy: 1e-6)
        XCTAssertEqual(HorizonEdgeMath.angleAboveEdge(direction: simd_normalize(SIMD3<Float>(0, 1, 1)), edge: edge),
                       .pi / 4, accuracy: 1e-6)
    }

    /// On the resting sphere the formula is the classic one: the limb lies
    /// `acos(R / d)` below the local horizontal, `sqrt(d^2 - R^2)` away.
    func testTheRestingSphereMatchesTheClassicLimb() {
        let edge = HorizonEdgeMath.edge(eye: eye, curvature: 1 / radius)
        let centerDistance = 1 + radius
        XCTAssertEqual(edge.up.x, 0, accuracy: 1e-6)
        XCTAssertEqual(edge.up.y, 0, accuracy: 1e-6)
        XCTAssertEqual(edge.up.z, 1, accuracy: 1e-6)
        XCTAssertEqual(edge.depression, acos(radius / centerDistance), accuracy: 1e-5)
        XCTAssertEqual(edge.limbDistance, (centerDistance * centerDistance - radius * radius).squareRoot(), accuracy: 1e-5)

        // Straight down looks `asin(R / d)` inside the limb; a ray grazing
        // the sphere is exactly on the edge. The nadir check is loose on
        // purpose: `asin` loses precision at -1 (one float ulp of the dot
        // product is a third of a milliradian there), which the mirrored
        // shader shares and which only matters far from the edge, where
        // nothing is painted.
        let limbAngle = asin(radius / centerDistance)
        XCTAssertEqual(HorizonEdgeMath.angleAboveEdge(direction: SIMD3<Float>(0, 0, -1), edge: edge),
                       -limbAngle, accuracy: 1e-3)
        let grazing = SIMD3<Float>(sin(limbAngle), 0, -cos(limbAngle))
        XCTAssertEqual(HorizonEdgeMath.angleAboveEdge(direction: grazing, edge: edge), 0, accuracy: 1e-5)
    }

    /// A pitched eye keeps its vertical pointing away from the centre.
    func testThePitchedEyeHasItsOwnVertical() {
        let pitchedEye = SIMD3<Float>(0, -0.7, 0.7)
        let edge = HorizonEdgeMath.edge(eye: pitchedEye, curvature: 1 / radius)
        let expectedUp = simd_normalize(pitchedEye - SIMD3<Float>(0, 0, -radius))
        XCTAssertEqual(simd_distance(edge.up, expectedUp), 0, accuracy: 1e-6)
    }

    /// Flattening the sphere walks the edge up into the horizon: the
    /// depression only ever falls, reaches zero on the plane itself, and
    /// near the plane falls like the square root of the curvature, which is
    /// the real limb of a huge sphere seen from an eye a little above it
    /// (`acos(Rs / (Rs + h))`), not a rounding artifact.
    func testTheEdgeRisesMonotonicallyIntoThePlane() {
        var previous = HorizonEdgeMath.edge(eye: eye, curvature: 1 / radius)
        for step in 1...200 {
            let curvature = (1 / radius) * (1 - Float(step) / 200)
            let edge = HorizonEdgeMath.edge(eye: eye, curvature: curvature)
            XCTAssertLessThanOrEqual(edge.depression, previous.depression + 1e-6, "step \(step)")
            XCTAssertLessThan(simd_distance(edge.up, previous.up), 0.05, "step \(step)")
            if curvature > 0 {
                let sphereRadius = 1 / curvature
                XCTAssertEqual(edge.depression, acos(sphereRadius / (sphereRadius + eye.z)), accuracy: 2e-3, "step \(step)")
            }
            previous = edge
        }
        XCTAssertEqual(previous.depression, 0, accuracy: 1e-6)
    }

    /// The gate: the zoom-1 globe view shows the sky, a flat camera looking
    /// straight down at street pitch sees no horizon within reach.
    func testEdgeReachDecidesWhetherTheLayerDraws() {
        let projection = Matrix.perspectiveMatrix(fovRadians: .pi / 4, aspect: 1, near: 0.01, far: 200)
        let view = Matrix.lookAt(eye: eye, center: SIMD3<Float>(0, 0, 0), up: SIMD3<Float>(0, 1, 0))
        let inverse = simd_inverse(projection * view)

        let sphere = HorizonEdgeMath.edge(eye: eye, curvature: 1 / radius)
        XCTAssertTrue(HorizonEdgeMath.isEdgeWithinReach(edge: sphere, reachBelow: 0, inverseProjectionView: inverse, eye: eye))

        let plane = HorizonEdgeMath.edge(eye: eye, curvature: 0)
        XCTAssertFalse(HorizonEdgeMath.isEdgeWithinReach(edge: plane, reachBelow: 0.1, inverseProjectionView: inverse, eye: eye),
                       "Looking straight down, every corner is far below the horizon")
        XCTAssertTrue(HorizonEdgeMath.isEdgeWithinReach(edge: plane, reachBelow: .pi, inverseProjectionView: inverse, eye: eye))
    }
}
