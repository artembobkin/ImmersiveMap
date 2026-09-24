// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The labels painted on the map: which copy of a name draws, at which
/// zooms, how large it is, and that the prepared-tile cache keeps it.
final class SurfaceLabelTests: XCTestCase {
    private static let placement = SurfaceLabelPlacement(referenceZoom: 3,
                                                         minimumZoom: 2.5,
                                                         maximumZoom: 5.5,
                                                         letterSpacingEm: 0.15)

    private func record(key: UInt64, vertexStart: Int = 0, vertexCount: Int = 6) -> SurfaceLabelRecord {
        SurfaceLabelRecord(key: key,
                           style: LabelTextStyle(key: 73,
                                                 fillColor: SIMD3<Float>(0.2, 0.4, 0.7),
                                                 strokeColor: SIMD3<Float>(1, 1, 1),
                                                 haloEm: 0.15,
                                                 sizePoints: 12,
                                                 weight: .thin),
                           placement: Self.placement,
                           vertexStart: vertexStart,
                           vertexCount: vertexCount)
    }

    // MARK: Selection

    /// The same name rides every tile zoom from the one it ships at: the
    /// finest source that carries it draws it, once.
    func testTheFinestSourceDrawsAName() {
        let sources = [
            SurfaceLabelSelection.Source(labels: [record(key: 1)], tileZoom: 3, worldWrap: 0),
            SurfaceLabelSelection.Source(labels: [record(key: 1), record(key: 2)], tileZoom: 4, worldWrap: 0)
        ]
        let items = SurfaceLabelSelection.select(sources: sources, cameraZoom: 4)
        XCTAssertEqual(items.map(\.key), [1, 2])
        XCTAssertEqual(items.map(\.sourceIndex), [1, 1])
    }

    /// Each copy of the flat world draws its own copy of the name.
    func testEveryWorldCopyDrawsItsOwnName() {
        let sources = [
            SurfaceLabelSelection.Source(labels: [record(key: 1)], tileZoom: 3, worldWrap: 0),
            SurfaceLabelSelection.Source(labels: [record(key: 1)], tileZoom: 3, worldWrap: 1)
        ]
        XCTAssertEqual(SurfaceLabelSelection.select(sources: sources, cameraZoom: 3).count, 2)
    }

    /// A name shows whole inside its zooms and not at all outside them.
    func testANameShowsOnlyAtItsZooms() {
        let sources = [SurfaceLabelSelection.Source(labels: [record(key: 1)], tileZoom: 3, worldWrap: 0)]
        XCTAssertTrue(SurfaceLabelSelection.select(sources: sources, cameraZoom: 2.4).isEmpty)
        XCTAssertEqual(SurfaceLabelSelection.select(sources: sources, cameraZoom: 2.5).count, 1)
        XCTAssertEqual(SurfaceLabelSelection.select(sources: sources, cameraZoom: 5.4).count, 1)
        XCTAssertTrue(SurfaceLabelSelection.select(sources: sources, cameraZoom: 5.5).isEmpty)
    }

    // MARK: Baking

    /// The map's scale follows the viewport's height: a tile at its own zoom
    /// spans its world size over the height the camera sees at distance 1.
    func testATileSpansTheShareOfTheHeightTheCameraSees() {
        let points = SurfaceLabelScale.tileScreenPoints(viewportHeightPoints: 800, tileWorldSize: 2 * tan(Double.pi / 8))
        XCTAssertEqual(points, 800, accuracy: 1e-9)
    }

    /// At the reference zoom the text spans its point size, and every zoom
    /// of the tile deeper doubles the tile units a point takes.
    func testTheTextSpansItsPointSizeAtTheReferenceZoom() {
        XCTAssertEqual(SurfaceLabelScale.tileUnitsPerPoint(tileZoom: 3, referenceZoom: 3, tileScreenPoints: 1024), 4)
        XCTAssertEqual(SurfaceLabelScale.tileUnitsPerPoint(tileZoom: 4, referenceZoom: 3, tileScreenPoints: 1024), 8)
        XCTAssertEqual(SurfaceLabelScale.tileUnitsPerPoint(tileZoom: 2, referenceZoom: 3, tileScreenPoints: 1024), 2)
    }

    /// A tile is drawn for the camera zooms from its own up to the next: a
    /// tile whose whole range lies outside the name's zooms never bakes it.
    func testATileNoZoomOfWhichShowsTheNameDoesNotCarryIt() {
        XCTAssertFalse(Self.placement.isVisible(onTileZoom: 1))
        XCTAssertTrue(Self.placement.isVisible(onTileZoom: 2))
        XCTAssertTrue(Self.placement.isVisible(onTileZoom: 5))
        XCTAssertFalse(Self.placement.isVisible(onTileZoom: 6))
    }

    // MARK: Cache

    func testThePreparedTileCacheKeepsTheSurfaceLabels() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        var preparedTile = PreparedTileCPUTestFixtures.empty(tile: tile)
        let vertices = (0..<12).map { index in
            LabelVertex(position: SIMD2<Float>(Float(index) * 100 - 300, 5_000),
                        uv: SIMD2<Float>(0.25, 0.5),
                        labelIndex: Int32(index / 6))
        }
        preparedTile.surfaceLabels = PreparedTileCPU.SurfaceLabelSet(labels: [record(key: 7, vertexStart: 0),
                                                                             record(key: 9, vertexStart: 6)],
                                                                    vertices: vertices)
        let cacheIdentity = PreparedTileCacheIdentity(preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
                                                      styleRevision: 1,
                                                      tileSourceRevision: 1,
                                                      textRevision: 1,
                                                      labelLanguage: .english,
                                                      labelFallbackPolicy: .international,
                                                      capitalMaximumZoom: 12,
                                                      cityMaximumZoom: 12,
                                                      smallSettlementMaximumZoom: 12,
                                                      landmarkMinimumZoom: 13,
                                                      addTestBorders: false,
                                                      labelsEnabled: true)
        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile, cacheIdentity: cacheIdentity)
        let decoded = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobFileURL: URL(fileURLWithPath: "/nonexistent/test.ptgeo"))

        let labels = decoded.image.surfaceLabels
        XCTAssertEqual(labels.map(\.key), [7, 9])
        XCTAssertEqual(labels.map(\.vertexStart), [0, 6])
        XCTAssertEqual(labels.map(\.vertexCount), [6, 6])
        XCTAssertEqual(labels.first?.placement, Self.placement)
        XCTAssertEqual(labels.first?.style.weight, .thin)
        XCTAssertEqual(decoded.image.spans, TileArenaImageMath.plan(for: preparedTile).spans)
        XCTAssertEqual(decoded.image.spans.last?.elementCount, vertices.count,
                       "the glyph quads are the arena's last span")
    }
}
