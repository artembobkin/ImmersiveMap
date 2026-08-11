// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap

/// Shared builders for synthetic `PreparedTileCPU` values: tests that need a
/// real `MetalTile` build one through the production `MetalTileFactory`
/// instead of hand-assembling arenas.
enum PreparedTileCPUTestFixtures {
    static func emptyGeometryLayer() -> PreparedTileCPU.GeometryLayer {
        PreparedTileCPU.GeometryLayer(vertices: [], indices: [], styles: [], overviewStyleMasks: [])
    }

    static func empty(tile: Tile) -> PreparedTileCPU {
        withGround(tile: tile, ground: emptyGeometryLayer())
    }

    /// One red ground triangle covering the tile corner; everything else empty.
    static func withGroundTriangle(tile: Tile) -> PreparedTileCPU {
        withGround(tile: tile, ground: PreparedTileCPU.GeometryLayer(
            vertices: [
                TilePipeline.VertexIn(position: SIMD2<Int16>(0, 0), styleIndex: 0),
                TilePipeline.VertexIn(position: SIMD2<Int16>(4096, 0), styleIndex: 0),
                TilePipeline.VertexIn(position: SIMD2<Int16>(0, 4096), styleIndex: 0)
            ],
            indices: [0, 1, 2],
            styles: [TilePolygonStyle(color: SIMD4<Float>(1, 0, 0, 1))],
            overviewStyleMasks: [0]
        ))
    }

    /// A degenerate ground layer with `vertexCount` vertices: sizes the tile's
    /// backing allocation for tests that need page-scale buffers.
    static func withGroundVertexCount(_ vertexCount: Int, tile: Tile) -> PreparedTileCPU {
        withGround(tile: tile, ground: PreparedTileCPU.GeometryLayer(
            vertices: Array(repeating: TilePipeline.VertexIn(position: SIMD2<Int16>(0, 0), styleIndex: 0),
                            count: vertexCount),
            indices: [],
            styles: [],
            overviewStyleMasks: []
        ))
    }

    static func withGround(tile: Tile, ground: PreparedTileCPU.GeometryLayer) -> PreparedTileCPU {
        let emptyLayer = emptyGeometryLayer()
        let emptyPhases = RoadGeometryPhases(shadow: emptyLayer,
                                             casing: emptyLayer,
                                             fill: emptyLayer,
                                             detail: emptyLayer,
                                             overlay: emptyLayer)
        let emptyTextSet = PreparedTileCPU.TextLabelSet(placementInputs: [], glyphRuns: [], poiIconRuns: [])
        return PreparedTileCPU(tile: tile,
                               ground: ground,
                               roads: RoadStructureBuckets(tunnel: emptyPhases,
                                                           ground: emptyPhases,
                                                           bridge: emptyPhases),
                               bridgeOverlay: emptyLayer,
                               extruded: PreparedTileCPU.Extruded(vertices: [], indices: [], styles: []),
                               textLabels: PreparedTileCPU.TextLabels(full: emptyTextSet,
                                                                      reduced: emptyTextSet,
                                                                      minimal: emptyTextSet),
                               roadLabels: PreparedTileCPU.RoadLabels(pathInputs: [],
                                                                      pathRanges: [],
                                                                      pathLabels: [],
                                                                      labelStyle: nil,
                                                                      localGlyphVertices: [],
                                                                      glyphBounds: [],
                                                                      glyphBoundRanges: [],
                                                                      sizes: [],
                                                                      anchorRanges: [],
                                                                      anchors: []))
    }
}
