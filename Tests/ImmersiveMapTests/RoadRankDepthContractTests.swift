// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The roads are ordered by depth: a band of ranks per role of a structure,
/// a style's rank inside it. The bands have to sit in the order the roads
/// paint in, the whole ladder has to stay as shallow as the road buckets
/// were before they were ranked, and the parser has to hand out the style
/// indices by class priority, nearest first in the buffer.
final class RoadRankDepthContractTests: XCTestCase {
    func testTheBandsFollowThePaintOrder() {
        func band(_ structureKind: RoadStructureKind, _ role: RoadPassRole) -> Int {
            RoadRankDepth.band(structureKind: structureKind, role: role)
        }
        // Inside a structure: the shadow, the casing, the fill, the paint.
        for structureKind in RoadStructureKind.drawOrder {
            XCTAssertLessThan(band(structureKind, .shadow), band(structureKind, .casing))
            XCTAssertLessThan(band(structureKind, .casing), band(structureKind, .fill))
            XCTAssertLessThan(band(structureKind, .fill), band(structureKind, .detail))
        }
        // A structure lies over every role of the one under it.
        XCTAssertLessThan(band(.tunnel, .detail), band(.ground, .shadow))
        XCTAssertLessThan(band(.ground, .detail), band(.automobileGround, .shadow))
        XCTAssertLessThan(band(.automobileGround, .detail), band(.bridge, .shadow))
        // The bridge overlay lies over them all, and the overlay role over it.
        XCTAssertLessThan(band(.bridge, .detail), RoadRankDepth.bridgeOverlayBand)
        for structureKind in RoadStructureKind.drawOrder {
            XCTAssertLessThan(RoadRankDepth.bridgeOverlayBand, band(structureKind, .overlay))
        }
    }

    func testEveryLayerHasItsOwnBand() {
        var bands = Set([RoadRankDepth.bridgeOverlayBand])
        for layer in RoadRankDepth.layersNearestFirst {
            XCTAssertTrue(bands.insert(layer.band).inserted, "band \(layer.band) is taken twice")
            XCTAssertLessThan(layer.band, RoadRankDepth.bandCount)
        }
        XCTAssertEqual(bands.count, RoadRankDepth.bandCount)
        let drawn = RoadRankDepth.layersNearestFirst.map(\.band)
        XCTAssertEqual(drawn, drawn.sorted(by: >), "the layers that blend draw nearest first")
    }

    func testAHigherBandIsNearerAndTheLadderStaysShallow() throws {
        for band in 0 ..< RoadRankDepth.bandCount - 1 {
            // The nearest rank of a band is still farther than the next
            // band's farthest.
            let nearestOfThis = RoadRankDepth.depthOffset(band: band)
                + Float(RoadRankDepth.ranksPerBand) * GlobeSurfaceDepthRank.layerDepthStep
            let farthestOfNext = RoadRankDepth.depthOffset(band: band + 1) + GlobeSurfaceDepthRank.layerDepthStep
            XCTAssertLessThanOrEqual(nearestOfThis, farthestOfNext)
        }
        XCTAssertEqual(RoadRankDepth.depthOffset(band: 0), GlobeSurfaceDepthRank.flatRoadsDepthOffset)
        // No deeper than one band of 256 styles over the roads' offset,
        // which is what the road buckets took before they were ranked: the
        // band stays farther than every real fragment.
        let deepest = RoadRankDepth.depthOffset(band: RoadRankDepth.bandCount)
        XCTAssertLessThanOrEqual(deepest, GlobeSurfaceDepthRank.flatRoadsDepthOffset
            + 256 * GlobeSurfaceDepthRank.layerDepthStep)
        // The labels painted on the map lie over every road, even a baked
        // layer or the bridge overlay with 256 styles, whose ranks are not
        // clamped to a band.
        XCTAssertLessThan(SurfaceLabelDepth.depth,
                          1 - deepest - 257 * GlobeSurfaceDepthRank.layerDepthStep)
        // And under every wall: the real geometry's scale is nearer than
        // the labels' by at least a step (RenderCamera.realDepthScale).
        XCTAssertLessThan(RenderCamera.realDepthScale,
                          SurfaceLabelDepth.depth - GlobeSurfaceDepthRank.layerDepthStep)
        let labelSource = try shaderSource("Labels/Shaders/Surface/SurfaceLabel.metal")
        XCTAssertTrue(labelSource.contains("constant float kSurfaceLabelRealDepthScale = 1.0 - 1536.0 * 3.2e-6;"))
    }

    func testTheShaderClampsAStyleToTheBand() throws {
        let source = try shaderSource("Tile/Shaders/Tile.metal")
        XCTAssertTrue(source.contains("constant float kTileRoadBandRanks = \(RoadRankDepth.ranksPerBand).0;"))
        XCTAssertTrue(source.contains("styleRank = min(styleRank, kTileRoadBandRanks - 1.0);"))
        XCTAssertTrue(source.contains("constant bool kTileRoadRibbons [[function_constant(4)]];"))
        XCTAssertTrue(source.contains("constant bool kTileRoadBlended [[function_constant(5)]];"))
    }

    func testARoadLayerRanksItsStylesByClassPriorityAndGoesOutNearestFirst() {
        func polygon(_ x: Float) -> ParsedPolygon {
            ParsedPolygon(vertices: [SIMD2(x, 0), SIMD2(x + 1, 0), SIMD2(x, 1)],
                          indices: [0, 1, 2],
                          lineDistances: [0, 0, 0],
                          lineParameters: [0, 0, 0])
        }
        func road(_ x: Int16, key: UInt8, priority: Int, sequence: Int) -> OrderedRoadPolygon {
            OrderedRoadPolygon(polygon: polygon(Float(x)),
                               styleKey: key,
                               structureKind: .automobileGround,
                               layer: 0,
                               classPriority: priority,
                               passRole: .fill,
                               sequence: sequence)
        }
        func style(_ key: UInt8) -> BakedStyle {
            BakedStyle(pass: LinePass(key: key,
                                      color: SIMD4<Float>(Float(key), 0, 0, 1),
                                      lineGeometry: LineGeometryStyle(lineWidth: 8)))
        }
        // The higher class has the lower key: the priority decides, not the
        // key.
        let roads = [road(10, key: 9, priority: 80, sequence: 0),
                     road(20, key: 40, priority: 50, sequence: 1),
                     road(30, key: 9, priority: 79, sequence: 2)]
        let layer = TileUnificationStage.unifyOrderedRoadLayer(
            sortedRoadPolygons: roads.sorted(by: OrderedRoadPolygon.sort),
            stylesByKey: [9: style(9), 40: style(40)]
        )
        XCTAssertEqual(layer.styles.map(\.color.x), [40, 9], "the lower class takes the farther rank")
        let vertices = layer.drawing.vertices
        XCTAssertEqual(vertices.map(\.styleIndex), [1, 1, 1, 1, 1, 1, 0, 0, 0])
        XCTAssertEqual([vertices[0].position.x, vertices[3].position.x, vertices[6].position.x], [30, 10, 20],
                       "the highest style leads, and its roads keep their sorted order")
    }

    private func shaderSource(_ relativePath: String) throws -> String {
        let packageRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRootURL.appendingPathComponent("Sources/ImmersiveMap").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
