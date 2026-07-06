// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import MetalKit
import XCTest

final class GlobeTexturePlacementPlannerTests: XCTestCase {
    func testBuildPlacementsKeepsOnlyBaseTargets() throws {
        let baseTile = Tile(x: 1, y: 1, z: 1)
        let baseMetalTile = MetalTile(tile: baseTile, tileBuffers: try makeTileBuffers())

        let context = GlobeTexturePlacementPlanner.buildPlacements(
            baseTargets: [VisibleTile(tile: baseTile)],
            readyTilesBySource: [
                baseTile: baseMetalTile
            ],
            baseZoom: 1,
            previousContext: .empty
        )

        XCTAssertEqual(context.tilePlacements.map(\.placeIn.tile), [baseTile])
    }

    func testBuildPlacementsUsesBaseReplacementRules() throws {
        let baseTile = Tile(x: 1, y: 1, z: 1)
        let baseMetalTile = MetalTile(tile: baseTile, tileBuffers: try makeTileBuffers())

        let context = GlobeTexturePlacementPlanner.buildPlacements(
            baseTargets: [VisibleTile(tile: baseTile)],
            readyTilesBySource: [
                baseTile: baseMetalTile
            ],
            baseZoom: 1,
            previousContext: .empty
        )

        XCTAssertEqual(context.tilePlacements.count, 1)
        XCTAssertEqual(context.tilePlacements.first?.placeIn.tile, baseTile)
    }

    private func makeTileBuffers() throws -> TileBuffers {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for MetalTile test fixture.")
        }
        let value: UInt32 = 0
        let buffer = device.makeBuffer(bytes: [value], length: MemoryLayout<UInt32>.stride)!
        let ground = TileBuffers.GeometryLayer(verticesBuffer: buffer,
                                               indicesBuffer: buffer,
                                               stylesBuffer: buffer,
                                               overviewStyleMaskBuffer: buffer,
                                               indicesCount: 0,
                                               verticesCount: 0)
        let extruded = TileBuffers.Extruded(verticesBuffer: buffer,
                                            indicesBuffer: buffer,
                                            stylesBuffer: buffer,
                                            indicesCount: 0,
                                            verticesCount: 0)
        let phases = RoadGeometryPhases(shadow: ground,
                                        casing: ground,
                                        fill: ground,
                                        detail: ground,
                                        overlay: ground)
        let roads = RoadStructureBuckets(tunnel: phases,
                                         ground: phases,
                                         bridge: phases)
        let emptyTextLabelSet = TileBuffers.TextLabelSet(placementInputs: [],
                                                         labelsByStyleRuns: [],
                                                         poiIconRuns: [])
        return TileBuffers(ground: ground,
                           roads: roads,
                           bridgeOverlay: ground,
                           extruded: extruded,
                           textLabels: TileBuffers.TextLabels(full: emptyTextLabelSet,
                                                               reduced: emptyTextLabelSet,
                                                               minimal: emptyTextLabelSet),
                           roadLabels: TileBuffers.RoadLabels(pathInputs: [],
                                                              pathRanges: [],
                                                              pathLabels: [],
                                                              labelStyle: nil,
                                                              localGlyphVerticesBuffer: nil,
                                                              localGlyphVertexCount: 0,
                                                              glyphBounds: [],
                                                              glyphBoundRanges: [],
                                                              sizes: [],
                                                              anchorRanges: [],
                                                              anchors: []))
    }
}
