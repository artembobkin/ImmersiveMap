// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The preprocessor's LOD. On the plane every tile's zoom follows its
/// distance from the eye (`FlatDistanceCoverage`): exact within the exact
/// radius, one level per `1 / steepness` doublings beyond, overlaps
/// allowed, the farthest parents trimmed to the ceiling, the rest of the
/// far field handed to the z3 horizon backdrop. On the sphere the distance
/// ladder stays (steepness 1.5): 0-2 exact, 3 → z-1, 4-5 → z-2, 6-8 → z-3,
/// 9+ → z-4, beyond distance 15 the preference clamps to the z3 backdrop
/// zoom.
final class VisibleTilesPreprocessorDistanceLodTests: XCTestCase {
    private let preprocessor = VisibleTilesPreprocessor()
    /// A z9 world whose tiles are one world unit wide, so distances read in
    /// tiles.
    private static let zoom = 9
    private static let flatRenderState = FlatRenderState(pan: .zero, renderMapSize: Double(1 << zoom))
    private static let lookAt = SIMD2<Double>(256.5, 250.5)
    private static var center: Center {
        Center(tileX: lookAt.x, tileY: lookAt.y)
    }

    /// The world position of a point in tile units (tile y grows south,
    /// world y north).
    private static func world(ofTilePoint point: SIMD2<Double>) -> SIMD2<Double> {
        let tile = VisibleTile(x: Int(floor(point.x)), y: Int(floor(point.y)), z: zoom)
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x, y: tile.y, z: tile.z, loop: 0,
                                                                  flatRenderPan: flatRenderState.pan,
                                                                  renderMapSize: flatRenderState.renderMapSize)
        let size = Double(origin.z)
        return SIMD2<Double>(Double(origin.x) + (point.x - floor(point.x)) * size,
                             Double(origin.y) + (1 - (point.y - floor(point.y))) * size)
    }

    private static func worldCenter(of tile: VisibleTile) -> SIMD3<Double> {
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x, y: tile.y, z: tile.z, loop: tile.loop,
                                                                  flatRenderPan: flatRenderState.pan,
                                                                  renderMapSize: flatRenderState.renderMapSize)
        return SIMD3<Double>(Double(origin.x) + Double(origin.z) / 2, Double(origin.y) + Double(origin.z) / 2, 0)
    }

    /// A camera `distance` tiles from the look-at point, pitched `tilt`
    /// degrees, turned to `bearing` degrees (0 looks north, 90 east).
    private static func camera(tilt: Double, bearing: Double = 0, distance: Double = 1.2) -> FlatCoverageCamera {
        let radians = bearing * .pi / 180
        // Forward on the ground in tile units: north is -y, east is +x.
        let forward = SIMD2<Double>(sin(radians), -cos(radians))
        let behind = distance * sin(tilt * .pi / 180)
        let eyeGround = lookAt - forward * behind
        let eyeGroundWorld = world(ofTilePoint: eyeGround)
        let eye = SIMD3<Double>(eyeGroundWorld.x, eyeGroundWorld.y, distance * cos(tilt * .pi / 180))
        return FlatCoverageCamera(eye: eye, flatRenderState: flatRenderState, eyeGround: eyeGround, lookAt: lookAt)
    }

    /// The tiles a square 45 degree frustum sees from that camera: the
    /// ground the wedge covers, sampled and snapped to tiles, so a turned
    /// view cuts the tile grid diagonally the way a real camera does.
    /// How far ahead of the eye's ground point a 45 degree frustum at
    /// `tilt` reaches: the far edge of the view, or 40 tiles once it looks
    /// past the horizon.
    private static func reach(tilt: Double, distance: Double = 1.2) -> Double {
        let radians = tilt * .pi / 180
        let farEdge = radians + .pi / 8
        guard farEdge < 89 * .pi / 180 else { return 40 }
        return min(40, distance * cos(radians) * tan(farEdge) - distance * sin(radians) + 0.5)
    }

    private static func frustumTiles(tilt: Double, bearing: Double = 0, distance: Double = 1.2, reach: Double? = nil,
                                     aspect: Double = 1) -> [VisibleTile] {
        let reach = reach ?? Self.reach(tilt: tilt, distance: distance)
        let radians = bearing * .pi / 180
        let forward = SIMD2<Double>(sin(radians), -cos(radians))
        let right = SIMD2<Double>(-forward.y, forward.x)
        let behind = distance * sin(tilt * .pi / 180)
        let eyeGround = lookAt - forward * behind
        var seen: Set<VisibleTile> = []
        var tiles: [VisibleTile] = []
        var ahead = 0.25
        while ahead <= reach {
            let halfWidth = ahead * tan(Double.pi / 8) * aspect + 0.5
            var lateral = -halfWidth
            while lateral <= halfWidth {
                let point = eyeGround + forward * ahead + right * lateral
                let tile = VisibleTile(x: Int(floor(point.x)), y: Int(floor(point.y)), z: zoom)
                if seen.insert(tile).inserted {
                    tiles.append(tile)
                }
                lateral += 0.25
            }
            ahead += 0.25
        }
        return tiles
    }

    private func flatTargets(_ tiles: [VisibleTile], camera: FlatCoverageCamera) -> [VisibleTile] {
        preprocessor.preprocess(visibleTiles: tiles,
                                center: Self.center,
                                renderSurfaceMode: .flat,
                                transition: 1,
                                flatCamera: camera)
    }

    private static func cover(of tile: VisibleTile, in output: [VisibleTile]) -> VisibleTile? {
        output.first { $0.loop == tile.loop && ($0.tile == tile.tile || $0.tile.covers(tile.tile)) }
    }

    /// Straight down the whole view is within the exact radius: every tile
    /// exact, nothing else.
    func testTopDownIsExact() {
        var tiles: [VisibleTile] = []
        for column in 0 ... 1 {
            for row in 0 ... 1 {
                tiles.append(VisibleTile(x: 255 + column, y: 249 + row, z: Self.zoom))
            }
        }
        let output = flatTargets(tiles, camera: Self.camera(tilt: 0))
        XCTAssertEqual(Set(output), Set(tiles))
    }

    /// Two tiles at the same distance get the same zoom: looking north, the
    /// view is mirror-symmetric about its axis, and so is every tile's own
    /// level, and the parent at that level is placed on both sides. (A
    /// parent's outline is not mirrored about the axis, so a neighbouring
    /// finer parent may reach over one side and not the other, which only
    /// ever adds detail; and at the ceiling's cut one of two equally far
    /// parents can be the one starting nearer.) Checked at the tilts the
    /// ceiling leaves alone.
    func testMirroredTilesGetTheSameZoom() {
        var tiltsCompared = 0
        for tilt in [30.0, 45.0, 55.0, 60.0] {
            let tiles = Self.frustumTiles(tilt: tilt)
            let visible = Set(tiles)
            let camera = Self.camera(tilt: tilt)
            let output = VisibleTilesPreprocessor().preprocess(visibleTiles: tiles, center: Self.center, renderSurfaceMode: .flat,
                                                               transition: 1, flatCamera: camera)
            guard output.filter({ $0.z < Self.zoom }).count < FlatDistanceCoverage.maximumParents else { continue }
            tiltsCompared += 1
            let lookAtWorld = Self.world(ofTilePoint: Self.lookAt)
            let cameraDistance = simd_length(camera.eye - SIMD3<Double>(lookAtWorld.x, lookAtWorld.y, 0))
            func level(_ tile: VisibleTile) -> Int {
                tile.z - FlatDistanceCoverage.drop(distance: simd_length(Self.worldCenter(of: tile) - camera.eye),
                                                   cameraDistance: cameraDistance)
            }
            var compared = 0
            for tile in tiles {
                let mirror = VisibleTile(x: 512 - tile.x, y: tile.y, z: Self.zoom)
                guard visible.contains(mirror) else { continue }
                XCTAssertEqual(level(tile), level(mirror), "tilt \(tilt): \(tile.x)/\(tile.y) and its mirror \(mirror.x)/\(mirror.y) differ in level")
                XCTAssertEqual(output.contains(tile), output.contains(mirror), "tilt \(tilt): exact on one side only")
                for candidate in [tile, mirror] {
                    let own = candidate.tile.findParentTile(atZoom: level(candidate)) ?? candidate.tile
                    XCTAssertTrue(output.contains { $0.tile == own }, "tilt \(tilt): \(candidate.x)/\(candidate.y) has its own-level parent placed")
                }
                compared += 1
            }
            XCTAssertGreaterThan(compared, 4, "tilt \(tilt)")
        }
        XCTAssertGreaterThanOrEqual(tiltsCompared, 2, "Some tilts stay under the ceiling")
    }

    /// Every tile nearer than the exact radius, in camera distances, is
    /// asked for exactly, whatever the tilt.
    func testTilesWithinTheExactRadiusAreExact() {
        for tilt in [30.0, 60.0, 75.0] {
            let camera = Self.camera(tilt: tilt)
            let tiles = Self.frustumTiles(tilt: tilt)
            let output = flatTargets(tiles, camera: camera)
            let lookAtWorld = Self.world(ofTilePoint: Self.lookAt)
            let cameraDistance = simd_length(camera.eye - SIMD3<Double>(lookAtWorld.x, lookAtWorld.y, 0))
            XCTAssertEqual(cameraDistance, 1.2, accuracy: 1e-9)
            var checked = 0
            for tile in tiles {
                let distance = simd_length(Self.worldCenter(of: tile) - camera.eye)
                guard distance <= FlatDistanceCoverage.exactRadius * cameraDistance else { continue }
                XCTAssertTrue(output.contains(tile), "tilt \(tilt): \(tile.x)/\(tile.y) at \(distance) is within the exact radius")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 0, "tilt \(tilt)")
        }
    }

    /// The counts the tuned constants give: a few tiles straight down, a
    /// bounded exact zone plus at most the parents' ceiling at a street
    /// tilt, whatever the window's aspect.
    func testCountsStayInTheTunedRange() {
        for tilt in [0.0, 30.0, 45.0, 60.0, 70.0, 75.0] {
            for bearing in stride(from: 0.0, through: 150.0, by: 30.0) {
                let aspect = bearing.truncatingRemainder(dividingBy: 60) == 0 ? 1.0 : 1.78
                let output = flatTargets(Self.frustumTiles(tilt: tilt, bearing: bearing, aspect: aspect), camera: Self.camera(tilt: tilt, bearing: bearing))
                let parents = output.filter { $0.z < Self.zoom }.count
                XCTAssertLessThanOrEqual(parents, FlatDistanceCoverage.maximumParents + 4, "tilt \(tilt) bearing \(bearing): parents \(parents)")
                XCTAssertLessThanOrEqual(output.count - parents, 12, "tilt \(tilt) bearing \(bearing): the exact zone is bounded by its radius")
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

    /// Past the ceiling the farthest parents go: every kept target starts
    /// nearer the eye than any tile left to the backdrop.
    func testTheCeilingTrimsOnlyTheFarthest() {
        // A full disc of tiles around the eye, far more than the ceiling.
        let camera = Self.camera(tilt: 75)
        let eye = camera.eyeGround
        var tiles: [VisibleTile] = []
        for row in -40 ... 40 {
            for column in -40 ... 40 {
                let tile = VisibleTile(x: Int(floor(eye.x)) + column, y: Int(floor(eye.y)) + row, z: Self.zoom)
                if simd_length(SIMD2<Double>(Double(column), Double(row))) <= 40 {
                    tiles.append(tile)
                }
            }
        }
        let output = flatTargets(tiles, camera: camera)
        let lookAtWorld = Self.world(ofTilePoint: Self.lookAt)
        let cameraDistance = simd_length(camera.eye - SIMD3<Double>(lookAtWorld.x, lookAtWorld.y, 0))
        let parents = output.filter { $0.z < Self.zoom }.count
        XCTAssertGreaterThanOrEqual(parents, FlatDistanceCoverage.maximumParents)
        XCTAssertLessThanOrEqual(parents, FlatDistanceCoverage.maximumParents + 4, "at most a tie group past the ceiling")
        for tile in tiles where simd_length(Self.worldCenter(of: tile) - camera.eye) <= FlatDistanceCoverage.exactRadius * cameraDistance {
            XCTAssertTrue(output.contains(tile), "the exact zone is never trimmed")
        }
        var farthestKept = 0.0
        var nearestDropped = Double.infinity
        for tile in tiles {
            let distance = simd_length(Self.worldCenter(of: tile) - camera.eye)
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

    /// The memory works through the preprocessor: a tile just past its
    /// threshold keeps the level it had the frame before.
    func testTheLevelMemoryHoldsAcrossFrames() {
        let tile = VisibleTile(x: 256, y: 250, z: Self.zoom)
        let cameraDistance = 1.2
        let threshold = FlatDistanceCoverage.threshold(ofLevel: 1, cameraDistance: cameraDistance)
        func camera(eyeDistance: Double) -> FlatCoverageCamera {
            // The eye straight above a point `eyeDistance` tiles east of the
            // tile's centre, at the camera distance.
            let tileCenter = Self.worldCenter(of: tile)
            let horizontal = (eyeDistance * eyeDistance - cameraDistance * cameraDistance).squareRoot()
            let eye = SIMD3<Double>(tileCenter.x + horizontal, tileCenter.y, cameraDistance)
            // The camera looks straight down at the point under it, so its
            // own distance is its height and the tile is `eyeDistance` away.
            return FlatCoverageCamera(eye: eye, flatRenderState: Self.flatRenderState,
                                      eyeGround: SIMD2<Double>(256.5 + horizontal, 250.5),
                                      lookAt: SIMD2<Double>(256.5 + horizontal, 250.5))
        }
        XCTAssertTrue(flatTargets([tile], camera: camera(eyeDistance: threshold * 0.9)).contains(tile))
        XCTAssertTrue(flatTargets([tile], camera: camera(eyeDistance: threshold * 1.05)).contains(tile),
                      "Just past the threshold the tile keeps its exact level")
        XCTAssertFalse(flatTargets([tile], camera: camera(eyeDistance: threshold * 1.15)).contains(tile),
                       "Well past it the tile drops a level")
        XCTAssertFalse(flatTargets([tile], camera: camera(eyeDistance: threshold * 0.95)).contains(tile),
                       "Coming back, the coarser level holds until the margin is crossed")
        XCTAssertTrue(flatTargets([tile], camera: camera(eyeDistance: threshold * 0.85)).contains(tile))
    }

    /// Past the source's deepest zoom the tiles keep doubling in the world
    /// while the camera's distance does not: measured in the tiles' own
    /// scale, the view straight down stays exact at any overzoom.
    func testOverzoomKeepsTheNearTilesExact() {
        // Four levels of overzoom: the z9 tiles are 16 times larger than the
        // camera's distance would suggest, and the 2 by 2 block under the
        // camera is still the finest the source has.
        var tiles: [VisibleTile] = []
        for column in 0 ... 1 {
            for row in 0 ... 1 {
                tiles.append(VisibleTile(x: 255 + column, y: 249 + row, z: Self.zoom))
            }
        }
        var camera = Self.camera(tilt: 0, distance: 1.2 / 16)
        XCTAssertFalse(flatTargets(tiles, camera: camera).count == tiles.count && flatTargets(tiles, camera: camera).allSatisfy { $0.z == Self.zoom },
                       "Without the overzoom scale the tiles read as sixteen camera distances away")
        camera.overzoomLevels = 4
        let output = VisibleTilesPreprocessor().preprocess(visibleTiles: tiles, center: Self.center, renderSurfaceMode: .flat,
                                                           transition: 1, flatCamera: camera)
        XCTAssertEqual(Set(output), Set(tiles))
    }

    /// The level memory belongs to one target zoom and to tiles that stay
    /// visible: a zoom change forgets it, and so does a frame without the
    /// tile.
    func testTheLevelMemoryIsForgottenOnAZoomChangeAndOnAbsence() {
        let coverage = FlatDistanceCoverage()
        let tile = VisibleTile(x: 256, y: 250, z: Self.zoom)
        let cameraDistance = 1.2
        let threshold = FlatDistanceCoverage.threshold(ofLevel: 1, cameraDistance: cameraDistance)
        func camera(eyeDistance: Double) -> FlatCoverageCamera {
            let tileCenter = Self.worldCenter(of: tile)
            let horizontal = (eyeDistance * eyeDistance - cameraDistance * cameraDistance).squareRoot()
            return FlatCoverageCamera(eye: SIMD3<Double>(tileCenter.x + horizontal, tileCenter.y, cameraDistance),
                                      flatRenderState: Self.flatRenderState,
                                      eyeGround: SIMD2<Double>(256.5 + horizontal, 250.5),
                                      lookAt: SIMD2<Double>(256.5 + horizontal, 250.5))
        }
        XCTAssertTrue(coverage.targets(visibleTiles: [tile], camera: camera(eyeDistance: threshold * 0.9), backdropZoom: 3).contains(tile))
        XCTAssertTrue(coverage.targets(visibleTiles: [tile], camera: camera(eyeDistance: threshold * 1.05), backdropZoom: 3).contains(tile),
                      "held by the memory")
        // A frame at another target zoom forgets the memory.
        let otherZoom = VisibleTile(x: 128, y: 125, z: Self.zoom - 1)
        _ = coverage.targets(visibleTiles: [otherZoom], camera: camera(eyeDistance: threshold * 0.9), backdropZoom: 3)
        XCTAssertFalse(coverage.targets(visibleTiles: [tile], camera: camera(eyeDistance: threshold * 1.05), backdropZoom: 3).contains(tile),
                       "after a zoom change the raw level applies")
        // Back exact, then a frame without the tile forgets it too.
        XCTAssertTrue(coverage.targets(visibleTiles: [tile], camera: camera(eyeDistance: threshold * 0.85), backdropZoom: 3).contains(tile))
        _ = coverage.targets(visibleTiles: [VisibleTile(x: 300, y: 300, z: Self.zoom)], camera: camera(eyeDistance: threshold * 0.85), backdropZoom: 3)
        XCTAssertFalse(coverage.targets(visibleTiles: [tile], camera: camera(eyeDistance: threshold * 1.05), backdropZoom: 3).contains(tile),
                       "absent for a frame, the tile starts from its raw level")
    }

    /// A coarse parent that contains an exact tile is placed next to it:
    /// overlaps are allowed instead of climbing.
    func testCoarseParentsCoexistWithExactTiles() {
        let camera = Self.camera(tilt: 75)
        let tiles = Self.frustumTiles(tilt: 75)
        let output = flatTargets(tiles, camera: camera)
        let exact = output.filter { $0.z == Self.zoom }
        let coarse = output.filter { $0.z < Self.zoom }
        XCTAssertFalse(exact.isEmpty)
        XCTAssertFalse(coarse.isEmpty)
        XCTAssertTrue(coarse.contains { parent in exact.contains { parent.tile.covers($0.tile) } },
                      "Some coarse parent contains an exact tile: \(coarse) over \(exact)")
    }

    /// The far rows whose parents would be the backdrop's zoom or coarser
    /// are not placed: the z3 backdrop paints them.
    func testTheFarFieldIsHandedToTheBackdrop() {
        let zoom = 6
        let state = FlatRenderState(pan: .zero, renderMapSize: Double(1 << zoom))
        let lookAt = SIMD2<Double>(32.5, 30.5)
        // Straight above a point 1.1 tiles south of the look-at, 0.3 up: a
        // street tilt.
        var tiles: [VisibleTile] = []
        for row in -2 ... 30 {
            tiles.append(VisibleTile(x: 32, y: 30 - row, z: zoom))
        }
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: 32, y: 31, z: zoom, loop: 0,
                                                                  flatRenderPan: state.pan, renderMapSize: state.renderMapSize)
        let eye = SIMD3<Double>(Double(origin.x) + 0.5, Double(origin.y) + 0.4, 0.3)
        let camera = FlatCoverageCamera(eye: eye, flatRenderState: state,
                                        eyeGround: lookAt + SIMD2<Double>(0, 1.1), lookAt: lookAt)
        let output = preprocessor.preprocess(visibleTiles: tiles,
                                             center: Center(tileX: lookAt.x, tileY: lookAt.y),
                                             renderSurfaceMode: .flat,
                                             transition: 1,
                                             flatCamera: camera)
        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(output.allSatisfy { $0.z > TileCulling.flatBackdropZoomLevel },
                      "Nothing at the backdrop's zoom or coarser is placed: \(output)")
        let farRow = VisibleTile(x: 32, y: 0, z: zoom)
        XCTAssertNil(Self.cover(of: farRow, in: output), "Thirty rows out belongs to the backdrop")
    }

    /// Without a backdrop nothing is trimmed and every level clamps to z0:
    /// a shallow world seen at a steep tilt still paints its wrapped copy.
    func testWithoutABackdropEverythingStaysCovered() {
        let zoom = 1
        let state = FlatRenderState(pan: .zero, renderMapSize: Double(1 << zoom))
        let lookAt = SIMD2<Double>(0.5, 0.5)
        var tiles: [VisibleTile] = []
        for loop: Int8 in [0, 1] {
            for x in 0 ... 1 {
                for y in 0 ... 1 {
                    tiles.append(VisibleTile(x: x, y: y, z: zoom, loop: loop))
                }
            }
        }
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: 0, y: 0, z: zoom, loop: 0,
                                                                  flatRenderPan: state.pan, renderMapSize: state.renderMapSize)
        let eye = SIMD3<Double>(Double(origin.x) - 0.6, Double(origin.y) + 0.5, 0.2)
        let camera = FlatCoverageCamera(eye: eye, flatRenderState: state,
                                        eyeGround: lookAt + SIMD2<Double>(-1.1, 0), lookAt: lookAt,
                                        backdropZoom: nil)
        let output = preprocessor.preprocess(visibleTiles: tiles,
                                             center: Center(tileX: lookAt.x, tileY: lookAt.y),
                                             renderSurfaceMode: .flat,
                                             transition: 1,
                                             flatCamera: camera)
        for tile in tiles {
            XCTAssertNotNil(Self.cover(of: tile, in: output), "\(tile) is covered in its own world copy: \(output)")
        }
        XCTAssertEqual(Set(output).count, output.count, "no duplicate targets")
    }

    func testTilesBeyondMaxVisibleDistanceAreDropped() {
        let tile = VisibleTile(x: 41, y: 10, z: 6)
        let state = FlatRenderState(pan: .zero, renderMapSize: 64)
        let output = preprocessor.preprocess(visibleTiles: [tile],
                                             center: Center(tileX: 0.0, tileY: 10.0),
                                             renderSurfaceMode: .flat,
                                             transition: 1,
                                             flatCamera: FlatCoverageCamera(eye: SIMD3<Double>(0, 0, 1), flatRenderState: state,
                                                                            eyeGround: SIMD2<Double>(0, 10), lookAt: SIMD2<Double>(0, 10)))
        XCTAssertTrue(output.isEmpty)
    }

    /// Without a flat camera (the globe never hands one over) a flat tile
    /// is asked for exactly.
    func testFlatWithoutCameraStaysExact() {
        let tile = VisibleTile(x: 5, y: 10, z: 6)
        let output = preprocessor.preprocess(visibleTiles: [tile],
                                             center: Center(tileX: 0.0, tileY: 10.0),
                                             renderSurfaceMode: .flat,
                                             transition: 1)
        XCTAssertEqual(output, [tile])
    }

    /// The spherical ladder stays at steepness 1.5: the globe visuals were
    /// tuned separately and the flat tightening does not touch them.
    /// Row y=31 tiles sit next to the equator, so the latitude drop is zero.
    func testSphericalLadderKeepsGentlerSteepness() {
        let casesByDistance: [(distance: Int, expectedZoom: Int)] = [
            (3, 5),
            (8, 3),
            (20, 2)
        ]

        for testCase in casesByDistance {
            let tile = VisibleTile(x: testCase.distance, y: 31, z: 6)
            let output = preprocessor.preprocess(visibleTiles: [tile],
                                                 center: Center(tileX: 0.0, tileY: 31.0),
                                                 renderSurfaceMode: .spherical,
                                                 transition: 0)

            XCTAssertEqual(output.count, 1, "distance \(testCase.distance)")
            XCTAssertEqual(output.first?.z, testCase.expectedZoom,
                           "distance \(testCase.distance): expected z\(testCase.expectedZoom), got z\(String(describing: output.first?.z))")
        }
    }
}
