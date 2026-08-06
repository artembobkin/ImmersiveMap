// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

final class RendererLabelDrawer {
    private init() {}

    // Cache of the encoder state actually bound. Metal argument slots live
    // at the encoder level and survive pipeline state changes, so re-setting
    // the same value into the same slot can be skipped: for labels almost all
    // style runs of a batch share the font texture and label shift, and without the cache
    // GPU Frame Capture flagged dozens of such calls as redundant binding.
    private struct EncoderBindings {
        var isPoiPipelineBound = false
        var fragmentTexture: ObjectIdentifier?
        var vertexBuffer0: ObjectIdentifier?
        var labelShift: simd_int1?
        var textStyle: TextStyleUniform?
        var poiIconStyle: PoiIconStyleUniform?
    }

    static func drawBaseLabels(renderEncoder: MTLRenderCommandEncoder,
                               screenMatrix: matrix_float4x4,
                               textRenderer: TextRenderer,
                               poiSpriteAtlas: PoiSpriteAtlas,
                               screenPositionsBuffer: MTLBuffer,
                               labelRuntimeMetaBuffer: MTLBuffer,
                               baseLabelsDrawBatches: [BaseLabelDrawBatch]) {
        var screenMatrixValue = screenMatrix

        renderEncoder.setVertexBytes(&screenMatrixValue, length: MemoryLayout<matrix_float4x4>.stride, index: 1)
        renderEncoder.setVertexBuffer(screenPositionsBuffer, offset: 0, index: 2)
        renderEncoder.setVertexBuffer(labelRuntimeMetaBuffer, offset: 0, index: 6)

        var bindings = EncoderBindings()

        for drawBatch in baseLabelsDrawBatches {
            for poiIconRun in drawBatch.poiIconRuns {
                guard let poiIconVerticesBuffer = poiIconRun.localVerticesBuffer,
                      poiIconRun.localVertexCount > 0 else {
                    continue
                }

                if bindings.isPoiPipelineBound == false {
                    renderEncoder.setRenderPipelineState(textRenderer.pipelines.poiIcon)
                    setFragmentTexture(poiSpriteAtlas.texture, renderEncoder: renderEncoder, bindings: &bindings)
                    bindings.isPoiPipelineBound = true
                }
                let iconStyle = PoiIconStyleUniform(
                    backgroundColor: SIMD4<Float>(poiIconRun.style.fillColor.x,
                                                  poiIconRun.style.fillColor.y,
                                                  poiIconRun.style.fillColor.z,
                                                  1.0),
                    iconColor: SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
                )
                if bindings.poiIconStyle != iconStyle {
                    var iconStyleValue = iconStyle
                    renderEncoder.setFragmentBytes(&iconStyleValue,
                                                   length: MemoryLayout<PoiIconStyleUniform>.stride,
                                                   index: 0)
                    bindings.poiIconStyle = iconStyle
                }
                setVertexBuffer0(poiIconVerticesBuffer, renderEncoder: renderEncoder, bindings: &bindings)
                setLabelShift(simd_int1(drawBatch.globalLabelStart), renderEncoder: renderEncoder, bindings: &bindings)
                renderEncoder.drawPrimitives(type: .triangle,
                                             vertexStart: 0,
                                             vertexCount: poiIconRun.localVertexCount)
            }
        }

        renderEncoder.setRenderPipelineState(textRenderer.pipelines.label)
        drawBaseLabelTextPass(renderEncoder: renderEncoder,
                              textRenderer: textRenderer,
                              baseLabelsDrawBatches: baseLabelsDrawBatches,
                              pass: .outline,
                              bindings: &bindings)
        drawBaseLabelTextPass(renderEncoder: renderEncoder,
                              textRenderer: textRenderer,
                              baseLabelsDrawBatches: baseLabelsDrawBatches,
                              pass: .fill,
                              bindings: &bindings)
    }

    static func drawRoadLabels(renderEncoder: MTLRenderCommandEncoder,
                               screenMatrix: matrix_float4x4,
                               textRenderer: TextRenderer,
                               roadDrawLabels: [DrawRoadLabels]) {
        guard roadDrawLabels.isEmpty == false else {
            return
        }

        renderEncoder.setRenderPipelineState(textRenderer.pipelines.roadLabel)
        var screenMatrixValue = screenMatrix
        renderEncoder.setVertexBytes(&screenMatrixValue, length: MemoryLayout<matrix_float4x4>.stride, index: 1)
        // Identical for all road labels - bound once per pass.
        var glyphShift: simd_int1 = 0
        renderEncoder.setVertexBytes(&glyphShift, length: MemoryLayout<simd_int1>.stride, index: 5)
        var screenOffset = SIMD2<Float>(repeating: 0.0)
        renderEncoder.setVertexBytes(&screenOffset,
                                     length: MemoryLayout<SIMD2<Float>>.stride,
                                     index: 6)

        var bindings = EncoderBindings()
        for drawLabel in roadDrawLabels {
            guard let placementBuffer = drawLabel.placementBuffer,
                  let glyphInputBuffer = drawLabel.glyphInputBuffer,
                  let runtimeMetaBuffer = drawLabel.runtimeMetaBuffer,
                  let localGlyphVerticesBuffer = drawLabel.localGlyphVerticesBuffer,
                  drawLabel.localGlyphVertexCount > 0 else {
                continue
            }

            renderEncoder.setVertexBuffer(placementBuffer, offset: 0, index: 2)
            renderEncoder.setVertexBuffer(glyphInputBuffer, offset: 0, index: 3)
            renderEncoder.setVertexBuffer(runtimeMetaBuffer, offset: 0, index: 4)
            setVertexBuffer0(localGlyphVerticesBuffer, renderEncoder: renderEncoder, bindings: &bindings)

            let style = drawLabel.labelStyle
                ?? LabelTextStyle(key: 0,
                                  fillColor: SIMD3<Float>(0.54, 0.54, 0.52),
                                  strokeColor: SIMD3<Float>(0.54, 0.54, 0.52),
                                  strokeWidthPx: 0.0,
                                  sizePx: 36.0,
                                  weight: .thin)
            let texture = style.weight == .bold ? textRenderer.texture : textRenderer.thinTexture
            setFragmentTexture(texture, renderEncoder: renderEncoder, bindings: &bindings)

            if style.strokeWidthPx > 0.0 {
                let outlineStyle = TextStyleUniform(textColor: style.strokeColor,
                                                    strokeColor: style.strokeColor,
                                                    strokeWidthPx: style.strokeWidthPx)
                setTextStyle(outlineStyle, renderEncoder: renderEncoder, bindings: &bindings)
                renderEncoder.drawPrimitives(type: .triangle,
                                             vertexStart: 0,
                                             vertexCount: drawLabel.localGlyphVertexCount)
            }

            let fillStyle = TextStyleUniform(textColor: style.fillColor,
                                             strokeColor: style.fillColor,
                                             strokeWidthPx: 0.0)
            setTextStyle(fillStyle, renderEncoder: renderEncoder, bindings: &bindings)
            renderEncoder.drawPrimitives(type: .triangle,
                                         vertexStart: 0,
                                         vertexCount: drawLabel.localGlyphVertexCount)
        }
    }

    private enum BaseLabelTextPass {
        case outline
        case fill
    }

    private static func drawBaseLabelTextPass(renderEncoder: MTLRenderCommandEncoder,
                                              textRenderer: TextRenderer,
                                              baseLabelsDrawBatches: [BaseLabelDrawBatch],
                                              pass: BaseLabelTextPass,
                                              bindings: inout EncoderBindings) {
        for drawBatch in baseLabelsDrawBatches {
            for run in drawBatch.labelsByStyleRuns {
                guard let localGlyphVerticesBuffer = run.localGlyphVerticesBuffer,
                      run.localGlyphVertexCount > 0 else {
                    continue
                }

                let style = run.style
                let texture = style.weight == .bold ? textRenderer.texture : textRenderer.thinTexture
                let textStyle: TextStyleUniform
                switch pass {
                case .outline:
                    textStyle = TextStyleUniform(textColor: style.strokeColor,
                                                 strokeColor: style.strokeColor,
                                                 strokeWidthPx: style.strokeWidthPx)
                case .fill:
                    textStyle = TextStyleUniform(textColor: style.fillColor,
                                                 strokeColor: style.fillColor,
                                                 strokeWidthPx: 0.0)
                }

                setFragmentTexture(texture, renderEncoder: renderEncoder, bindings: &bindings)
                setTextStyle(textStyle, renderEncoder: renderEncoder, bindings: &bindings)
                setVertexBuffer0(localGlyphVerticesBuffer, renderEncoder: renderEncoder, bindings: &bindings)
                setLabelShift(simd_int1(drawBatch.globalLabelStart), renderEncoder: renderEncoder, bindings: &bindings)
                renderEncoder.drawPrimitives(type: .triangle,
                                             vertexStart: 0,
                                             vertexCount: run.localGlyphVertexCount)
            }
        }
    }

    private static func setFragmentTexture(_ texture: MTLTexture?,
                                           renderEncoder: MTLRenderCommandEncoder,
                                           bindings: inout EncoderBindings) {
        guard let texture else { return }
        let identity = ObjectIdentifier(texture)
        guard bindings.fragmentTexture != identity else { return }
        renderEncoder.setFragmentTexture(texture, index: 0)
        bindings.fragmentTexture = identity
    }

    private static func setVertexBuffer0(_ buffer: MTLBuffer,
                                         renderEncoder: MTLRenderCommandEncoder,
                                         bindings: inout EncoderBindings) {
        let identity = ObjectIdentifier(buffer)
        guard bindings.vertexBuffer0 != identity else { return }
        renderEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
        bindings.vertexBuffer0 = identity
    }

    private static func setLabelShift(_ shift: simd_int1,
                                      renderEncoder: MTLRenderCommandEncoder,
                                      bindings: inout EncoderBindings) {
        guard bindings.labelShift != shift else { return }
        var shiftValue = shift
        renderEncoder.setVertexBytes(&shiftValue, length: MemoryLayout<simd_int1>.stride, index: 3)
        bindings.labelShift = shift
    }

    private static func setTextStyle(_ textStyle: TextStyleUniform,
                                     renderEncoder: MTLRenderCommandEncoder,
                                     bindings: inout EncoderBindings) {
        guard bindings.textStyle != textStyle else { return }
        var textStyleValue = textStyle
        renderEncoder.setFragmentBytes(&textStyleValue,
                                       length: MemoryLayout<TextStyleUniform>.stride,
                                       index: 0)
        bindings.textStyle = textStyle
    }
}
