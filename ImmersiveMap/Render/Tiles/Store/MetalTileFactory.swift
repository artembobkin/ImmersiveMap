// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

final class MetalTileFactory {
    private let metalDevice: MTLDevice
    private let groundBuffersBuilder: TileGroundBuffersBuilder
    private let extrudedBuffersBuilder: TileExtrudedBuffersBuilder

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
        self.groundBuffersBuilder = TileGroundBuffersBuilder(metalDevice: metalDevice)
        self.extrudedBuffersBuilder = TileExtrudedBuffersBuilder(metalDevice: metalDevice)
    }

    func makeTile(from preparedTile: PreparedTileCPU) -> MetalTile {
        let ground = groundBuffersBuilder.build(layer: preparedTile.ground)
        let roads = preparedTile.roads.map { structureBucket in
            structureBucket.map { phase in
                groundBuffersBuilder.build(layer: phase)
            }
        }
        let bridgeOverlay = groundBuffersBuilder.build(layer: preparedTile.bridgeOverlay)
        let extruded = extrudedBuffersBuilder.build(extruded: preparedTile.extruded)
        let textLabels = makeTextLabels(from: preparedTile.textLabels)
        let roadLabels = makeRoadLabels(from: preparedTile.roadLabels)
        let tileBuffers = TileBuffers(ground: ground,
                                      roads: roads,
                                      bridgeOverlay: bridgeOverlay,
                                      extruded: extruded,
                                      textLabels: textLabels,
                                      roadLabels: roadLabels)
        return MetalTile(tile: preparedTile.tile, tileBuffers: tileBuffers)
    }

    private func makeTextLabels(from preparedTextLabels: PreparedTileCPU.TextLabels) -> TileBuffers.TextLabels {
        return TileBuffers.TextLabels(full: makeTextLabelSet(from: preparedTextLabels.full),
                                      reduced: makeTextLabelSet(from: preparedTextLabels.reduced),
                                      minimal: makeTextLabelSet(from: preparedTextLabels.minimal))
    }

    private func makeTextLabelSet(from preparedSet: PreparedTileCPU.TextLabelSet) -> TileBuffers.TextLabelSet {
        let glyphRuns = preparedSet.glyphRuns.map { run in
            let buffer: MTLBuffer?
            if run.localGlyphVertices.isEmpty {
                buffer = nil
            } else {
                buffer = metalDevice.makeBuffer(bytes: run.localGlyphVertices,
                                                length: MemoryLayout<LabelVertex>.stride * run.localGlyphVertices.count)
            }
            return LabelsByStyleRun(style: run.style,
                                    localGlyphVerticesBuffer: buffer,
                                    localGlyphVertexCount: run.localGlyphVertices.count)
        }

        let poiIconRuns = preparedSet.poiIconRuns.map { run in
            let buffer: MTLBuffer?
            if run.localIconVertices.isEmpty {
                buffer = nil
            } else {
                buffer = metalDevice.makeBuffer(bytes: run.localIconVertices,
                                                length: MemoryLayout<LabelVertex>.stride * run.localIconVertices.count)
            }
            return PoiIconRunBuffer(style: run.style,
                                    localVerticesBuffer: buffer,
                                    localVertexCount: run.localIconVertices.count)
        }

        return TileBuffers.TextLabelSet(placementInputs: preparedSet.placementInputs,
                                        labelsByStyleRuns: glyphRuns,
                                        poiIconRuns: poiIconRuns)
    }

    private func makeRoadLabels(from preparedRoadLabels: PreparedTileCPU.RoadLabels) -> TileBuffers.RoadLabels {
        let localGlyphVerticesBuffer: MTLBuffer?
        if preparedRoadLabels.localGlyphVertices.isEmpty {
            localGlyphVerticesBuffer = nil
        } else {
            localGlyphVerticesBuffer = metalDevice.makeBuffer(bytes: preparedRoadLabels.localGlyphVertices,
                                                              length: MemoryLayout<LabelVertex>.stride * preparedRoadLabels.localGlyphVertices.count,
                                                              options: [.storageModeShared])
        }

        return TileBuffers.RoadLabels(pathInputs: preparedRoadLabels.pathInputs,
                                      pathRanges: preparedRoadLabels.pathRanges,
                                      pathLabels: preparedRoadLabels.pathLabels,
                                      labelStyle: preparedRoadLabels.labelStyle,
                                      localGlyphVerticesBuffer: localGlyphVerticesBuffer,
                                      localGlyphVertexCount: preparedRoadLabels.localGlyphVertices.count,
                                      glyphBounds: preparedRoadLabels.glyphBounds,
                                      glyphBoundRanges: preparedRoadLabels.glyphBoundRanges,
                                      sizes: preparedRoadLabels.sizes,
                                      anchorRanges: preparedRoadLabels.anchorRanges,
                                      anchors: preparedRoadLabels.anchors)
    }
}
