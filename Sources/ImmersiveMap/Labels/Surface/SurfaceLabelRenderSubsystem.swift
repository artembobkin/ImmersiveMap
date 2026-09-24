// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The labels painted on the map (`LabelPlacement.surface`): drawn in the
/// world pass right after the ground, on the flat map and on the globe
/// alike, through the ground's own projection. `update` picks the copy of
/// each label that draws (`SurfaceLabelSelection`), `encode` draws every
/// halo and then every fill. A label shows whole or not at all: nothing
/// fades in or out.
final class SurfaceLabelRenderSubsystem: RenderSubsystem {
    let name: String = "SurfaceLabels"

    private struct DrawItem {
        let metalTile: MetalTile
        let worldWrap: Int8
        let record: SurfaceLabelRecord
    }

    private let pipeline: SurfaceLabelPipeline
    private let textRenderer: TextRenderer
    private let depthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private var drawItems: [DrawItem] = []

    init(pipeline: SurfaceLabelPipeline,
         textRenderer: TextRenderer,
         depthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState) {
        self.pipeline = pipeline
        self.textRenderer = textRenderer
        self.depthState = depthState
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext: FrameContext) {
        let placements = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
        // One source per tile and world copy. The sphere has one world, so
        // its placements' wrap is not part of a source there.
        let wrapsWorld = frameContext.renderSurfaceMode == .flat
        var seen = Set<FlatGroundSourceKey>()
        var sourceTiles: [(metalTile: MetalTile, worldWrap: Int8)] = []
        for placement in placements where placement.metalTile.tileBuffers.surfaceLabels.labels.isEmpty == false {
            let worldWrap = wrapsWorld ? placement.placeIn.worldWrap : 0
            if seen.insert(FlatGroundSourceKey(tile: placement.metalTile.tile, worldWrap: worldWrap)).inserted {
                sourceTiles.append((placement.metalTile, worldWrap))
            }
        }
        let sources = sourceTiles.map {
            SurfaceLabelSelection.Source(labels: $0.metalTile.tileBuffers.surfaceLabels.labels,
                                         tileZoom: $0.metalTile.tile.z,
                                         worldWrap: $0.worldWrap)
        }
        let selected = SurfaceLabelSelection.select(sources: sources, cameraZoom: frameContext.zoom)
        drawItems = selected.map { item in
            let source = sourceTiles[item.sourceIndex]
            return DrawItem(metalTile: source.metalTile,
                            worldWrap: source.worldWrap,
                            record: sources[item.sourceIndex].labels[item.labelIndex])
        }
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .surfaceLabels, drawItems.isEmpty == false else { return }

        encoder.pushDebugGroup("surfaceLabels")
        // Every glyph is counter-clockwise in render space, like the ground's
        // triangles, and neither surface's projection mirrors: culling the
        // back faces removes the far side of the planet, as for the ground.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setDepthStencilState(depthState)

        var cameraUniform = frameContext.cameraUniform
        encoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)

        // Every tile at its own zoom has the same world size: the map's at
        // the frame's integer zoom over that zoom's tile count.
        let normalization = frameContext.resolvedPresentation.renderNormalizationState
        let viewportHeightPoints = Double(frameContext.drawSize.height) / max(Double(frameContext.pixelsPerPoint), 1)
        let tileScreenPoints = SurfaceLabelScale.tileScreenPoints(
            viewportHeightPoints: viewportHeightPoints,
            tileWorldSize: normalization.flatRenderMapSize / normalization.zoomScale
        )

        let screen = SurfaceLabelScreen(
            viewportSizePx: SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height)),
            pixelsPerPoint: Float(frameContext.pixelsPerPoint)
        )

        let surface: Surface
        switch frameContext.renderSurfaceMode {
        case .flat:
            encoder.setRenderPipelineState(pipeline.flatPipelineState)
            surface = .flat(frameContext.resolvedPresentation.flatRenderState)
        case .spherical:
            let globe = frameContext.globeRenderUniform
            let pureSphere = GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                                transition: globe.transition)
            encoder.setRenderPipelineState(pureSphere ? pipeline.spherePipelineState : pipeline.morphPipelineState)
            var globeValue = globe
            var globeFrame = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: cameraUniform.matrix)
            encoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 8)
            encoder.setVertexBytes(&globeFrame, length: MemoryLayout<GlobeFrameConstantsUniform>.stride, index: 10)
            surface = .sphere
        }

        // Every halo first, then every fill: where two names cross, the
        // halo of one never covers the letters of the other.
        for haloPass in [true, false] {
            for item in drawItems {
                draw(item,
                     haloPass: haloPass,
                     surface: surface,
                     tileScreenPoints: tileScreenPoints,
                     screen: screen,
                     encoder: encoder)
            }
        }

        encoder.setCullMode(.none)
        encoder.setFrontFacing(.clockwise)
        encoder.setDepthStencilState(depthDisabledState)
        encoder.popDebugGroup()
    }

    private struct SurfaceLabelScreen {
        let viewportSizePx: SIMD2<Float>
        let pixelsPerPoint: Float
    }

    private enum Surface {
        case flat(FlatRenderState)
        case sphere
    }

    private func draw(_ item: DrawItem,
                      haloPass: Bool,
                      surface: Surface,
                      tileScreenPoints: Double,
                      screen: SurfaceLabelScreen,
                      encoder: MTLRenderCommandEncoder) {
        let record = item.record
        guard record.vertexCount > 0,
              let vertices = item.metalTile.tileBuffers.surfaceLabels.vertices else { return }
        let style = record.style
        let atlasEmTexels = Float(textRenderer.atlasEmTexels(for: style.weight))
        let haloAtlasTexels = style.haloEm * atlasEmTexels
        if haloPass, haloAtlasTexels <= 0 {
            return
        }

        let tile = item.metalTile.tile
        switch surface {
        case .flat(let flatRenderState):
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                             y: tile.y,
                                                                             z: tile.z,
                                                                             worldWrap: item.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0
            var modelMatrix = Matrix.translationMatrix(x: originAndSize.x, y: originAndSize.y, z: 0)
                * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
            encoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
        case .sphere:
            var surfaceTile = GlobeSurfaceTileUniform(tile: tile)
            encoder.setVertexBytes(&surfaceTile, length: MemoryLayout<GlobeSurfaceTileUniform>.stride, index: 9)
        }

        var drawUniform = SurfaceLabelDrawUniform(fillColor: SIMD4<Float>(style.fillColor, 1),
                                                  strokeColor: SIMD4<Float>(style.strokeColor, 1),
                                                  haloAtlasTexels: haloAtlasTexels,
                                                  depth: SurfaceLabelDepth.depth,
                                                  haloPass: haloPass ? 1 : 0,
                                                  tileUnitsPerPoint: SurfaceLabelScale.tileUnitsPerPoint(
                                                      tileZoom: tile.z,
                                                      referenceZoom: record.placement.referenceZoom,
                                                      tileScreenPoints: tileScreenPoints),
                                                  viewportSizePx: screen.viewportSizePx,
                                                  pixelsPerPoint: screen.pixelsPerPoint)
        encoder.setVertexBytes(&drawUniform, length: MemoryLayout<SurfaceLabelDrawUniform>.stride, index: 4)
        encoder.setFragmentBytes(&drawUniform, length: MemoryLayout<SurfaceLabelDrawUniform>.stride, index: 0)
        encoder.setFragmentTexture(style.weight == .thin ? textRenderer.thinTexture : textRenderer.texture, index: 0)
        encoder.setVertexBuffer(vertices.buffer, offset: vertices.offset, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: record.vertexStart, vertexCount: record.vertexCount)
    }

    func handleMemoryWarning() {}

    func evict() {
        drawItems = []
    }
}
