// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The flat map's coverage walk: the same targets the distance rule gives
/// leaf by leaf, without visiting the leaves a parent covers. Exact within
/// the exact radius, one level per `1 / steepness` doublings beyond,
/// overlaps allowed, the farthest parents trimmed to the ceiling, the rest
/// of the far field handed to the z3 horizon backdrop.
final class FlatTileCoverageTests: XCTestCase {
    /// A z9 world whose tiles are one world unit wide, so distances read in
    /// tiles.
    private static let zoom = 9
    private static let flatRenderState = FlatRenderState(pan: .zero, renderMapSize: Double(1 << zoom))
    private static let lookAt = SIMD2<Double>(256.5, 250.5)

    /// The world position of a point in tile units (tile y grows south,
    /// world y north).
    private static func world(ofTilePoint point: SIMD2<Double>) -> SIMD2<Double> {
        let world = FlatDistanceCoverage.worldPoint(ofTilePoint: point, zoom: zoom, flatRenderState: flatRenderState)
        return SIMD2<Double>(world.x, world.y)
    }

    private static func worldCenter(of tile: VisibleTile) -> SIMD3<Double> {
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x, y: tile.y, z: tile.z, loop: tile.loop,
                                                                  flatRenderPan: flatRenderState.pan,
                                                                  renderMapSize: flatRenderState.renderMapSize)
        return SIMD3<Double>(Double(origin.x) + Double(origin.z) / 2, Double(origin.y) + Double(origin.z) / 2, 0)
    }

    /// A inputs `distance` tiles from the look-at point, pitched `tilt`
    /// degrees, turned to `bearing` degrees (0 looks north, 90 east).
    private static func inputs(tilt: Double, bearing: Double = 0, distance: Double = 1.2) -> FlatCoverageInputs {
        let radians = bearing * .pi / 180
        // Forward on the ground in tile units: north is -y, east is +x.
        let forward = SIMD2<Double>(sin(radians), -cos(radians))
        let behind = distance * sin(tilt * .pi / 180)
        let eyeGround = lookAt - forward * behind
        let eyeGroundWorld = world(ofTilePoint: eyeGround)
        let eye = SIMD3<Double>(eyeGroundWorld.x, eyeGroundWorld.y, distance * cos(tilt * .pi / 180))
        return FlatCoverageInputs(eye: eye, flatRenderState: flatRenderState, eyeGround: eyeGround, lookAt: lookAt)
    }

    /// How far ahead of the eye's ground point a 45 degree frustum at
    /// `tilt` reaches: the far edge of the view, or 40 tiles once it looks
    /// past the horizon.
    private static func reach(tilt: Double, distance: Double = 1.2) -> Double {
        let radians = tilt * .pi / 180
        let farEdge = radians + .pi / 8
        guard farEdge < 89 * .pi / 180 else { return 40 }
        return min(40, distance * cos(radians) * tan(farEdge) - distance * sin(radians) + 0.5)
    }

    /// The ground a square 45 degree frustum sees from that inputs, as the
    /// convex wedge the walk tests tiles against: a turned view cuts the
    /// tile grid diagonally the way a real inputs does.
    private static func polygon(tilt: Double, bearing: Double = 0, distance: Double = 1.2, reach: Double? = nil,
                                aspect: Double = 1) -> CoveragePolygon {
        let reach = reach ?? Self.reach(tilt: tilt, distance: distance)
        let radians = bearing * .pi / 180
        let forward = SIMD2<Double>(sin(radians), -cos(radians))
        let right = SIMD2<Double>(-forward.y, forward.x)
        let behind = distance * sin(tilt * .pi / 180)
        let eyeGround = lookAt - forward * behind
        func halfWidth(_ ahead: Double) -> Double { ahead * tan(Double.pi / 8) * aspect + 0.5 }
        let near = 0.25
        let nearCenter: SIMD2<Double> = eyeGround + forward * near
        let farCenter: SIMD2<Double> = eyeGround + forward * reach
        let nearSide: SIMD2<Double> = right * halfWidth(near)
        let farSide: SIMD2<Double> = right * halfWidth(reach)
        let corners: [SIMD2<Double>] = [nearCenter - nearSide, nearCenter + nearSide, farCenter + farSide, farCenter - farSide]
        return CoveragePolygon(vertices: corners.map { SIMD2<Float>(world(ofTilePoint: $0)) })
    }

    /// A square of tiles as a polygon, in tile units.
    private static func square(minX: Double, minY: Double, maxX: Double, maxY: Double) -> CoveragePolygon {
        CoveragePolygon(vertices: [SIMD2<Float>(world(ofTilePoint: SIMD2<Double>(minX, minY))),
                                   SIMD2<Float>(world(ofTilePoint: SIMD2<Double>(maxX, minY))),
                                   SIMD2<Float>(world(ofTilePoint: SIMD2<Double>(maxX, maxY))),
                                   SIMD2<Float>(world(ofTilePoint: SIMD2<Double>(minX, maxY)))])
    }

    /// The leaves the polygon meets, the reference the walk is checked
    /// against.
    private static func leaves(in polygon: CoveragePolygon, zoom: Int = zoom, state: FlatRenderState = flatRenderState) -> [VisibleTile] {
        let tileSize = state.renderMapSize / Double(1 << zoom)
        let half = state.renderMapSize / 2
        let minColumn = Int(floor((Double(polygon.bounds.minX) + half) / tileSize)) - 1
        let maxColumn = Int(floor((Double(polygon.bounds.maxX) + half) / tileSize)) + 1
        let minRow = Int(floor((half - Double(polygon.bounds.maxY)) / tileSize)) - 1
        let maxRow = Int(floor((half - Double(polygon.bounds.minY)) / tileSize)) + 1
        var tiles: [VisibleTile] = []
        for y in minRow ... maxRow {
            for x in minColumn ... maxColumn {
                let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: x, y: y, z: zoom, loop: 0,
                                                                          flatRenderPan: state.pan, renderMapSize: state.renderMapSize)
                if polygon.intersects(minX: Double(origin.x), minY: Double(origin.y),
                                      maxX: Double(origin.x) + Double(origin.z), maxY: Double(origin.y) + Double(origin.z)) {
                    tiles.append(VisibleTile(x: x, y: y, z: zoom))
                }
            }
        }
        return tiles
    }

    /// The rule applied leaf by leaf, as the coverage used to compute it:
    /// every leaf's ancestor at the zoom its centre's distance wants, the
    /// far field beyond the reach left out, nothing at the backdrop's zoom
    /// or coarser, no ceiling. A leaf is exact by its centre wherever its
    /// square is in view; a parent is asked for by the leaf centres in
    /// view, which is the ground the walk reads.
    private static func leafRuleTargets(leaves: [VisibleTile], inputs: FlatCoverageInputs, polygon: CoveragePolygon) -> Set<VisibleTile> {
        let lookAtWorld = FlatDistanceCoverage.worldPoint(ofTilePoint: inputs.lookAt, zoom: zoom, flatRenderState: inputs.flatRenderState)
        let cameraDistance = simd_length(inputs.eye - lookAtWorld) * pow(2.0, Double(max(0, inputs.overzoomLevels)))
        var targets: Set<VisibleTile> = []
        for leaf in leaves {
            let center = worldCenter(of: leaf)
            let distance = simd_length(center - inputs.eye)
            let centerInView = polygon.intersects(minX: center.x, minY: center.y, maxX: center.x, maxY: center.y)
            if inputs.backdropZoom != nil, distance > inputs.farRadius * cameraDistance { continue }
            let wanted = max(0, leaf.z - FlatDistanceCoverage.drop(distance: distance, cameraDistance: cameraDistance))
            if let backdropZoom = inputs.backdropZoom, wanted <= backdropZoom { continue }
            if wanted == leaf.z {
                targets.insert(leaf)
            } else if centerInView, let parent = leaf.tile.findParentTile(atZoom: wanted) {
                targets.insert(VisibleTile(tile: parent, loop: leaf.loop))
            }
        }
        return targets
    }

    private static func cover(of tile: VisibleTile, in output: [VisibleTile]) -> VisibleTile? {
        output.first { $0.loop == tile.loop && ($0.tile == tile.tile || $0.tile.covers(tile.tile)) }
    }

    private func targets(inputs: FlatCoverageInputs, polygon: CoveragePolygon, coverage: FlatTileCoverage = FlatTileCoverage()) -> [VisibleTile] {
        coverage.targets(targetZoom: Self.zoom, inputs: inputs, polygon: polygon)
    }

    /// Straight down the whole view is within the exact radius: every tile
    /// exact, nothing else.
    func testTopDownIsExact() {
        let polygon = Self.square(minX: 255.1, minY: 249.1, maxX: 256.9, maxY: 250.9)
        var expected: Set<VisibleTile> = []
        for column in 0 ... 1 {
            for row in 0 ... 1 {
                expected.insert(VisibleTile(x: 255 + column, y: 249 + row, z: Self.zoom))
            }
        }
        XCTAssertEqual(Set(targets(inputs: Self.inputs(tilt: 0), polygon: polygon)), expected)
    }

    /// The walk places what the rule says leaf by leaf: the same exact
    /// tiles, and every parent a leaf centre in view asks for. A parent a
    /// band only grazes without holding a leaf's centre is the one extra
    /// the walk may add, since it reads the ground's extent between the
    /// centres, not the centres themselves.
    func testTheWalkMatchesTheRuleAppliedLeafByLeaf() {
        for tilt in [0.0, 20.0, 30.0, 45.0, 60.0, 70.0, 75.0] {
            for bearing in stride(from: 0.0, through: 150.0, by: 30.0) {
                let aspect = bearing.truncatingRemainder(dividingBy: 60) == 0 ? 1.0 : 1.78
                let inputs = Self.inputs(tilt: tilt, bearing: bearing)
                let polygon = Self.polygon(tilt: tilt, bearing: bearing, aspect: aspect)
                let walked = targets(inputs: inputs, polygon: polygon)
                let reference = Self.leafRuleTargets(leaves: Self.leaves(in: polygon), inputs: inputs, polygon: polygon)
                let walkedExact = Set(walked.filter { $0.z == Self.zoom })
                let referenceExact = reference.filter { $0.z == Self.zoom }
                XCTAssertEqual(walkedExact, referenceExact, "tilt \(tilt) bearing \(bearing): the exact tiles")
                let walkedParents = Set(walked.filter { $0.z < Self.zoom })
                let referenceParents = reference.filter { $0.z < Self.zoom }
                guard walkedParents.count < FlatDistanceCoverage.maximumParents else { continue }
                XCTAssertTrue(referenceParents.isSubset(of: walkedParents),
                              "tilt \(tilt) bearing \(bearing): missing \(referenceParents.subtracting(walkedParents))")
                XCTAssertLessThanOrEqual(walkedParents.subtracting(referenceParents).count, 3,
                                         "tilt \(tilt) bearing \(bearing): extra \(walkedParents.subtracting(referenceParents))")
            }
        }
    }

    /// Every tile nearer than the exact radius, in inputs distances, is
    /// asked for exactly, whatever the tilt.
    func testTilesWithinTheExactRadiusAreExact() {
        for tilt in [30.0, 60.0, 75.0] {
            let inputs = Self.inputs(tilt: tilt)
            let polygon = Self.polygon(tilt: tilt)
            let output = targets(inputs: inputs, polygon: polygon)
            let lookAtWorld = Self.world(ofTilePoint: Self.lookAt)
            let cameraDistance = simd_length(inputs.eye - SIMD3<Double>(lookAtWorld.x, lookAtWorld.y, 0))
            XCTAssertEqual(cameraDistance, 1.2, accuracy: 1e-9)
            var checked = 0
            for tile in Self.leaves(in: polygon) {
                let distance = simd_length(Self.worldCenter(of: tile) - inputs.eye)
                guard distance <= FlatDistanceCoverage.exactRadius * cameraDistance else { continue }
                XCTAssertTrue(output.contains(tile), "tilt \(tilt): \(tile.x)/\(tile.y) at \(distance) is within the exact radius")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 0, "tilt \(tilt)")
        }
    }

    /// The counts the tuned constants give: a few tiles straight down, a
    /// bounded exact zone plus at most the parents' ceiling at a street
    /// tilt, whatever the window's aspect, and a walk of a few hundred
    /// tiles at most.
    func testCountsStayInTheTunedRange() {
        for tilt in [0.0, 30.0, 45.0, 60.0, 70.0, 75.0] {
            for bearing in stride(from: 0.0, through: 150.0, by: 30.0) {
                let aspect = bearing.truncatingRemainder(dividingBy: 60) == 0 ? 1.0 : 1.78
                let coverage = FlatTileCoverage()
                let output = targets(inputs: Self.inputs(tilt: tilt, bearing: bearing),
                                     polygon: Self.polygon(tilt: tilt, bearing: bearing, aspect: aspect),
                                     coverage: coverage)
                let parents = output.filter { $0.z < Self.zoom }.count
                XCTAssertLessThanOrEqual(parents, FlatDistanceCoverage.maximumParents + 4, "tilt \(tilt) bearing \(bearing): parents \(parents)")
                XCTAssertLessThanOrEqual(output.count - parents, 14, "tilt \(tilt) bearing \(bearing): the exact zone is bounded by its radius")
                XCTAssertLessThan(coverage.visitedNodeCount, 400, "tilt \(tilt) bearing \(bearing): the walk stays small")
                if tilt == 0 {
                    XCTAssertLessThanOrEqual(output.count, 6, "tilt \(tilt) bearing \(bearing): \(output.count)")
                    XCTAssertTrue(output.allSatisfy { $0.z == Self.zoom }, "tilt \(tilt) bearing \(bearing): straight down everything is exact")
                }
                if tilt >= 70 {
                    XCTAssertGreaterThanOrEqual(output.count, 8, "tilt \(tilt) bearing \(bearing): \(output.count)")
                }
            }
        }
    }

    /// A coarse parent that contains an exact tile is placed next to it:
    /// overlaps are allowed instead of climbing.
    func testCoarseParentsCoexistWithExactTiles() {
        let output = targets(inputs: Self.inputs(tilt: 75), polygon: Self.polygon(tilt: 75))
        let exact = output.filter { $0.z == Self.zoom }
        let coarse = output.filter { $0.z < Self.zoom }
        XCTAssertFalse(exact.isEmpty)
        XCTAssertFalse(coarse.isEmpty)
        XCTAssertTrue(coarse.contains { parent in exact.contains { parent.tile.covers($0.tile) } },
                      "Some coarse parent contains an exact tile: \(coarse) over \(exact)")
    }

    /// Past the ceiling the farthest parents go: every kept target starts
    /// nearer the eye than any tile left to the backdrop.
    func testTheCeilingTrimsOnlyTheFarthest() {
        // A full disc of tiles around the eye, far more than the ceiling,
        // with the reach pushed past the disc so the ceiling is what cuts.
        var inputs = Self.inputs(tilt: 75)
        inputs.farRadius = 100
        let eye = inputs.eyeGround
        let polygon = Self.square(minX: eye.x - 40, minY: eye.y - 40, maxX: eye.x + 40, maxY: eye.y + 40)
        let output = targets(inputs: inputs, polygon: polygon)
        let lookAtWorld = Self.world(ofTilePoint: Self.lookAt)
        let cameraDistance = simd_length(inputs.eye - SIMD3<Double>(lookAtWorld.x, lookAtWorld.y, 0))
        let parents = output.filter { $0.z < Self.zoom }.count
        XCTAssertGreaterThanOrEqual(parents, FlatDistanceCoverage.maximumParents)
        XCTAssertLessThanOrEqual(parents, FlatDistanceCoverage.maximumParents + 4, "at most a tie group past the ceiling")
        let leaves = Self.leaves(in: polygon)
        for tile in leaves where simd_length(Self.worldCenter(of: tile) - inputs.eye) <= FlatDistanceCoverage.exactRadius * cameraDistance {
            XCTAssertTrue(output.contains(tile), "the exact zone is never trimmed")
        }
        var farthestKept = 0.0
        var nearestDropped = Double.infinity
        for tile in leaves {
            let distance = simd_length(Self.worldCenter(of: tile) - inputs.eye)
            let zoom = tile.z - FlatDistanceCoverage.drop(distance: distance, cameraDistance: cameraDistance)
            guard zoom > TileCulling.flatBackdropZoomLevel else { continue }
            if Self.cover(of: tile, in: output) != nil {
                farthestKept = max(farthestKept, distance)
            } else {
                nearestDropped = min(nearestDropped, distance)
            }
        }
        XCTAssertLessThan(nearestDropped, .infinity, "Something was trimmed")
        XCTAssertLessThanOrEqual(farthestKept, nearestDropped * 1.5,
                                 "The trimmed tiles are the farthest, allowing for a parent spanning both sides of the cut")
    }

    /// Beyond the reach nothing is placed at any zoom, the backdrop paints
    /// the ground; within it the levels are as before. Without a backdrop
    /// the reach does not apply.
    func testBeyondTheReachNothingIsPlaced() {
        var inputs = Self.inputs(tilt: 75)
        // A street tilt's frustum, which runs to the horizon.
        let polygon = Self.polygon(tilt: 75)
        let leaves = Self.leaves(in: polygon)
        let lookAtWorld = Self.world(ofTilePoint: Self.lookAt)
        let cameraDistance = simd_length(inputs.eye - SIMD3<Double>(lookAtWorld.x, lookAtWorld.y, 0))
        inputs.farRadius = 6
        let output = targets(inputs: inputs, polygon: polygon)
        var coveredBeyond = 0
        var uncoveredWithin = 0
        for tile in leaves {
            let distance = simd_length(Self.worldCenter(of: tile) - inputs.eye)
            let zoom = tile.z - FlatDistanceCoverage.drop(distance: distance, cameraDistance: cameraDistance)
            let covered = Self.cover(of: tile, in: output) != nil
            if distance > inputs.farRadius * cameraDistance * 1.05, covered {
                // A parent placed for nearer ground may reach over the line;
                // a tile beyond it never earns a placement itself.
                XCTAssertTrue(output.contains { $0.z < Self.zoom && $0.tile.covers(tile.tile) },
                              "beyond the reach only nearer ground's parent covers a tile")
                coveredBeyond += 1
            }
            if distance < inputs.farRadius * cameraDistance * 0.95, zoom > TileCulling.flatBackdropZoomLevel, covered == false {
                uncoveredWithin += 1
            }
        }
        XCTAssertEqual(uncoveredWithin, 0, "within the reach every tile the backdrop does not own is covered")
        XCTAssertLessThan(output.filter { $0.z < Self.zoom }.count, FlatDistanceCoverage.maximumParents,
                          "at a reach of 6 the ceiling is never reached")
        XCTAssertGreaterThan(leaves.count - coveredBeyond, 0)

        // No backdrop: the reach is ignored, the far ground stays covered.
        inputs.backdropZoom = nil
        let uncut = targets(inputs: inputs, polygon: polygon)
        for tile in leaves {
            XCTAssertNotNil(Self.cover(of: tile, in: uncut), "without a backdrop every tile stays covered")
        }
    }

    func testTheReachKnobIsClamped() {
        XCTAssertEqual(FlatDistanceCoverage.clampFarRadius(1), FlatDistanceCoverage.farRadiusRange.lowerBound)
        XCTAssertEqual(FlatDistanceCoverage.clampFarRadius(1000), FlatDistanceCoverage.farRadiusRange.upperBound)
        XCTAssertEqual(FlatDistanceCoverage.clampFarRadius(.nan), FlatDistanceCoverage.farRadius)
        let controls = DebugOverlayControlState()
        XCTAssertEqual(controls.snapshot().coverageFarRadiusCameraDistances, Float(FlatDistanceCoverage.farRadius))
        controls.setCoverageFarRadiusCameraDistances(7)
        XCTAssertEqual(controls.snapshot().coverageFarRadiusCameraDistances, 7)
        controls.setCoverageFarRadiusCameraDistances(0)
        XCTAssertEqual(controls.snapshot().coverageFarRadiusCameraDistances, Float(FlatDistanceCoverage.farRadiusRange.lowerBound))
    }

    /// A tile changes level only once its distance has crossed the
    /// threshold by the hysteresis margin, in either direction.
    func testHysteresisHoldsALevelNearItsThreshold() {
        let cameraDistance = 1.2
        let threshold = FlatDistanceCoverage.threshold(ofLevel: 1, cameraDistance: cameraDistance)
        XCTAssertEqual(FlatDistanceCoverage.drop(distance: threshold * 0.99, cameraDistance: cameraDistance), 0)
        XCTAssertEqual(FlatDistanceCoverage.drop(distance: threshold * 1.01, cameraDistance: cameraDistance), 1)
        // Coarsening: just past the threshold the previous level holds.
        XCTAssertEqual(FlatDistanceCoverage.settledDrop(raw: 1, previous: 0, distance: threshold * 1.05, cameraDistance: cameraDistance), 0)
        XCTAssertEqual(FlatDistanceCoverage.settledDrop(raw: 1, previous: 0, distance: threshold * 1.15, cameraDistance: cameraDistance), 1)
        // Refining: just under the threshold the coarser level holds.
        XCTAssertEqual(FlatDistanceCoverage.settledDrop(raw: 0, previous: 1, distance: threshold * 0.95, cameraDistance: cameraDistance), 1)
        XCTAssertEqual(FlatDistanceCoverage.settledDrop(raw: 0, previous: 1, distance: threshold * 0.85, cameraDistance: cameraDistance), 0)
        // A jump of two levels settles as far as the margins allow.
        let second = FlatDistanceCoverage.threshold(ofLevel: 2, cameraDistance: cameraDistance)
        XCTAssertEqual(FlatDistanceCoverage.settledDrop(raw: 2, previous: 0, distance: second * 1.05, cameraDistance: cameraDistance), 1)
        XCTAssertEqual(FlatDistanceCoverage.settledDrop(raw: 2, previous: 0, distance: second * 1.15, cameraDistance: cameraDistance), 2)
        XCTAssertEqual(FlatDistanceCoverage.settledDrop(raw: 0, previous: 0, distance: 1, cameraDistance: cameraDistance), 0)
        XCTAssertEqual(FlatDistanceCoverage.settledDrop(raw: 3, previous: nil, distance: 100, cameraDistance: cameraDistance), 3)
    }

    /// The eye straight above a point `eyeDistance` tiles east of a tile's
    /// centre, at the inputs distance: the inputs looks straight down at
    /// the point under it, so its own distance is its height and the tile
    /// is `eyeDistance` away.
    private static func sideInputs(tile: VisibleTile, eyeDistance: Double, cameraDistance: Double = 1.2) -> FlatCoverageInputs {
        let tileCenter = worldCenter(of: tile)
        let horizontal = (eyeDistance * eyeDistance - cameraDistance * cameraDistance).squareRoot()
        let eye = SIMD3<Double>(tileCenter.x + horizontal, tileCenter.y, cameraDistance)
        let lookAt = SIMD2<Double>(Double(tile.x) + 0.5 + horizontal, Double(tile.y) + 0.5)
        return FlatCoverageInputs(eye: eye, flatRenderState: flatRenderState, eyeGround: lookAt, lookAt: lookAt)
    }

    /// The memory works through the walk: a tile just past its threshold
    /// keeps the level it had the frame before, and a tile held a level
    /// coarser is covered by the parent it holds.
    func testTheLevelMemoryHoldsAcrossFrames() {
        let coverage = FlatTileCoverage()
        let tile = VisibleTile(x: 256, y: 250, z: Self.zoom)
        let polygon = Self.square(minX: 256.1, minY: 250.1, maxX: 256.9, maxY: 250.9)
        let threshold = FlatDistanceCoverage.threshold(ofLevel: 1, cameraDistance: 1.2)
        func output(eyeDistance: Double) -> [VisibleTile] {
            coverage.targets(targetZoom: Self.zoom, inputs: Self.sideInputs(tile: tile, eyeDistance: eyeDistance), polygon: polygon)
        }
        XCTAssertTrue(output(eyeDistance: threshold * 0.9).contains(tile))
        XCTAssertTrue(output(eyeDistance: threshold * 1.05).contains(tile),
                      "Just past the threshold the tile keeps its exact level")
        let dropped = output(eyeDistance: threshold * 1.15)
        XCTAssertFalse(dropped.contains(tile), "Well past it the tile drops a level")
        XCTAssertNotNil(Self.cover(of: tile, in: dropped), "and its parent covers it")
        let held = output(eyeDistance: threshold * 0.95)
        XCTAssertFalse(held.contains(tile), "Coming back, the coarser level holds until the margin is crossed")
        XCTAssertNotNil(Self.cover(of: tile, in: held), "and the held parent is placed for it")
        XCTAssertTrue(output(eyeDistance: threshold * 0.85).contains(tile))
    }

    /// The level memory belongs to one target zoom and to tiles that stay
    /// visible: a zoom change forgets it, and so does a frame without the
    /// tile.
    func testTheLevelMemoryIsForgottenOnAZoomChangeAndOnAbsence() {
        let coverage = FlatTileCoverage()
        let tile = VisibleTile(x: 256, y: 250, z: Self.zoom)
        let polygon = Self.square(minX: 256.1, minY: 250.1, maxX: 256.9, maxY: 250.9)
        let threshold = FlatDistanceCoverage.threshold(ofLevel: 1, cameraDistance: 1.2)
        func output(eyeDistance: Double, targetZoom: Int = Self.zoom, polygon: CoveragePolygon = polygon) -> [VisibleTile] {
            coverage.targets(targetZoom: targetZoom, inputs: Self.sideInputs(tile: tile, eyeDistance: eyeDistance), polygon: polygon)
        }
        XCTAssertTrue(output(eyeDistance: threshold * 0.9).contains(tile))
        XCTAssertTrue(output(eyeDistance: threshold * 1.05).contains(tile), "held by the memory")
        // A frame at another target zoom forgets the memory.
        _ = output(eyeDistance: threshold * 0.9, targetZoom: Self.zoom - 1)
        XCTAssertFalse(output(eyeDistance: threshold * 1.05).contains(tile), "after a zoom change the raw level applies")
        // Back exact, then a frame without the tile forgets it too.
        XCTAssertTrue(output(eyeDistance: threshold * 0.85).contains(tile))
        _ = output(eyeDistance: threshold * 0.85, polygon: Self.square(minX: 300.1, minY: 300.1, maxX: 300.9, maxY: 300.9))
        XCTAssertFalse(output(eyeDistance: threshold * 1.05).contains(tile), "absent for a frame, the tile starts from its raw level")
    }

    /// Past the source's deepest zoom the tiles keep doubling in the world
    /// while the inputs's distance does not: measured in the tiles' own
    /// scale, the view straight down stays exact at any overzoom.
    func testOverzoomKeepsTheNearTilesExact() {
        let polygon = Self.square(minX: 255.1, minY: 249.1, maxX: 256.9, maxY: 250.9)
        var expected: Set<VisibleTile> = []
        for column in 0 ... 1 {
            for row in 0 ... 1 {
                expected.insert(VisibleTile(x: 255 + column, y: 249 + row, z: Self.zoom))
            }
        }
        var inputs = Self.inputs(tilt: 0, distance: 1.2 / 16)
        XCTAssertNotEqual(Set(targets(inputs: inputs, polygon: polygon)), expected,
                          "Without the overzoom scale the tiles read as sixteen inputs distances away")
        inputs.overzoomLevels = 4
        XCTAssertEqual(Set(targets(inputs: inputs, polygon: polygon)), expected)
    }

    /// The far rows whose parents would be the backdrop's zoom or coarser
    /// are not placed: the z3 backdrop paints them.
    func testTheFarFieldIsHandedToTheBackdrop() {
        let zoom = 6
        let state = FlatRenderState(pan: .zero, renderMapSize: Double(1 << zoom))
        let lookAt = SIMD2<Double>(32.5, 30.5)
        func world(_ point: SIMD2<Double>) -> SIMD2<Float> {
            let world = FlatDistanceCoverage.worldPoint(ofTilePoint: point, zoom: zoom, flatRenderState: state)
            return SIMD2<Float>(Float(world.x), Float(world.y))
        }
        // A thin wedge north, thirty rows out, seen from a street tilt
        // straight above a point 1.1 tiles south of the look-at, 0.3 up.
        let polygon = CoveragePolygon(vertices: [world(SIMD2<Double>(32.2, 32.5)), world(SIMD2<Double>(32.8, 32.5)),
                                                 world(SIMD2<Double>(32.8, -1)), world(SIMD2<Double>(32.2, -1))])
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: 32, y: 31, z: zoom, loop: 0,
                                                                  flatRenderPan: state.pan, renderMapSize: state.renderMapSize)
        let eye = SIMD3<Double>(Double(origin.x) + 0.5, Double(origin.y) + 0.4, 0.3)
        let inputs = FlatCoverageInputs(eye: eye, flatRenderState: state, eyeGround: lookAt + SIMD2<Double>(0, 1.1), lookAt: lookAt)
        let output = FlatTileCoverage().targets(targetZoom: zoom, inputs: inputs, polygon: polygon)
        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(output.allSatisfy { $0.z > TileCulling.flatBackdropZoomLevel },
                      "Nothing at the backdrop's zoom or coarser is placed: \(output)")
        XCTAssertNil(Self.cover(of: VisibleTile(x: 32, y: 0, z: zoom), in: output), "Thirty rows out belongs to the backdrop")
    }

    /// Without a backdrop nothing is trimmed and every level clamps to z0:
    /// a shallow world seen at a steep tilt still paints its wrapped copy.
    func testWithoutABackdropEverythingStaysCovered() {
        let zoom = 1
        let state = FlatRenderState(pan: .zero, renderMapSize: Double(1 << zoom))
        let lookAt = SIMD2<Double>(0.5, 0.5)
        // The whole world and its eastern copy.
        let polygon = CoveragePolygon(vertices: [SIMD2<Float>(-1.1, -1.1), SIMD2<Float>(3.1, -1.1),
                                                 SIMD2<Float>(3.1, 1.1), SIMD2<Float>(-1.1, 1.1)])
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: 0, y: 0, z: zoom, loop: 0,
                                                                  flatRenderPan: state.pan, renderMapSize: state.renderMapSize)
        let eye = SIMD3<Double>(Double(origin.x) - 0.6, Double(origin.y) + 0.5, 0.2)
        let inputs = FlatCoverageInputs(eye: eye, flatRenderState: state,
                                        eyeGround: lookAt + SIMD2<Double>(-1.1, 0), lookAt: lookAt,
                                        backdropZoom: nil)
        let output = FlatTileCoverage().targets(targetZoom: zoom, inputs: inputs, polygon: polygon)
        for loop: Int8 in [0, 1] {
            for x in 0 ... 1 {
                for y in 0 ... 1 {
                    let tile = VisibleTile(x: x, y: y, z: zoom, loop: loop)
                    XCTAssertNotNil(Self.cover(of: tile, in: output), "\(tile) is covered in its own world copy: \(output)")
                }
            }
        }
        XCTAssertEqual(Set(output).count, output.count, "no duplicate targets")
    }

    /// The backdrop is the coarse tiles under the whole footprint, in a
    /// stable order.
    func testTheBackdropEnumeratesTheFootprintAtItsZoom() {
        let polygon = Self.polygon(tilt: 75)
        let backdrop = FlatTileCoverage.tiles(atZoom: 3, polygon: polygon, flatRenderState: Self.flatRenderState)
        XCTAssertFalse(backdrop.isEmpty)
        XCTAssertTrue(backdrop.allSatisfy { $0.z == 3 })
        for leaf in Self.leaves(in: polygon) {
            XCTAssertNotNil(Self.cover(of: leaf, in: backdrop), "\(leaf) is under a backdrop tile")
        }
        XCTAssertEqual(backdrop, FlatTileCoverage.tiles(atZoom: 3, polygon: polygon, flatRenderState: Self.flatRenderState),
                       "deterministic")
    }
}
