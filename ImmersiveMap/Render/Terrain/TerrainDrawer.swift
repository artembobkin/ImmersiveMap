// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum TerrainDrawMode: UInt32 {
    case flat = 0
    case spherical = 1
}

struct TerrainDrawUniform {
    var modelMatrix: matrix_float4x4
    var renderMode: UInt32
    var padding: SIMD3<UInt32> = SIMD3<UInt32>(repeating: 0)
}

enum TerrainDrawer {
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     globe: GlobeUniform,
                     terrain: ImmersiveMapSettings.TerrainSettings,
                     visibleTiles: [VisibleTile],
                     renderSurfaceMode: ViewMode,
                     flatRenderState: FlatRenderState,
                     terrainPipeline: TerrainPipeline,
                     terrainTileStore: TerrainTileStore,
                     isWireframeEnabled: Bool) {
        let drawItems = terrainTileStore.drawItems(visibleTiles: visibleTiles,
                                                   terrain: terrain,
                                                   renderSurfaceMode: renderSurfaceMode,
                                                   globeRadius: globe.radius)
        guard drawItems.isEmpty == false else {
            return
        }

        var cameraUniformValue = cameraUniform
        var globeValue = globe
        terrainPipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setCullMode(.none)
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.lines)
        }
        renderEncoder.setVertexBytes(&cameraUniformValue,
                                     length: MemoryLayout<CameraUniform>.stride,
                                     index: 1)
        renderEncoder.setVertexBytes(&globeValue,
                                     length: MemoryLayout<GlobeUniform>.stride,
                                     index: 3)

        for item in drawItems {
            draw(item: item,
                 renderEncoder: renderEncoder,
                 renderSurfaceMode: renderSurfaceMode,
                 flatRenderState: flatRenderState)
        }

        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.fill)
        }
    }

    private static func draw(item: TerrainTileDrawItem,
                             renderEncoder: MTLRenderCommandEncoder,
                             renderSurfaceMode: ViewMode,
                             flatRenderState: FlatRenderState) {
        var uniform = TerrainDrawUniform(modelMatrix: modelMatrix(for: item,
                                                                  renderSurfaceMode: renderSurfaceMode,
                                                                  flatRenderState: flatRenderState),
                                         renderMode: drawMode(for: renderSurfaceMode).rawValue)
        renderEncoder.setVertexBuffer(item.mesh.vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBytes(&uniform,
                                     length: MemoryLayout<TerrainDrawUniform>.stride,
                                     index: 2)
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: item.mesh.indexCount,
                                            indexType: .uint32,
                                            indexBuffer: item.mesh.indexBuffer,
                                            indexBufferOffset: 0)
    }

    private static func modelMatrix(for item: TerrainTileDrawItem,
                                    renderSurfaceMode: ViewMode,
                                    flatRenderState: FlatRenderState) -> matrix_float4x4 {
        guard renderSurfaceMode == .flat else {
            return matrix_identity_float4x4
        }

        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: item.sourceTile.x,
                                                                         y: item.sourceTile.y,
                                                                         z: item.sourceTile.z,
                                                                         loop: item.visibleTile.loop,
                                                                         flatRenderPan: flatRenderState.pan,
                                                                         renderMapSize: flatRenderState.renderMapSize)
        let scale = originAndSize.z / 4096.0
        return Matrix.translationMatrix(x: originAndSize.x,
                                        y: originAndSize.y,
                                        z: 0)
            * Matrix.scaleMatrix(sx: scale, sy: scale, sz: scale)
    }

    private static func drawMode(for renderSurfaceMode: ViewMode) -> TerrainDrawMode {
        switch renderSurfaceMode {
        case .flat:
            return .flat
        case .spherical:
            return .spherical
        }
    }
}
