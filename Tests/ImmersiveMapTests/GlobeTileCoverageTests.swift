// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The sphere's coverage walk: the flat distance rule read off the globe,
/// with the pinned world cover as the floor and as the far field, and the
/// frustum and horizon rejects of the tree walk.
final class GlobeTileCoverageTests: XCTestCase {
    private static let globe = GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0)

    private static func inputs(eyeDistance: Float, farRadius: Double = FlatDistanceCoverage.farRadius) -> GlobeCoverageInputs {
        GlobeCoverageInputs(eye: SIMD3<Float>(0, 0, eyeDistance), globe: globe, rule: CoverageRule(farRadius: farRadius))
    }

    /// A wide frustum looking at the sphere's front point from the eye.
    private static func frustum(eyeDistance: Float, fovRadians: Float = .pi * 0.6) -> Frustum {
        let view = Matrix.lookAt(eye: SIMD3<Float>(0, 0, eyeDistance), center: SIMD3<Float>(0, 0, -1), up: SIMD3<Float>(0, 1, 0))
        let projection = Matrix.perspectiveMatrix(fovRadians: fovRadians, aspect: 1, near: 0.001, far: 100)
        return Frustum(pv: projection * view)
    }

    private static func distance(from inputs: GlobeCoverageInputs, to tile: Tile) -> Double {
        let visibility = GlobeVisibilityModel.makeInputs(globe: inputs.globe, cameraEye: inputs.eye)
        return Double(simd_length(GlobeVisibilityModel.tileBound(tile: tile, inputs: visibility).center - inputs.eye))
    }

    private static func cover(of tile: Tile, in output: [VisibleTile]) -> VisibleTile? {
        output.first { $0.tile == tile || $0.tile.covers(tile) }
    }

    /// Close in, the tile under the eye is exact, the ring around it steps
    /// down the ladder, and the far field is the pinned cover: nothing
    /// below the floor, far fewer targets than leaves in view, and a walk
    /// of a few hundred tiles.
    func testNearTilesAreExactAndTheFarFieldIsTheCover() {
        let inputs = Self.inputs(eyeDistance: 0.05)
        let resolution = GlobeTileCoverage.targets(targetZoom: 6, inputs: inputs, frustum: Self.frustum(eyeDistance: 0.05))
        let output = resolution.targets
        XCTAssertTrue(output.contains(VisibleTile(x: 32, y: 32, z: 6)), "the tile under the eye is exact: \(output)")
        XCTAssertTrue(output.allSatisfy { $0.z >= GlobeTileCoverage.floorZoom })
        let exact = output.filter { $0.z == 6 }
        let cover = output.filter { $0.z == GlobeTileCoverage.floorZoom }
        XCTAssertGreaterThan(exact.count, 0)
        XCTAssertGreaterThan(cover.count, 0, "the far field is asked for at the cover's zoom")
        XCTAssertLessThan(output.count, 60, "far fewer targets than leaves in view: \(output.count)")
        XCTAssertLessThan(resolution.metrics.visitedNodeCount, 600, "the walk stays small: \(resolution.metrics.visitedNodeCount)")
        // Every exact tile is within the exact radius, every farther visible
        // tile is covered by a parent at the zoom its distance wants or coarser.
        let cameraDistance = 0.05
        for target in exact {
            XCTAssertLessThanOrEqual(Self.distance(from: inputs, to: target.tile), FlatDistanceCoverage.exactRadius * cameraDistance * 1.01)
        }
        for x in 28 ... 36 {
            for y in 28 ... 36 {
                let tile = Tile(x: x, y: y, z: 6)
                XCTAssertNotNil(Self.cover(of: tile, in: output), "\(tile) in front of the eye is covered")
            }
        }
    }

    /// Overlaps are allowed on the sphere as on the plane: a parent placed
    /// for the ground around an exact tile covers the exact tile too.
    func testParentsOverlapTheExactTiles() {
        let output = GlobeTileCoverage.targets(targetZoom: 6, inputs: Self.inputs(eyeDistance: 0.05), frustum: Self.frustum(eyeDistance: 0.05)).targets
        let exact = output.filter { $0.z == 6 }
        let parents = output.filter { $0.z < 6 }
        XCTAssertTrue(parents.contains { parent in exact.contains { parent.tile.covers($0.tile) } },
                      "some parent contains an exact tile: \(parents) over \(exact)")
    }

    /// At the cover's zoom and above it nothing coarsens: the whole world is
    /// pinned there, and the walk places the leaves at the target zoom.
    func testShallowTargetsStayExact() {
        for zoom in 0 ... GlobeTileCoverage.floorZoom {
            let output = GlobeTileCoverage.targets(targetZoom: zoom, inputs: Self.inputs(eyeDistance: 4), frustum: Self.frustum(eyeDistance: 4)).targets
            XCTAssertFalse(output.isEmpty)
            XCTAssertTrue(output.allSatisfy { $0.z == zoom }, "z\(zoom): \(output)")
        }
        XCTAssertTrue(GlobeTileCoverage.targets(targetZoom: 6, inputs: Self.inputs(eyeDistance: 4), frustum: nil).targets.isEmpty)
    }

    /// Seen from afar every tile is scaled alike and the whole sphere is
    /// within the exact zone: the culling's target zoom keeps the count.
    func testFromAfarEverythingInViewIsExact() {
        let output = GlobeTileCoverage.targets(targetZoom: 6, inputs: Self.inputs(eyeDistance: 4), frustum: Self.frustum(eyeDistance: 4, fovRadians: .pi / 6)).targets
        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(output.allSatisfy { $0.z == 6 }, "\(output.filter { $0.z != 6 })")
    }

    /// A leaf follows the rule frame by frame, with nothing carried over:
    /// past the exact threshold it drops a level and a parent covers it,
    /// back inside it is exact again.
    func testALeafFollowsTheRuleFrameByFrame() {
        let tile = Tile(x: 32, y: 32, z: 6)
        // The eye on the axis above the front point, which is a corner of
        // the tile: the tile's centre sits a fixed distance to the side, so
        // it leaves the exact zone as the eye comes DOWN, where the camera's
        // own distance shrinks under it. Search for the height where the
        // rule drops it.
        func output(eyeDistance: Float) -> [VisibleTile] {
            GlobeTileCoverage.targets(targetZoom: 6, inputs: Self.inputs(eyeDistance: eyeDistance), frustum: Self.frustum(eyeDistance: eyeDistance)).targets
        }
        var threshold: Float = 0.05
        XCTAssertEqual(FlatDistanceCoverage.drop(distance: Self.distance(from: Self.inputs(eyeDistance: threshold), to: tile), cameraDistance: Double(threshold)), 0)
        while FlatDistanceCoverage.drop(distance: Self.distance(from: Self.inputs(eyeDistance: threshold), to: tile),
                                        cameraDistance: Double(threshold)) == 0 {
            threshold /= 1.01
            XCTAssertGreaterThan(threshold, 0.001, "the rule drops the tile somewhere")
        }
        XCTAssertTrue(output(eyeDistance: threshold * 1.03).contains(VisibleTile(tile: tile)), "within the exact radius")
        let dropped = output(eyeDistance: threshold * 0.97)
        XCTAssertFalse(dropped.contains(VisibleTile(tile: tile)), "past it the tile drops a level")
        XCTAssertNotNil(Self.cover(of: tile, in: dropped), "and a parent covers it")
        XCTAssertTrue(output(eyeDistance: threshold * 1.03).contains(VisibleTile(tile: tile)), "back inside, exact again at once")
    }

    /// A short reach turns most of the view into the far field: the cover
    /// tiles, nothing between them and the exact zone.
    func testAShortReachHandsTheViewToTheCover() {
        let output = GlobeTileCoverage.targets(targetZoom: 6, inputs: Self.inputs(eyeDistance: 0.05, farRadius: 3), frustum: Self.frustum(eyeDistance: 0.05)).targets
        XCTAssertTrue(output.allSatisfy { $0.z >= GlobeTileCoverage.floorZoom })
        XCTAssertGreaterThan(output.filter { $0.z == GlobeTileCoverage.floorZoom }.count, 0)
        XCTAssertTrue(output.contains(VisibleTile(x: 32, y: 32, z: 6)))
    }
}
