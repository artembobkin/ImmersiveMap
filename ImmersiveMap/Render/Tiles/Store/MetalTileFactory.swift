// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

/// Turns a parsed tile into GPU state. Every buffer of the tile lives in one
/// backing allocation (`TileBufferArena`): the measure pass sums the aligned
/// footprints of exactly the arrays the write pass appends, so a tile costs
/// one Metal allocation instead of ~70 page-rounded ones.
final class MetalTileFactory {
    private let metalDevice: MTLDevice

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
    }

    func makeTile(from preparedTile: PreparedTileCPU) -> MetalTile {
        // Indices narrow to 16 bits once, ahead of both passes.
        let groundIndices = NarrowedIndices(indices: preparedTile.ground.indices,
                                            vertexCount: preparedTile.ground.vertices.count)
        let roadsWithIndices = preparedTile.roads.map { structureBucket in
            structureBucket.map { phase in
                (layer: phase, indices: NarrowedIndices(indices: phase.indices,
                                                        vertexCount: phase.vertices.count))
            }
        }
        let bridgeIndices = NarrowedIndices(indices: preparedTile.bridgeOverlay.indices,
                                            vertexCount: preparedTile.bridgeOverlay.vertices.count)
        let extrudedIndices = NarrowedIndices(indices: preparedTile.extruded.indices,
                                              vertexCount: preparedTile.extruded.vertices.count)

        var totalLength = measure(layer: preparedTile.ground, indices: groundIndices)
        for phase in roadsWithIndices.drawOrderBuckets.flatMap(\.drawOrderLayers) {
            totalLength += measure(layer: phase.layer, indices: phase.indices)
        }
        totalLength += measure(layer: preparedTile.bridgeOverlay, indices: bridgeIndices)
        totalLength += TileBufferArena.alignedSize(of: preparedTile.extruded.vertices)
        totalLength += extrudedIndices.alignedSize
        totalLength += TileBufferArena.alignedSize(of: preparedTile.extruded.styles)
        for preparedSet in [preparedTile.textLabels.full,
                            preparedTile.textLabels.reduced,
                            preparedTile.textLabels.minimal] {
            for run in preparedSet.glyphRuns {
                totalLength += TileBufferArena.alignedSize(of: run.localGlyphVertices)
            }
            for run in preparedSet.poiIconRuns {
                totalLength += TileBufferArena.alignedSize(of: run.localIconVertices)
            }
        }
        totalLength += TileBufferArena.alignedSize(of: preparedTile.roadLabels.localGlyphVertices)

        let arena = TileBufferArena(metalDevice: metalDevice, length: totalLength)

        let ground = build(layer: preparedTile.ground, indices: groundIndices, arena: arena)
        let roads = roadsWithIndices.map { structureBucket in
            structureBucket.map { phase in
                build(layer: phase.layer, indices: phase.indices, arena: arena)
            }
        }
        let bridgeOverlay = build(layer: preparedTile.bridgeOverlay, indices: bridgeIndices, arena: arena)
        let extruded = TileBuffers.Extruded(vertices: arena?.append(preparedTile.extruded.vertices) ?? nil,
                                            indices: extrudedIndices.append(to: arena),
                                            styles: arena?.append(preparedTile.extruded.styles) ?? nil,
                                            indexType: extrudedIndices.indexType)
        let textLabels = TileBuffers.TextLabels(full: makeTextLabelSet(from: preparedTile.textLabels.full, arena: arena),
                                                reduced: makeTextLabelSet(from: preparedTile.textLabels.reduced, arena: arena),
                                                minimal: makeTextLabelSet(from: preparedTile.textLabels.minimal, arena: arena))
        let roadLabels = makeRoadLabels(from: preparedTile.roadLabels, arena: arena)
        let tileBuffers = TileBuffers(backingBuffer: arena?.backingBuffer,
                                      ground: ground,
                                      roads: roads,
                                      bridgeOverlay: bridgeOverlay,
                                      extruded: extruded,
                                      textLabels: textLabels,
                                      roadLabels: roadLabels)
        return MetalTile(tile: preparedTile.tile, tileBuffers: tileBuffers)
    }

    /// One geometry layer's index data with the 16-bit narrowing applied
    /// once, shared by the measure and the write pass.
    private struct NarrowedIndices {
        let narrowed: [UInt16]?
        let original: [UInt32]
        let indexType: MTLIndexType

        init(indices: [UInt32], vertexCount: Int) {
            if let narrowed = IndexStorageMath.narrowedIndices(indices, vertexCount: vertexCount) {
                self.narrowed = narrowed
                indexType = .uint16
            } else {
                narrowed = nil
                indexType = .uint32
            }
            original = indices
        }

        var alignedSize: Int {
            if let narrowed {
                return TileBufferArena.alignedSize(of: narrowed)
            }
            return TileBufferArena.alignedSize(of: original)
        }

        func append(to arena: TileBufferArena?) -> TileBufferView? {
            if let narrowed {
                return arena?.append(narrowed) ?? nil
            }
            return arena?.append(original) ?? nil
        }
    }

    private func measure(layer: PreparedTileCPU.GeometryLayer, indices: NarrowedIndices) -> Int {
        TileBufferArena.alignedSize(of: layer.vertices)
            + indices.alignedSize
            + TileBufferArena.alignedSize(of: layer.styles)
            + TileBufferArena.alignedSize(of: layer.overviewStyleMasks)
    }

    private func build(layer: PreparedTileCPU.GeometryLayer,
                       indices: NarrowedIndices,
                       arena: TileBufferArena?) -> TileBuffers.GeometryLayer {
        TileBuffers.GeometryLayer(vertices: arena?.append(layer.vertices) ?? nil,
                                  indices: indices.append(to: arena),
                                  styles: arena?.append(layer.styles) ?? nil,
                                  overviewStyleMask: arena?.append(layer.overviewStyleMasks) ?? nil,
                                  indexType: indices.indexType)
    }

    private func makeTextLabelSet(from preparedSet: PreparedTileCPU.TextLabelSet,
                                  arena: TileBufferArena?) -> TileBuffers.TextLabelSet {
        let glyphRuns = preparedSet.glyphRuns.map { run in
            LabelsByStyleRun(style: run.style,
                             localGlyphVertices: arena?.append(run.localGlyphVertices) ?? nil)
        }
        let poiIconRuns = preparedSet.poiIconRuns.map { run in
            PoiIconRunBuffer(style: run.style,
                             localVertices: arena?.append(run.localIconVertices) ?? nil)
        }
        return TileBuffers.TextLabelSet(placementInputs: preparedSet.placementInputs,
                                        labelsByStyleRuns: glyphRuns,
                                        poiIconRuns: poiIconRuns)
    }

    private func makeRoadLabels(from preparedRoadLabels: PreparedTileCPU.RoadLabels,
                                arena: TileBufferArena?) -> TileBuffers.RoadLabels {
        TileBuffers.RoadLabels(pathInputs: preparedRoadLabels.pathInputs,
                               pathRanges: preparedRoadLabels.pathRanges,
                               pathLabels: preparedRoadLabels.pathLabels,
                               labelStyle: preparedRoadLabels.labelStyle,
                               localGlyphVertices: arena?.append(preparedRoadLabels.localGlyphVertices) ?? nil,
                               glyphBounds: preparedRoadLabels.glyphBounds,
                               glyphBoundRanges: preparedRoadLabels.glyphBoundRanges,
                               sizes: preparedRoadLabels.sizes,
                               anchorRanges: preparedRoadLabels.anchorRanges,
                               anchors: preparedRoadLabels.anchors)
    }
}
