// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The edge lines of a road: a deferred ribbon carries its rim as line
/// segments over its rim vertices, which the flat drawer draws as one-pixel
/// lines at half the road's alpha to soften the hard edge. A road layer's
/// indices are the bodies of its roads, then their edge lines, and the
/// boundary travels with the prepared tile.
final class RoadEdgeLineTests: XCTestCase {
    private let tileExtent: Float = 4096

    private func ribbon(_ points: [SIMD2<Float>],
                        startCapRound: Bool = false,
                        deferred: Bool = true) throws -> ParsedPolygon {
        try XCTUnwrap(ParseLine().parse(points: points,
                                        width: 10,
                                        tileExtent: tileExtent,
                                        startCapRound: startCapRound,
                                        endCapRound: false,
                                        lineJoinRound: true,
                                        clipGeometryToTileBounds: false,
                                        deferredExtrusion: deferred))
    }

    func testAStraightSegmentCarriesALineAlongEachSide() throws {
        let polygon = try ribbon([SIMD2(100, 100), SIMD2(200, 100)])
        XCTAssertEqual(polygon.vertices.count, 4, "the lines add no vertex")
        XCTAssertEqual(polygon.indices.count, 6, "the body is one quad")
        XCTAssertEqual(polygon.edgeLineIndices, [0, 2, 1, 3], "a line along each side, none across the ends")
    }

    func testAnEdgeLineJoinsTwoRimVerticesOfOneSide() throws {
        // A bend with a round join, and a round cap at the start.
        let polygon = try ribbon([SIMD2(100, 100), SIMD2(200, 100), SIMD2(200, 300)], startCapRound: true)
        XCTAssertEqual(polygon.edgeLineIndices.count % 2, 0)
        for line in stride(from: 0, to: polygon.edgeLineIndices.count, by: 2) {
            let first = Int(polygon.edgeLineIndices[line])
            let second = Int(polygon.edgeLineIndices[line + 1])
            XCTAssertNotEqual(polygon.lineDistances[first], 0, "a hub is no end of an edge line")
            XCTAssertNotEqual(polygon.lineDistances[second], 0, "a hub is no end of an edge line")
            XCTAssertEqual(polygon.lineDistances[first] > 0, polygon.lineDistances[second] > 0,
                           "a line stays on one side of the ribbon")
        }
        // Each segment has a line along each side, the join's fan and the
        // cap's fan a line for each of their triangles.
        let fanTriangles = (polygon.indices.count - 2 * 6) / 3
        XCTAssertEqual(polygon.edgeLineIndices.count, 2 * 4 + fanTriangles * 2)
    }

    func testABakedRibbonCarriesNoEdgeLines() throws {
        let polygon = try ribbon([SIMD2(100, 100), SIMD2(200, 100)], deferred: false)
        XCTAssertTrue(polygon.edgeLineIndices.isEmpty)
    }

    func testARoadLayerWritesItsBodiesThenItsEdgeLines() throws {
        func road(_ y: Float, sequence: Int) throws -> OrderedRoadPolygon {
            OrderedRoadPolygon(polygon: try ribbon([SIMD2(100, y), SIMD2(200, y)]),
                               styleKey: 7,
                               structureKind: .automobileGround,
                               layer: 0,
                               classPriority: 50,
                               passRole: .fill,
                               sequence: sequence)
        }
        let style = BakedStyle(pass: LinePass(key: 7,
                                              color: SIMD4<Float>(repeating: 1),
                                              lineGeometry: LineGeometryStyle(lineWidth: 10)))
        let layer = TileUnificationStage.unifyOrderedRoadLayer(
            sortedRoadPolygons: [try road(100, sequence: 0), try road(300, sequence: 1)],
            stylesByKey: [7: style]
        )
        XCTAssertEqual(layer.drawing.vertices.count, 8)
        XCTAssertEqual(layer.drawing.edgeLineIndexStart, 12, "two quads of bodies come first")
        // The second road's lines read the second road's vertices.
        XCTAssertEqual(Array(layer.drawing.indices[12...]), [0, 2, 1, 3, 4, 6, 5, 7])
    }

    /// A tile whose automobile fill layer is one quad and its two edge
    /// lines, everything else empty.
    private func preparedTileWithOneRoad(tile: Tile) -> PreparedTileCPU {
        let base = PreparedTileCPUTestFixtures.empty(tile: tile)
        let vertices = (0 ..< 4).map { TileVertexIn(position: SIMD2<Int16>(Int16($0), 0), styleIndex: 0) }
        let fill = PreparedTileCPU.GeometryLayer(vertices: vertices,
                                                 indices: [0, 1, 2, 1, 3, 2, 0, 2, 1, 3],
                                                 styles: [TilePolygonStyle(color: SIMD4<Float>(repeating: 1))],
                                                 styleZoomFades: [ImmersiveMapZoomFade.none.shaderPair],
                                                 edgeLineIndexStart: 6)
        let empty = PreparedTileCPUTestFixtures.emptyGeometryLayer()
        let automobileGround = RoadGeometryPhases(shadow: empty, casing: empty, fill: fill, detail: empty, overlay: empty)
        return PreparedTileCPU(tile: tile,
                               ground: base.ground,
                               roads: RoadStructureBuckets(tunnel: base.roads.tunnel,
                                                           ground: base.roads.ground,
                                                           automobileGround: automobileGround,
                                                           bridge: base.roads.bridge),
                               bridgeOverlay: base.bridgeOverlay,
                               extruded: base.extruded,
                               textLabels: base.textLabels,
                               roadLabels: base.roadLabels)
    }

    private var fillSlot: Int {
        RoadStructureKind.drawOrder.firstIndex(of: .automobileGround)! * RoadPassRole.drawOrder.count
            + RoadPassRole.drawOrder.firstIndex(of: .fill)!
    }

    func testThePreparedTileListsTheBoundariesInTheArenaLayerOrder() {
        let prepared = preparedTileWithOneRoad(tile: Tile(x: 1, y: 2, z: 14))
        let starts = prepared.roadEdgeLineIndexStarts
        XCTAssertEqual(starts.count, RoadStructureKind.drawOrder.count * RoadPassRole.drawOrder.count)
        XCTAssertEqual(starts[fillSlot], 6)
        // A layer without edge lines is all bodies: the boundary is its end.
        for (slot, start) in starts.enumerated() where slot != fillSlot {
            XCTAssertEqual(start, 0, "an empty layer ends where it starts")
        }
        XCTAssertEqual(PreparedTileCPUTestFixtures.withGroundTriangle(tile: prepared.tile).ground.edgeLineIndexStart, 3,
                       "a layer that states no boundary keeps its whole range as bodies")
    }

    func testTheBoundariesSurviveTheDiskCodec() throws {
        let tile = Tile(x: 1, y: 2, z: 14)
        let prepared = preparedTileWithOneRoad(tile: tile)
        let identity = PreparedTileCacheIdentity(preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
                                                 styleRevision: 1,
                                                 tileSourceRevision: 2,
                                                 textRevision: 4,
                                                 labelLanguage: .english,
                                                 labelFallbackPolicy: .international,
                                                 capitalMaximumZoom: 12,
                                                 cityMaximumZoom: 12,
                                                 smallSettlementMaximumZoom: 12,
                                                 landmarkMinimumZoom: 13,
                                                 addTestBorders: false,
                                                 labelsEnabled: true)
        let encoded = try PreparedTileDiskCodec.encode(preparedTile: prepared, cacheIdentity: identity).metadata
        let decoded = try PreparedTileDiskCodec.decode(data: encoded,
                                                       expectedTile: tile,
                                                       cacheIdentity: identity,
                                                       blobFileURL: URL(fileURLWithPath: "/nonexistent/test.ptgeo"))
        XCTAssertEqual(decoded.image.roadEdgeLineIndexStarts, prepared.roadEdgeLineIndexStarts)
        XCTAssertEqual(decoded.image.roadEdgeLineIndexStarts[fillSlot], 6)
    }
}
