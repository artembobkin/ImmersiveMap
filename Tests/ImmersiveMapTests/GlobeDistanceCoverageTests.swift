// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The sphere's coverage rule: the flat distance rule read off the globe,
/// with the pinned world cover as the floor and as the far field.
final class GlobeDistanceCoverageTests: XCTestCase {
    private static let globe = GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0)

    private static func camera(eyeDistance: Float, farRadius: Double = FlatDistanceCoverage.farRadius) -> GlobeCoverageCamera {
        GlobeCoverageCamera(eye: SIMD3<Float>(0, 0, eyeDistance), globe: globe, farRadius: farRadius)
    }

    private static func distance(from camera: GlobeCoverageCamera, to tile: VisibleTile) -> Double {
        let inputs = GlobeVisibilityModel.makeInputs(globe: camera.globe, cameraEye: camera.eye)
        return Double(simd_length(GlobeVisibilityModel.tileBound(tile: tile.tile, inputs: inputs).center - camera.eye))
    }

    /// One row of z6 tiles along the equator, from the front point round to the back.
    private static func equatorRow(zoom: Int = 6) -> [VisibleTile] {
        let count = 1 << zoom
        return (0 ..< count).map { VisibleTile(x: $0, y: count / 2, z: zoom) }
    }

    func testPreferredZoomFollowsTheDistanceFromTheEye() {
        let coverage = GlobeDistanceCoverage()
        let camera = Self.camera(eyeDistance: 0.05)
        let tiles = Self.equatorRow()
        let zooms = coverage.preferredZooms(visibleTiles: tiles, camera: camera)
        XCTAssertEqual(zooms.count, tiles.count)
        let cameraDistance = 0.05
        var sawExact = false
        var sawParent = false
        var sawFloor = false
        for (tile, zoom) in zip(tiles, zooms) {
            let distance = Self.distance(from: camera, to: tile)
            let expected: Int
            if distance > camera.farRadius * cameraDistance {
                expected = GlobeDistanceCoverage.floorZoom
            } else {
                expected = max(GlobeDistanceCoverage.floorZoom,
                               tile.z - FlatDistanceCoverage.drop(distance: distance, cameraDistance: cameraDistance))
            }
            XCTAssertEqual(zoom, expected, "tile x\(tile.x) at \(distance / cameraDistance) camera distances")
            sawExact = sawExact || zoom == tile.z
            sawParent = sawParent || (zoom < tile.z && zoom > GlobeDistanceCoverage.floorZoom)
            sawFloor = sawFloor || zoom == GlobeDistanceCoverage.floorZoom
        }
        XCTAssertTrue(sawExact && sawParent && sawFloor, "the row crosses the exact zone, the ladder and the reach")
    }

    func testTheFloorIsThePinnedCoverAndShallowTargetsStayExact() {
        let coverage = GlobeDistanceCoverage()
        // Close in with a short reach, every z6 tile but the nearest is in
        // the far field: it is asked for at the cover's zoom, never below.
        let far = coverage.preferredZooms(visibleTiles: Self.equatorRow(), camera: Self.camera(eyeDistance: 0.05, farRadius: 3))
        XCTAssertTrue(far.allSatisfy { $0 >= GlobeDistanceCoverage.floorZoom })
        XCTAssertGreaterThan(far.filter { $0 == GlobeDistanceCoverage.floorZoom }.count, far.count / 2)
        // Far away the whole sphere is within the exact zone: seen from
        // afar every tile is scaled alike, and the culling's target zoom is
        // what keeps the count down.
        let afar = coverage.preferredZooms(visibleTiles: Self.equatorRow(), camera: Self.camera(eyeDistance: 4))
        XCTAssertTrue(afar.allSatisfy { $0 == 6 })
        // At the cover's zoom and above it nothing coarsens.
        for zoom in 0 ... GlobeDistanceCoverage.floorZoom {
            let tiles = Self.equatorRow(zoom: zoom)
            XCTAssertEqual(coverage.preferredZooms(visibleTiles: tiles, camera: Self.camera(eyeDistance: 4)), tiles.map(\.z))
        }
        XCTAssertEqual(coverage.preferredZooms(visibleTiles: [], camera: Self.camera(eyeDistance: 1)), [])
    }

    /// The reach holds with the level hysteresis, through the memory: a
    /// tile just past the line keeps its side until the margin is crossed.
    func testTheReachHoldsWithHysteresis() {
        let coverage = GlobeDistanceCoverage()
        let tile = VisibleTile(x: 40, y: 32, z: 6)
        // The reach in world units is farRadius times the eye's distance;
        // the eye moves along the axis, so the tile's distance and the
        // reach both change. Pick far radii that put the line around the tile.
        let eyeDistance: Float = 0.2
        let distance = Self.distance(from: Self.camera(eyeDistance: eyeDistance), to: tile)
        let lineRadius = distance / Double(eyeDistance)
        func zoom(farRadius: Double) -> Int {
            coverage.preferredZooms(visibleTiles: [tile], camera: Self.camera(eyeDistance: eyeDistance, farRadius: farRadius))[0]
        }
        let within = zoom(farRadius: lineRadius * 1.1)
        XCTAssertGreaterThan(within, GlobeDistanceCoverage.floorZoom, "within the reach the tile keeps a level of its own")
        XCTAssertEqual(zoom(farRadius: lineRadius / 1.05), within, "just past the reach the tile keeps its level")
        XCTAssertEqual(zoom(farRadius: lineRadius / 1.15), GlobeDistanceCoverage.floorZoom, "well past it the far field takes it")
        XCTAssertEqual(zoom(farRadius: lineRadius * 1.05), GlobeDistanceCoverage.floorZoom, "coming back, it stays in the far field until the margin is crossed")
        XCTAssertEqual(zoom(farRadius: lineRadius * 1.15), within)
    }

    func testTheMemoryIsForgottenOnAZoomChange() {
        let coverage = GlobeDistanceCoverage()
        let tile = VisibleTile(x: 40, y: 32, z: 6)
        let eyeDistance: Float = 0.2
        let lineRadius = Self.distance(from: Self.camera(eyeDistance: eyeDistance), to: tile) / Double(eyeDistance)
        _ = coverage.preferredZooms(visibleTiles: [tile], camera: Self.camera(eyeDistance: eyeDistance, farRadius: lineRadius / 1.15))
        // Another target zoom in between clears the memory: back at z6 the
        // tile just past the line is judged afresh, and is beyond it.
        _ = coverage.preferredZooms(visibleTiles: [VisibleTile(x: 80, y: 64, z: 7)], camera: Self.camera(eyeDistance: eyeDistance))
        XCTAssertEqual(coverage.preferredZooms(visibleTiles: [tile], camera: Self.camera(eyeDistance: eyeDistance, farRadius: lineRadius / 1.02))[0],
                       GlobeDistanceCoverage.floorZoom)
    }

    /// Through the preprocessor: the near tiles are exact, the far field
    /// collapses to a few cover tiles, and nothing overlaps.
    func testThePreprocessorSelectsFromTheRuleWithoutOverlaps() {
        let preprocessor = VisibleTilesPreprocessor()
        let camera = Self.camera(eyeDistance: 0.05)
        // The front of the sphere: what the culling's horizon test leaves.
        var tiles: [VisibleTile] = []
        for x in 20 ..< 44 {
            for y in 20 ..< 44 {
                tiles.append(VisibleTile(x: x, y: y, z: 6))
            }
        }
        let output = preprocessor.preprocess(visibleTiles: tiles,
                                             center: Center(tileX: 32, tileY: 32),
                                             renderSurfaceMode: .spherical,
                                             globeCamera: camera)
        let front = VisibleTile(x: 32, y: 32, z: 6)
        XCTAssertTrue(output.contains(front), "the tile under the eye is exact")
        let exact = output.filter { $0.z == 6 }.count
        let cover = output.filter { $0.z == GlobeDistanceCoverage.floorZoom }.count
        XCTAssertGreaterThan(exact, 0)
        XCTAssertGreaterThan(cover, 0, "the far field is asked for at the cover's zoom")
        let coverParents = Set(tiles.compactMap { $0.tile.findParentTile(atZoom: GlobeDistanceCoverage.floorZoom) })
        XCTAssertLessThanOrEqual(cover, coverParents.count, "and collapses to the block's cover tiles at most")
        XCTAssertLessThan(cover + exact, tiles.count / 8, "far fewer targets than visible tiles")
        for lhs in output {
            for rhs in output where lhs != rhs {
                XCTAssertFalse(lhs.tile.covers(rhs.tile), "\(lhs) overlaps \(rhs)")
            }
        }
        XCTAssertTrue(output.allSatisfy { $0.z >= GlobeDistanceCoverage.floorZoom })
    }
}
