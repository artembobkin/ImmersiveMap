// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd
@testable import ImmersiveMap
import XCTest

/// A fold of the unroll flips a triangle's screen winding, and back-face
/// culling then draws far-side geometry over the near map (the mid-morph
/// "wedge" artifact). Folding is machine-decidable: the morph maps
/// (latitude, longitude) onto the growing sphere, and its surface normal
/// (the cross product of the two coordinate tangents) must point outward
/// from that sphere's centre. A sphere cannot unroll without a cut, so
/// fold-freedom cannot hold globally; what must hold, and what this sweep
/// of the production `GlobeUnrollMath.worldPosition` pins, is that every
/// fold is harmless: either inside the unroll's cut (the cap past
/// `GlobeUnrollMath.cutCosine`, which the morph vertex stage clips) or
/// painting at least half a radius from the view centre, far off-screen at
/// the zooms the morph runs at.
final class GlobeUnrollFoldTests: XCTestCase {
    private let radius: Float = 1000

    private func rotationMatrix(panLatitude: Float) -> matrix_float4x4 {
        // The pan rotation exactly as GlobeFrameConstantsUniform builds it
        // (pan longitude 0: folds are longitude-symmetric).
        let cx = cos(-panLatitude)
        let sx = sin(-panLatitude)
        return simd_transpose(matrix_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, cx, sx, 0),
            SIMD4<Float>(0, -sx, cx, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )))
    }

    private func sphereWorld(latitude: Float, longitude: Float, rotation: matrix_float4x4) -> SIMD3<Float> {
        let phi = latitude - .pi / 2
        let theta = longitude + .pi
        let unit = SIMD3<Float>(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
        let rotated = rotation * SIMD4<Float>(unit * radius, 1)
        return SIMD3<Float>(rotated.x, rotated.y, rotated.z - radius)
    }

    private func flatWorld(latitude: Float, longitude: Float,
                           panLatitude: Float, transition: Float,
                           unwrapNear referenceX: Float?) -> SIMD2<Float> {
        // Mirror of globeTransitionMapSize / globeFlatWorldPosition at pan
        // longitude 0.
        let mapSize = 2 * Float.pi * radius * ((1 - transition) * cos(panLatitude) + transition)
        let half = mapSize * 0.5
        let normalizedX = (longitude + .pi) / (2 * .pi)
        var x = Float(ImmersiveMapProjection.wrap(value: Double(normalizedX * mapSize - half),
                                                  size: Double(mapSize)))
        if let referenceX {
            while x - referenceX > half { x -= mapSize }
            while referenceX - x > half { x += mapSize }
        }
        let mercY = Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(latitude)))
        let panMercY = Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(panLatitude)))
        let y = (mercY - panMercY) * half
        return SIMD2<Float>(x, y)
    }

    private func morphPosition(latitude: Float, longitude: Float,
                               panLatitude: Float, transition: Float,
                               rotation: matrix_float4x4,
                               unwrapNear referenceX: Float?) -> (position: SIMD3<Float>, flatX: Float) {
        let sphere = sphereWorld(latitude: latitude, longitude: longitude, rotation: rotation)
        let flat = flatWorld(latitude: latitude, longitude: longitude,
                             panLatitude: panLatitude, transition: transition,
                             unwrapNear: referenceX)
        let position = GlobeUnrollMath.worldPosition(sphereWorldPosition: sphere,
                                                     flatWorldPosition: flat,
                                                     transition: transition,
                                                     radius: radius)
        return (position, flat.x)
    }

    func testTheCutCosineMirrorsTheShader() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let header = try String(contentsOf: root.appendingPathComponent("ImmersiveMap/Render/Shaders/Globe/GlobeUnroll.h"),
                                encoding: .utf8)
        XCTAssertTrue(header.contains("constant float kGlobeUnrollCutCosine = -0.8660254;"))
        XCTAssertEqual(GlobeUnrollMath.cutCosine, -0.8660254)
    }

    func testEveryFoldIsInsideTheCutOrPaintsFarOffScreen() {
        let panLatitudes: [Float] = [0, 0.7, -0.7, 1.05, -1.05, 1.31]
        let transitions: [Float] = [0.02, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.98]
        let step: Float = 3.0 * .pi / 180.0
        let h: Float = 0.02 * .pi / 180.0
        let maxLat: Float = 84.0 * .pi / 180.0
        var violations: [(Float, Float, Float, Float)] = []
        var checked = 0

        for panLatitude in panLatitudes {
            let rotation = rotationMatrix(panLatitude: panLatitude)
            for transition in transitions {
                let curvature = (1 - transition) / radius
                let unrollCenterZ = -1 / curvature
                var latitude: Float = -maxLat
                while latitude <= maxLat {
                    var longitude: Float = -177.0 * .pi / 180.0
                    while longitude <= 177.5 * .pi / 180.0 {
                        let center = morphPosition(latitude: latitude, longitude: longitude,
                                                   panLatitude: panLatitude, transition: transition,
                                                   rotation: rotation, unwrapNear: nil)
                        let dLat = morphPosition(latitude: latitude + h, longitude: longitude,
                                                 panLatitude: panLatitude, transition: transition,
                                                 rotation: rotation, unwrapNear: center.flatX)
                        let dLon = morphPosition(latitude: latitude, longitude: longitude + h,
                                                 panLatitude: panLatitude, transition: transition,
                                                 rotation: rotation, unwrapNear: center.flatX)
                        let tangentLat = dLat.position - center.position
                        let tangentLon = dLon.position - center.position
                        let normal = simd_cross(tangentLat, tangentLon)
                        let outward = center.position - SIMD3<Float>(0, 0, unrollCenterZ)
                        let orientation = simd_dot(normal, outward)
                        checked += 1
                        // The sphere's own orientation at transition 0 is the
                        // reference: d/dLat x d/dLon points inward on this
                        // parametrization, so a healthy sample is negative.
                        if orientation > 0 {
                            // Harmless folds: inside the cut the morph clips,
                            // and past half a radius nothing reaches the
                            // screen at the zooms the morph runs at.
                            let sphere = sphereWorld(latitude: latitude, longitude: longitude,
                                                     rotation: rotation)
                            let cosArc = (sphere.z + radius) / radius
                            let insideCut = cosArc <= GlobeUnrollMath.cutCosine
                            let paintRadius = simd_length(SIMD2<Float>(center.position.x, center.position.y))
                            if insideCut == false, paintRadius < 0.5 * radius {
                                if violations.count < 8 {
                                    violations.append((panLatitude, transition,
                                                       latitude * 180 / .pi, longitude * 180 / .pi))
                                } else {
                                    violations.append((0, 0, 0, 0))
                                }
                            }
                        }
                        longitude += step
                    }
                    latitude += step
                }
            }
        }
        XCTAssertGreaterThan(checked, 100_000)
        XCTAssertTrue(violations.isEmpty,
                      "\(violations.count) harmful folds of \(checked); first: \(violations.prefix(8))")
    }
}
