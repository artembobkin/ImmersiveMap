// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Road label filter by visible screen area: the tile quad is clipped against
/// the near plane and the viewport, metrics are computed on the visible part.
/// The viewport in tests is 1000x1000: NDC x/y = -1..1 map to 0..1000 px.
final class RoadLabelNearCameraFilterTests: XCTestCase {
    func testRoadLabelNearCameraFilterDoesNotUsePathOrAnchorCulling() throws {
        let filterSource = try productionSource("ImmersiveMap/Labels/Road/RoadLabelNearCameraFilter.swift")
        let prepareSource = try productionSource("ImmersiveMap/Render/Core/Subsystems/Labels/BaseLabelPrepareSubsystem.swift")

        XCTAssertFalse(filterSource.contains("shouldKeepPath"))
        XCTAssertFalse(filterSource.contains("shouldKeepAnchor"))
        XCTAssertFalse(prepareSource.contains("shouldKeepPath"))
        XCTAssertFalse(prepareSource.contains("shouldKeepAnchor"))
    }

    func testKeepsLargeFullyVisibleTile() {
        // Quad of ~700x700 px, undistorted.
        let result = RoadLabelNearCameraFilter.shouldKeepTile(
            clipCorners: quad(minX: 100, minY: 100, maxX: 800, maxY: 800),
            viewportWidth: 1000,
            viewportHeight: 1000
        )

        XCTAssertTrue(result)
    }

    func testRejectsSmallUndistortedTile() {
        // A 200x200 px square is below the area threshold.
        let result = RoadLabelNearCameraFilter.shouldKeepTile(
            clipCorners: quad(minX: 100, minY: 100, maxX: 300, maxY: 300),
            viewportWidth: 1000,
            viewportHeight: 1000
        )

        XCTAssertFalse(result)
    }

    func testRejectsRibbonFailingCompressionRatio() {
        // A diagonal ribbon of ~1300x80 px inside the viewport: the 103k area
        // passes, but the ratio 103k/1300^2 = 0.06 reveals a strip flattened
        // by perspective.
        let result = RoadLabelNearCameraFilter.shouldKeepTile(
            clipCorners: [
                clipPoint(x: 60, y: 20, w: 1),
                clipPoint(x: 980, y: 940, w: 1),
                clipPoint(x: 924, y: 996, w: 1),
                clipPoint(x: 4, y: 76, w: 1)
            ],
            viewportWidth: 1000,
            viewportHeight: 1000
        )

        XCTAssertFalse(result)
    }

    func testKeepsNearTileCrossingCameraPlane() {
        // Near corners behind the camera (w < 0): clipping against the near
        // plane keeps the visible half, and it is huge: the tile is kept, and
        // the degenerate corner projections don't affect the decision.
        let corners = [
            clipPoint(x: -400, y: 900, w: 1),
            clipPoint(x: 1400, y: 900, w: 1),
            SIMD4<Float>(0.4, -0.6, 0.0, -0.5),
            SIMD4<Float>(-0.4, -0.6, 0.0, -0.5)
        ]

        let result = RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: corners,
                                                              viewportWidth: 1000,
                                                              viewportHeight: 1000)

        XCTAssertTrue(result)
    }

    func testRejectsTileFullyBehindCamera() {
        let behind = SIMD4<Float>(0.2, 0.2, 0.0, -1.0)
        let result = RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: [behind, behind, behind, behind],
                                                              viewportWidth: 1000,
                                                              viewportHeight: 1000)

        XCTAssertFalse(result)
    }

    func testUnderzoomRequiresMoreVisibleAreaPerContent() {
        // A 700x700 quad (490k px): enough for the exact tile, but for a parent
        // two levels coarser the area per content, 490k/16 = 30.6k, is below the
        // 40k threshold: its world is squeezed 16x and labels along roads are
        // degenerate.
        let corners = quad(minX: 100, minY: 100, maxX: 800, maxY: 800)

        XCTAssertTrue(RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: corners,
                                                               viewportWidth: 1000,
                                                               viewportHeight: 1000,
                                                               underzoomLevels: 0))
        XCTAssertFalse(RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: corners,
                                                                viewportWidth: 1000,
                                                                viewportHeight: 1000,
                                                                underzoomLevels: 2))
    }

    func testNearCoarseParentPassesWithLargeVisibleArea() {
        // A near parent one level coarser covering almost the entire screen:
        // the visible area per content is sufficient (900k / 4 > threshold).
        let result = RoadLabelNearCameraFilter.shouldKeepTile(
            clipCorners: quad(minX: 20, minY: 20, maxX: 980, maxY: 980),
            viewportWidth: 1000,
            viewportHeight: 1000,
            underzoomLevels: 1
        )

        XCTAssertTrue(result)
    }

    func testVisibleAreaIsClippedByViewport() {
        // A giant quad far beyond the screen: the decision is driven not by the
        // full projection (17000x200 = 3.4M px) but by the visible part,
        // 1000x200 = 200k px. That is enough for the exact tile, but a parent
        // two levels coarser no longer has enough area per content
        // (200k/16 = 12.5k): without the clip it would have passed
        // (3.4M/16 = 212k).
        let corners = quad(minX: -8000, minY: 400, maxX: 9000, maxY: 600)

        XCTAssertTrue(RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: corners,
                                                               viewportWidth: 1000,
                                                               viewportHeight: 1000,
                                                               underzoomLevels: 0))
        XCTAssertFalse(RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: corners,
                                                                viewportWidth: 1000,
                                                                viewportHeight: 1000,
                                                                underzoomLevels: 2))
    }

    func testTileCornerInputsUseOwnerTileAndSingleSlot() {
        let inputs = RoadLabelNearCameraFilter.makeTileCornerInputs(tile: VisibleTile(x: 12,
                                                                                     y: 34,
                                                                                     z: 6,
                                                                                     loop: -1))

        XCTAssertEqual(inputs.map(\.uv), [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(1, 1),
            SIMD2<Float>(0, 1)
        ])
        XCTAssertEqual(inputs.map(\.tile), Array(repeating: SIMD3<Int32>(12, 34, 6), count: 4))
        XCTAssertEqual(inputs.map(\.tileSlotIndex), Array(repeating: UInt32(0), count: 4))
    }

    /// Clip coordinate of a point with screen position (x, y) px at w = 1
    /// and a 1000x1000 viewport.
    private func clipPoint(x: Float, y: Float, w: Float) -> SIMD4<Float> {
        let ndcX = x / 1000 * 2 - 1
        let ndcY = y / 1000 * 2 - 1
        return SIMD4<Float>(ndcX * w, ndcY * w, 0, w)
    }

    private func quad(minX: Float, minY: Float, maxX: Float, maxY: Float) -> [SIMD4<Float>] {
        [
            clipPoint(x: minX, y: minY, w: 1),
            clipPoint(x: maxX, y: minY, w: 1),
            clipPoint(x: maxX, y: maxY, w: 1),
            clipPoint(x: minX, y: maxY, w: 1)
        ]
    }

    private func productionSource(_ relativePath: String) throws -> String {
        // On the iOS simulator cwd points into the sandbox; the package root is derived from this file's path.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
