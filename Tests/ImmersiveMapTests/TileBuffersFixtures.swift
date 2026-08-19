// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// Shared TileBuffers fixtures. Production tiles are arena-backed (one
/// backing allocation with views into it), so test tiles are built the same
/// way instead of hand-rolling per-field buffers in every suite.
enum TileBuffersFixtures {
    static func emptyGeometryLayer() -> TileBuffers.GeometryLayer {
        TileBuffers.GeometryLayer(vertices: nil,
                                  indices: nil,
                                  styles: nil,
                                  overviewStyleMask: nil,
                                  lineStyles: nil,
                                  indexType: .uint16)
    }

    static func emptyTextLabelSet() -> TileBuffers.TextLabelSet {
        TileBuffers.TextLabelSet(placementInputs: [],
                                 labelsByStyleRuns: [],
                                 poiIconRuns: [])
    }

    static func emptyRoadLabels() -> TileBuffers.RoadLabels {
        TileBuffers.RoadLabels(pathInputs: [],
                               pathRanges: [],
                               pathLabels: [],
                               labelStyle: nil,
                               localGlyphVertices: nil,
                               glyphBounds: [],
                               glyphBoundRanges: [],
                               sizes: [],
                               anchorRanges: [],
                               anchors: [])
    }

    /// An empty-but-cacheable tile: every layer empty, one tiny backing
    /// allocation so the memory cache still sees a nonzero byte cost.
    static func makeEmptyTileBuffers(textLabels: TileBuffers.TextLabels? = nil) throws -> TileBuffers {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for MetalTile test fixture.")
        }
        let backingBuffer = try XCTUnwrap(device.makeBuffer(length: 16),
                                          "The fixture contract requires a nonzero cacheable allocation")
        let ground = emptyGeometryLayer()
        let phases = RoadGeometryPhases(shadow: ground,
                                        casing: ground,
                                        fill: ground,
                                        detail: ground,
                                        overlay: ground)
        return TileBuffers(backingBuffer: backingBuffer,
                           ground: ground,
                           roads: RoadStructureBuckets(tunnel: phases,
                                                       ground: phases,
                                                       automobileGround: phases,
                                                       bridge: phases),
                           bridgeOverlay: ground,
                           extruded: TileBuffers.Extruded(vertices: nil,
                                                          indices: nil,
                                                          styles: nil,
                                                          indexType: .uint16),
                           textLabels: textLabels ?? TileBuffers.TextLabels(full: emptyTextLabelSet(),
                                                                            reduced: emptyTextLabelSet(),
                                                                            minimal: emptyTextLabelSet()),
                           roadLabels: emptyRoadLabels())
    }
}
