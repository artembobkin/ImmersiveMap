// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum BuildingExtrusionDrawer {
    private struct ExtrudedLightUniform {
        var direction: SIMD4<Float>
        var color: SIMD4<Float>
        var intensities: SIMD4<Float>
    }

    private struct ExtrudedMaterialUniform {
        var alpha: Float
        var padding: SIMD3<Float> = .zero
    }

    static func drawColorPass(renderEncoder: MTLRenderCommandEncoder,
                              cameraUniform: CameraUniform,
                              placeTilesContext: PlaceTilesContext,
                              flatRenderState: FlatRenderState,
                              buildingExtrusionAlpha: Float,
                              winnerIDTexture: MTLTexture?,
                              extrudedTilePipeline: ExtrudedTilePipeline,
                              extrudedColorPassDepthState: MTLDepthStencilState,
                              depthDisabledState: MTLDepthStencilState) {
        guard let winnerIDTexture else { return }

        var cameraUniformValue = cameraUniform
        renderEncoder.setCullMode(.back)

        extrudedTilePipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setDepthStencilState(extrudedColorPassDepthState)
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setFragmentTexture(winnerIDTexture, index: 0)
        renderEncoder.setFragmentBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)

        let lightDirection = simd_normalize(SIMD3<Float>(-0.4, -0.6, 1.0))
        var lightUniform = ExtrudedLightUniform(
            direction: SIMD4<Float>(lightDirection, 0.0),
            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
            intensities: SIMD4<Float>(0.35, 0.65, 0.2, 24.0)
        )
        var materialUniform = ExtrudedMaterialUniform(alpha: buildingExtrusionAlpha)
        renderEncoder.setFragmentBytes(&lightUniform, length: MemoryLayout<ExtrudedLightUniform>.stride, index: 2)
        renderEncoder.setFragmentBytes(&materialUniform, length: MemoryLayout<ExtrudedMaterialUniform>.stride, index: 3)
        drawExtrudedGeometry(renderEncoder: renderEncoder,
                             placeTilesContext: placeTilesContext,
                             flatRenderState: flatRenderState)

        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    static func drawWinnerLayer(renderEncoder: MTLRenderCommandEncoder,
                                cameraUniform: CameraUniform,
                                placeTilesContext: PlaceTilesContext,
                                flatRenderState: FlatRenderState,
                                extrudedTilePipeline: ExtrudedTilePipeline,
                                extrudedDepthState: MTLDepthStencilState) {
        var cameraUniformValue = cameraUniform
        renderEncoder.setCullMode(.back)
        renderEncoder.setDepthStencilState(extrudedDepthState)
        extrudedTilePipeline.selectWinnerPipeline(renderEncoder: renderEncoder)
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        drawExtrudedGeometry(renderEncoder: renderEncoder,
                             placeTilesContext: placeTilesContext,
                             flatRenderState: flatRenderState)
    }

    private static func drawExtrudedGeometry(renderEncoder: MTLRenderCommandEncoder,
                                             placeTilesContext: PlaceTilesContext,
                                             flatRenderState: FlatRenderState) {
        var isBackCullingEnabled = true
        for placeTile in placeTilesContext.tilePlacements {
            let metalTile = placeTile.metalTile
            let tile = metalTile.tile
            let buffers = metalTile.tileBuffers
            let placeIn = placeTile.placeIn

            guard buffers.extruded.indicesCount > 0 else { continue }

            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                             y: tile.y,
                                                                             z: tile.z,
                                                                             loop: placeIn.loop,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0

            renderEncoder.setVertexBuffer(buffers.extruded.verticesBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBuffer(buffers.extruded.stylesBuffer, offset: 0, index: 2)

            // Клип фрагментов к слоту placeIn - и в winner-препассе, и в цветовом
            // пассе: здания retained-родителя не должны перекрывать соседние тайлы.
            var localClipBounds = TileLocalClipMath.clipBounds(source: tile, placeIn: placeIn.tile)
            renderEncoder.setFragmentBytes(&localClipBounds,
                                           length: MemoryLayout<SIMD4<Float>>.stride,
                                           index: 4)

            // Клип режет здание вертикальной плоскостью без закрывающей грани:
            // при отсечении back-faces срез выглядит «полым» насквозь. Для
            // клипнутых размещений рисуем и внутренние стены - тёмный срез
            // вместо дыры.
            let isClipped = localClipBounds != TileLocalClipMath.disabledBounds
            if isClipped == isBackCullingEnabled {
                isBackCullingEnabled = !isClipped
                renderEncoder.setCullMode(isBackCullingEnabled ? .back : .none)
            }

            var modelMatrix = Matrix.translationMatrix(
                x: originAndSize.x,
                y: originAndSize.y,
                z: 0
            ) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: scale)
            renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)

            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: buffers.extruded.indicesCount,
                                                indexType: .uint32,
                                                indexBuffer: buffers.extruded.indicesBuffer,
                                                indexBufferOffset: 0)
        }
    }
}
