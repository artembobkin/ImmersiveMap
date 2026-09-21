// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The sphere's coverage walk: the ring rules read off the globe's grid
/// from the look-at tile, with the pinned world cover as the floor and as
/// the ground past the last rule, and the frustum and horizon rejects of
/// the tree walk.
final class GlobeTileCoverageTests: XCTestCase {
    private static let globe = GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0)

    /// The globe at pan zero looks at longitude and latitude zero, the
    /// corner four tiles share: the look-at tile is the south-east one.
    private static func inputs(eyeDistance: Float,
                               rules: FlatRingRules = .default,
                               targetZoom: Int = 6,
                               globe: GlobeUniform = globe,
                               lookAtTile: (x: Int, y: Int)? = nil) -> GlobeCoverageInputs {
        let half = (1 << targetZoom) / 2
        return GlobeCoverageInputs(eye: SIMD3<Float>(0, 0, eyeDistance), globe: globe, rules: rules,
                                   lookAtTile: lookAtTile ?? (half, half))
    }

    /// A wide frustum looking at the sphere's front point from the eye.
    private static func frustum(eyeDistance: Float, fovRadians: Float = .pi * 0.6) -> Frustum {
        let view = Matrix.lookAt(eye: SIMD3<Float>(0, 0, eyeDistance), center: SIMD3<Float>(0, 0, -1), up: SIMD3<Float>(0, 1, 0))
        let projection = Matrix.perspectiveMatrix(fovRadians: fovRadians, aspect: 1, near: 0.001, far: 100)
        return Frustum(pv: projection * view)
    }

    private static func cover(of tile: Tile, in output: [VisibleTile]) -> VisibleTile? {
        output.first { $0.tile == tile || $0.tile.covers(tile) }
    }

    /// The eye is high enough for the frustum to hold the first three
    /// rings whole.
    private static func resolve(eyeDistance: Float = 0.3,
                                rules: FlatRingRules = .default,
                                targetZoom: Int = 6) -> GlobeCoverageResolution {
        GlobeTileCoverage.targets(targetZoom: targetZoom,
                                  inputs: inputs(eyeDistance: eyeDistance, rules: rules, targetZoom: targetZoom),
                                  frustum: frustum(eyeDistance: eyeDistance))
    }

    /// Close in, the look-at tile and the ring around it are exact, the
    /// rings beyond step down by their rules, and the ground past the last
    /// rule is the pinned cover: nothing below the floor and a small walk.
    func testTheRingsAroundTheLookAtTileFollowTheRules() {
        let resolution = Self.resolve()
        let output = resolution.targets
        for x in 31 ... 33 {
            for y in 31 ... 33 {
                XCTAssertTrue(output.contains(VisibleTile(x: x, y: y, z: 6)), "ring 1 is exact: z6/\(x)/\(y)")
            }
        }
        XCTAssertFalse(output.contains(VisibleTile(x: 34, y: 32, z: 6)), "ring 2 is not drawn at the target zoom")
        XCTAssertNotNil(output.first { $0.z == 5 && $0.tile.covers(Tile(x: 34, y: 32, z: 6)) }, "ring 2 is one level coarser")
        XCTAssertNotNil(output.first { $0.z == 4 && $0.tile.covers(Tile(x: 35, y: 32, z: 6)) }, "ring 3 is two levels coarser")
        XCTAssertTrue(output.allSatisfy { $0.z >= GlobeTileCoverage.floorZoom })
        XCTAssertLessThan(resolution.metrics.visitedNodeCount, 600, "the walk stays small: \(resolution.metrics.visitedNodeCount)")
        for x in 28 ... 36 {
            for y in 28 ... 36 {
                let tile = Tile(x: x, y: y, z: 6)
                XCTAssertNotNil(Self.cover(of: tile, in: output), "\(tile) in front of the eye is covered")
            }
        }
    }

    /// Every placed tile answers to a rule: it is at the zoom of a band
    /// whose rings it meets, or it is the cover over ground past the last
    /// rule.
    func testEveryTargetSitsInABandOfItsZoom() {
        let rules = FlatRingRules.default.normalized().rules
        let output = Self.resolve().targets
        XCTAssertFalse(output.isEmpty)
        for target in output {
            let rings = GlobeRingMath.ringRange(of: target.tile, targetZoom: 6, lookAt: (32, 32))
            var firstRing = 0
            var answers = target.z == GlobeTileCoverage.floorZoom && rings.upperBound > (rules.last?.distance ?? 0)
            for rule in rules {
                let zoom = max(GlobeTileCoverage.floorZoom, 6 - rule.zoomDrop)
                if zoom == target.z, firstRing <= rings.upperBound, rule.distance >= rings.lowerBound {
                    answers = true
                }
                firstRing = rule.distance + 1
            }
            XCTAssertTrue(answers, "\(target.tile) at rings \(rings) answers to no rule")
        }
    }

    /// The bands are reported as on the plane, one per rule, with the
    /// tiles each placed.
    func testTheBandsReportTheirZoomsAndCounts() {
        let resolution = Self.resolve()
        XCTAssertEqual(resolution.bands.map(\.zoom), [6, 5, 4, 2])
        XCTAssertEqual(resolution.bands.map(\.distance), [1, 2, 3, 20])
        XCTAssertEqual(resolution.bands.first?.tileCount, 9, "the look-at tile and ring 1, all in view")
        XCTAssertEqual(resolution.bands.map(\.rasterResolution), [256, 256, 256, 256], "the plane's default pictures every band")
        let banded = resolution.bands.reduce(0) { $0 + $1.tileCount }
        XCTAssertLessThanOrEqual(banded, resolution.targets.count)
    }

    /// Overlaps are allowed on the sphere as on the plane: a parent placed
    /// for the ring around the exact tiles covers exact tiles too.
    func testParentsOverlapTheExactTiles() {
        let output = Self.resolve().targets
        let exact = output.filter { $0.z == 6 }
        let parents = output.filter { $0.z < 6 }
        XCTAssertTrue(parents.contains { parent in exact.contains { parent.tile.covers($0.tile) } },
                      "some parent contains an exact tile: \(parents) over \(exact)")
    }

    /// Past the last rule the ground is the pinned cover, and a single
    /// short rule hands the rest of the view to it.
    func testPastTheLastRuleTheGroundIsTheCover() {
        let rules = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 1)])
        let output = Self.resolve(rules: rules).targets
        XCTAssertTrue(output.contains(VisibleTile(x: 32, y: 32, z: 6)))
        XCTAssertTrue(output.contains(VisibleTile(x: 0, y: 0, z: GlobeTileCoverage.floorZoom)))
        XCTAssertTrue(output.allSatisfy { $0.z == 6 || $0.z == GlobeTileCoverage.floorZoom }, "\(output)")
        XCTAssertEqual(output.filter { $0.z == 6 }.count, 9)
    }

    /// The columns close on themselves: a look-at tile in the first column
    /// takes its ring from the last column, across the antimeridian.
    func testTheRingsCrossTheAntimeridian() {
        let seamGlobe = GlobeUniform(panX: 1, panY: 0, radius: 1, transition: 0)
        let inputs = Self.inputs(eyeDistance: 0.3, globe: seamGlobe, lookAtTile: (0, 32))
        let output = GlobeTileCoverage.targets(targetZoom: 6, inputs: inputs, frustum: Self.frustum(eyeDistance: 0.3)).targets
        XCTAssertTrue(output.contains(VisibleTile(x: 0, y: 32, z: 6)), "\(output)")
        XCTAssertTrue(output.contains(VisibleTile(x: 63, y: 32, z: 6)), "the ring's column across the seam is exact: \(output)")
        XCTAssertFalse(output.contains(VisibleTile(x: 62, y: 32, z: 6)), "ring 2 across the seam is coarser")
    }

    /// The shallow zooms need no rule of their own: the whole world is a
    /// few rings wide, and nothing goes below the cover.
    func testShallowTargetsStaySane() {
        for zoom in 0 ... 2 {
            let output = Self.resolve(eyeDistance: 4, targetZoom: zoom).targets
            XCTAssertFalse(output.isEmpty, "z\(zoom)")
            XCTAssertTrue(output.allSatisfy { $0.z >= GlobeTileCoverage.floorZoom && $0.z <= zoom }, "z\(zoom): \(output)")
            XCTAssertTrue(output.contains { $0.z == zoom }, "the look-at tile is exact at z\(zoom): \(output)")
        }
        XCTAssertTrue(GlobeTileCoverage.targets(targetZoom: 6, inputs: Self.inputs(eyeDistance: 4), frustum: nil).targets.isEmpty)
    }

    /// The zooms along the rings need no order: a list whose second rule is
    /// finer than its third still covers the view.
    func testAnyRuleListCoversTheView() {
        let rules = FlatRingRules(rules: [FlatRingRule(zoomDrop: 2, distance: 1),
                                          FlatRingRule(zoomDrop: 0, distance: 3),
                                          FlatRingRule(zoomDrop: 3, distance: 30)])
        let output = Self.resolve(rules: rules).targets
        XCTAssertTrue(output.contains(VisibleTile(x: 35, y: 32, z: 6)), "ring 3 is exact under the second rule: \(output)")
        for x in 28 ... 36 {
            for y in 28 ... 36 {
                XCTAssertNotNil(Self.cover(of: Tile(x: x, y: y, z: 6), in: output), "z6/\(x)/\(y) is covered")
            }
        }
    }

    /// A rule that draws no lines names its tiles, and the cover past the
    /// last rule follows the last rule.
    func testALinelessRuleNamesItsTiles() {
        let rules = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 1),
                                          FlatRingRule(zoomDrop: 2, distance: 6, drawsLines: false)])
        let resolution = Self.resolve(rules: rules)
        XCTAssertFalse(resolution.linelessTargets.isEmpty)
        XCTAssertTrue(resolution.linelessTargets.allSatisfy { $0.z == 4 || $0.z == GlobeTileCoverage.floorZoom },
                      "\(resolution.linelessTargets)")
        XCTAssertTrue(resolution.linelessTargets.contains(VisibleTile(x: 0, y: 0, z: GlobeTileCoverage.floorZoom)))
        XCTAssertFalse(resolution.linelessTargets.contains(VisibleTile(x: 32, y: 32, z: 6)))
        XCTAssertTrue(Self.resolve().linelessTargets.allSatisfy { $0.z < 5 }, "the default's lined rings stay lined")
    }

    /// A rasterizable rule names its tiles with its resolution, the nearer
    /// band's answer for a tile two bands ask for, and a vector rule none.
    func testARasterizableRuleNamesItsTiles() {
        let rules = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 1),
                                          FlatRingRule(zoomDrop: 2, distance: 6, rasterized: true)])
        let resolution = Self.resolve(rules: rules)
        XCTAssertFalse(resolution.rasterizedTargets.isEmpty)
        XCTAssertTrue(resolution.rasterizedTargets.values.allSatisfy { $0 == FlatRingRules.defaultRasterResolution })
        XCTAssertTrue(resolution.rasterizedTargets.keys.allSatisfy { $0.z == 4 || $0.z == GlobeTileCoverage.floorZoom },
                      "the rasterizable band and the cover past it: \(resolution.rasterizedTargets.keys)")
        XCTAssertNil(resolution.rasterizedTargets[VisibleTile(x: 32, y: 32, z: 6)], "the vector band stays vector")
        XCTAssertTrue(resolution.rasterizedTargets.keys.allSatisfy { resolution.targets.contains($0) })
        let vector = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 1), FlatRingRule(zoomDrop: 2, distance: 6)])
        XCTAssertTrue(Self.resolve(rules: vector).rasterizedTargets.isEmpty)
    }

    /// The rules are read frame by frame, with nothing carried over: the
    /// same inputs give the same targets.
    func testTheWalkCarriesNothingOver() {
        XCTAssertEqual(Self.resolve().targets, Self.resolve().targets)
    }
}
