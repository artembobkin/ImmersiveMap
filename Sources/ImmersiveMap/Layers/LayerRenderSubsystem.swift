// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The `Layers` folder: the layers of the app's own data drawn over the map
/// (`ImmersiveMapLayer`), from the public model and its GeoJSON reading to
/// the meshes (`LayerMeshBuilder`, `LayerMeshStore`), the pipelines and
/// the shaders, and this subsystem. The data comes in with the settings
/// (`ImmersiveMapSettings.layers`), read every frame. Nothing here knows the
/// map's tiles, its schema or its style.
///
/// Draws the layers on the ground of whichever surface the frame shows: in
/// the flat map's roads layer, after the roads and the trees' shadows, and
/// in the globe's surface layer, after its ground, so the labels painted on
/// the map come over them on both. A layer draws its zones, then its lines
/// and their joins, then its points, the layers in the order they are set.
/// On the flat map a chunk draws in the copy of the world nearest the
/// camera, and in its neighbours too at the zooms that show more than one.
/// A layer is not tested against the ground's depth unless it asks to be
/// (`ImmersiveMapLayer.hidesBehindTerrain`): the buildings, the models and
/// the trees cover it through the surface mask bit they raise in the
/// stencil (`LayerPipeline.overGroundState`).
final class LayerRenderSubsystem: RenderSubsystem {
    let name: String = "Layers"

    private let store: LayerMeshStore
    private let pipeline: LayerPipeline
    private let depthDisabledState: MTLDepthStencilState
    /// The frame's layers that draw, each with whether the terrain hides it.
    private var drawn: [(mesh: LayerMesh, hidesBehindTerrain: Bool)] = []

    /// The camera zoom under which the flat map can show more than one copy
    /// of the world across the view.
    static let wrappedCopiesBelowZoom: Double = 4

    init(store: LayerMeshStore,
         pipeline: LayerPipeline,
         depthDisabledState: MTLDepthStencilState) {
        self.store = store
        self.pipeline = pipeline
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext: FrameContext) {
        let layers = frameContext.services.settings.layers
        // Every layer is kept built, a hidden one too, so showing it again
        // is immediate.
        let meshes = store.meshes(for: layers)
        let zoom = frameContext.planningZoom
        drawn = zip(layers, meshes).compactMap { layer, mesh in
            guard layer.isVisible, layer.zoomRange.contains(zoom), let mesh, mesh.chunks.isEmpty == false else {
                return nil
            }
            return (mesh, layer.hidesBehindTerrain)
        }
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard drawn.isEmpty == false else { return }
        let surface: LayerPipeline.Surface
        switch (layer, frameContext.renderSurfaceMode) {
        case (.flatMapRoads, .flat):
            surface = .flat
        case (.globeVectorSurface, .spherical):
            let globe = frameContext.globeRenderUniform
            surface = GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                          transition: globe.transition) ? .sphere : .morph
        default:
            return
        }

        encoder.pushDebugGroup("layers")
        var cameraUniform = frameContext.cameraUniform
        var globe = frameContext.globeRenderUniform
        var globeFrame = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: cameraUniform.matrix)
        encoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        encoder.setVertexBytes(&globe, length: MemoryLayout<GlobeUniform>.stride, index: 8)
        encoder.setVertexBytes(&globeFrame, length: MemoryLayout<GlobeFrameConstantsUniform>.stride, index: 10)
        GlobeLightUniform.bind(GlobeLightUniform.resolve(frameContext: frameContext), encoder: encoder)
        GroundFogUniform.bind(GroundFogUniform.resolve(frameContext: frameContext), encoder: encoder)
        encoder.setStencilReferenceValue(0)
        // A zone's triangles are counter-clockwise in render space, as the
        // ground's: culling the back faces removes the far side of the
        // planet. A line's and a point's quads are cut there instead.
        encoder.setFrontFacing(.counterClockwise)

        let placements = chunkPlacements(frameContext: frameContext, surface: surface)
        let states = pipeline.states(for: surface)
        for (mesh, hidesBehindTerrain) in drawn {
            encoder.setDepthStencilState(hidesBehindTerrain ? pipeline.behindTerrainState : pipeline.overGroundState)
            if let vertices = mesh.fillVertices, let indices = mesh.fillIndices {
                encoder.setCullMode(.back)
                encoder.setRenderPipelineState(states.fill)
                encoder.setVertexBuffer(vertices, offset: 0, index: 0)
                for chunk in mesh.chunks where chunk.fillIndexCount > 0 {
                    for var draw in placements(chunk) {
                        encoder.setVertexBytes(&draw, length: MemoryLayout<LayerDrawUniform>.stride, index: 2)
                        encoder.drawIndexedPrimitives(type: .triangle,
                                                      indexCount: chunk.fillIndexCount,
                                                      indexType: .uint32,
                                                      indexBuffer: indices,
                                                      indexBufferOffset: chunk.fillIndexStart * MemoryLayout<UInt32>.stride)
                    }
                }
            }
            encoder.setCullMode(.none)
            if let vertices = mesh.lineVertices, let indices = mesh.lineIndices {
                encoder.setRenderPipelineState(states.line)
                encoder.setVertexBuffer(vertices, offset: 0, index: 0)
                for chunk in mesh.chunks where chunk.lineIndexCount > 0 {
                    for var draw in placements(chunk) {
                        encoder.setVertexBytes(&draw, length: MemoryLayout<LayerDrawUniform>.stride, index: 2)
                        encoder.drawIndexedPrimitives(type: .triangle,
                                                      indexCount: chunk.lineIndexCount,
                                                      indexType: .uint32,
                                                      indexBuffer: indices,
                                                      indexBufferOffset: chunk.lineIndexStart * MemoryLayout<UInt32>.stride)
                    }
                }
            }
            if let discs = mesh.discs {
                encoder.setRenderPipelineState(states.point)
                encoder.setVertexBuffer(discs, offset: 0, index: 0)
                // The lines' joins with the lines, then the points over them.
                for pass in 0 ..< 2 {
                    for chunk in mesh.chunks {
                        let start = pass == 0 ? chunk.joinStart : chunk.pointStart
                        let count = pass == 0 ? chunk.joinCount : chunk.pointCount
                        guard count > 0 else { continue }
                        for var draw in placements(chunk) {
                            encoder.setVertexBytes(&draw, length: MemoryLayout<LayerDrawUniform>.stride, index: 2)
                            encoder.drawPrimitives(type: .triangle,
                                                   vertexStart: 0,
                                                   vertexCount: 6,
                                                   instanceCount: count,
                                                   baseInstance: start)
                        }
                    }
                }
            }
        }

        encoder.setCullMode(.none)
        encoder.setFrontFacing(.clockwise)
        encoder.setDepthStencilState(depthDisabledState)
        encoder.popDebugGroup()
    }

    /// The draw states of a chunk this frame: one per copy of the world it
    /// draws in on the flat map, one on the globe.
    private func chunkPlacements(frameContext: FrameContext,
                                 surface: LayerPipeline.Surface) -> (LayerMeshChunk) -> [LayerDrawUniform] {
        let viewport = SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height))
        let pixelsPerPoint = Float(frameContext.pixelsPerPoint)
        guard surface == .flat else {
            return { chunk in
                let tileUniform = GlobeSurfaceTileUniform(tile: chunk.tile)
                return [LayerDrawUniform(modelMatrix: matrix_identity_float4x4,
                                         uvOrigin: tileUniform.uvOrigin,
                                         uvScale: tileUniform.uvScale,
                                         referenceWorldX: tileUniform.referenceWorldX,
                                         viewportSizePx: viewport,
                                         pixelsPerPoint: pixelsPerPoint,
                                         depth: LayerDepth.depth)]
            }
        }
        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        let cameraX = frameContext.mapCameraState.centerWorldMercator.x
        let copies: [Int] = frameContext.planningZoom < Self.wrappedCopiesBelowZoom ? [-1, 0, 1] : [0]
        return { chunk in
            let count = Double(1 << chunk.tile.z)
            let centreX = (Double(chunk.tile.x) + 0.5) / count
            let nearest = Int((cameraX - centreX).rounded())
            return copies.map { offset in
                let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: chunk.tile.x,
                                                                                 y: chunk.tile.y,
                                                                                 z: chunk.tile.z,
                                                                                 worldWrap: Int8(clamping: nearest + offset),
                                                                                 flatRenderPan: flatRenderState.pan,
                                                                                 renderMapSize: flatRenderState.renderMapSize)
                let scale = originAndSize.z / Float(TileCoordinateSpace.tileExtent)
                return LayerDrawUniform(modelMatrix: Matrix.translationMatrix(x: originAndSize.x, y: originAndSize.y, z: 0)
                                            * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1),
                                        uvOrigin: .zero,
                                        uvScale: 0,
                                        referenceWorldX: 0,
                                        viewportSizePx: viewport,
                                        pixelsPerPoint: pixelsPerPoint,
                                        depth: LayerDepth.depth)
            }
        }
    }

    func handleMemoryWarning() {}

    func evict() {}
}
