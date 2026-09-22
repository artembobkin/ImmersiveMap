// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
import simd
@testable import ImmersiveMap

/// A road's point width lies on the ground: one ground width per road,
/// whatever way it runs, measured so that a road along the view through the
/// centre of the screen is exactly its points wide. The scale that does the
/// measuring is the ground's across the view at the centre of the screen,
/// and it must not depend on the camera's bearing, or a turn of the camera
/// would change every road's width on the ground.
final class RoadWidthPerspectiveTests: XCTestCase {
    private let viewport = SIMD2<Float>(1600, 1200)

    /// A camera matrix looking at the origin of the ground from `distance`
    /// away, tilted by `pitch` and turned by `bearing`.
    private func cameraMatrix(pitch: Float, bearing: Float, distance: Float = 3) -> matrix_float4x4 {
        let projection = Matrix.perspectiveMatrix(fovRadians: .pi / 3, aspect: viewport.x / viewport.y,
                                                  near: 0.01, far: 200)
        let forward = SIMD3<Float>(sin(pitch) * sin(bearing), sin(pitch) * cos(bearing), -cos(pitch))
        let eye = -forward * distance
        let worldUp: SIMD3<Float> = abs(cos(pitch)) > 0.999 ? SIMD3(sin(bearing), cos(bearing), 0) : SIMD3(0, 0, 1)
        let right = simd_normalize(simd_cross(forward, worldUp))
        let up = simd_cross(right, forward)
        let view = matrix_float4x4(columns: (
            SIMD4(right.x, up.x, -forward.x, 0),
            SIMD4(right.y, up.y, -forward.y, 0),
            SIMD4(right.z, up.z, -forward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1)))
        return projection * view
    }

    private func uniform(_ matrix: matrix_float4x4) -> TileOverviewFadeUniform {
        TileOverviewFadeUniform(overviewAlpha: 1, roadAlpha: 1, landuseAlpha: 1,
                                pixelsPerPoint: 2, cameraZoom: 16,
                                viewportSizePx: viewport,
                                pointWidthReferenceDepth: FlatMapSurfaceDrawer.screenCentreGroundDepth(cameraMatrix: matrix),
                                cameraMatrix: matrix)
    }

    func testTheGroundScaleDoesNotDependOnTheBearingOrTheTilt() {
        let reference = uniform(cameraMatrix(pitch: 0, bearing: 0)).pointWidthCentrePixelsPerWorldUnit
        XCTAssertGreaterThan(reference, 0)
        for pitch in [Float(0.4), 1.0, 1.3] {
            for bearing in [Float(0), 0.7, 2.2, -1.9] {
                let scale = uniform(cameraMatrix(pitch: pitch, bearing: bearing)).pointWidthCentrePixelsPerWorldUnit
                XCTAssertEqual(scale, reference, accuracy: reference * 1e-3,
                               "pitch \(pitch), bearing \(bearing): the ground across the view at the look-at point is a distance away and nothing else")
            }
        }
    }

    func testADrawWithoutACameraMatrixFollowsTheDistanceOnly() {
        let uniform = TileOverviewFadeUniform(overviewAlpha: 1, roadAlpha: 1, landuseAlpha: 1,
                                              pixelsPerPoint: 2, cameraZoom: 16)
        XCTAssertEqual(uniform.pointWidthCentrePixelsPerWorldUnit, 0)
    }

    func testTheGroundAxesAreTheCameraMatrixColumnsOfTheGroundPlane() {
        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4<Float>(1, 2, 3, 4)
        matrix.columns.1 = SIMD4<Float>(5, 6, 7, 8)
        let uniform = TileOverviewFadeUniform(overviewAlpha: 1, roadAlpha: 1, landuseAlpha: 1,
                                              pixelsPerPoint: 2, cameraZoom: 16, cameraMatrix: matrix)
        XCTAssertEqual([uniform.groundAxisXClipX, uniform.groundAxisXClipY, uniform.groundAxisXClipW], [1, 2, 4])
        XCTAssertEqual([uniform.groundAxisYClipX, uniform.groundAxisYClipY, uniform.groundAxisYClipW], [5, 6, 8])
    }

    func testSwiftAndMetalUniformsAgreeOnTheTail() throws {
        XCTAssertEqual(MemoryLayout<TileOverviewFadeUniform>.offset(of: \.pointWidthCentrePixelsPerWorldUnit), 48)
        XCTAssertEqual(MemoryLayout<TileOverviewFadeUniform>.offset(of: \.groundAxisXClipX), 52)
        XCTAssertEqual(MemoryLayout<TileOverviewFadeUniform>.offset(of: \.groundAxisYClipX), 64)

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ImmersiveMap/Tile/Shaders/TileShading.h")
        let source = try String(contentsOf: url, encoding: .utf8)
        let structRange = try XCTUnwrap(source.range(of: "struct OverviewFadeUniform {"))
        let body = source[structRange.upperBound...]
        var cursor = body.startIndex
        for field in ["float footprintOpaqueAreaPx;", "float pointWidthCentrePixelsPerWorldUnit;",
                      "packed_float3 groundAxisXClip;", "packed_float3 groundAxisYClip;"] {
            let range = try XCTUnwrap(body.range(of: field, range: cursor ..< body.endIndex), field)
            cursor = range.upperBound
        }
    }
}
