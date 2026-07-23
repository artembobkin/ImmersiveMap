// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

struct TileOverlayLineSegment {
    let start: SIMD2<Float>
    let end: SIMD2<Float>
}

struct TileWatermarkScreenPlacement: Equatable {
    let xAxis: SIMD2<Float>
    let yAxis: SIMD2<Float>
}

final class DebugOverlayRenderer {
    private var settings: ImmersiveMapSettings.DebugSettings
    private let axesVertexBuffer: MTLBuffer
    private let axesVerticesCount: Int
    private let tileTextVertexBufferStore: FrameSlottedDynamicMetalBuffer<TextVertex>
    private let lineVertexBufferStore: FrameSlottedDynamicMetalBuffer<PolygonsPipeline.Vertex>
    private let tilePointScreenProjector = TilePointScreenProjector()
    private var textVerticesScratch: [TextVertex] = []
    private var lineVerticesScratch: [PolygonsPipeline.Vertex] = []
    private var tileTextEntriesScratch: [TextEntry] = []
    private var tileProjectedTextVerticesScratch: [TextVertex] = []
    private var tileWatermarkProjectionInputsScratch: [TilePointInput] = []
    private var tileWatermarkVertexInputsScratch: [TilePointInput] = []
    private let tileOutlineThicknessPx: Float = 3.5
    private let tileLabelInsetPx = SIMD2<Float>(8.0, 8.0)
    private let tileWatermarkMaxWidthUV: Float = 0.22
    private let tileWatermarkMaxHeightUV: Float = 0.04
    private let tileWatermarkPaddingPx = SIMD2<Float>(8.0, 4.0)
    private let tileLabelTextColor = SIMD3<Float>(1.0, 0.95, 0.2)
    private let tileLabelStrokeColor = SIMD3<Float>(0.0, 0.0, 0.0)
    private let tileLabelStrokeWidthPx: Float = 5.0
    private let tileOutlineColor = SIMD4<Float>(1.0, 0.95, 0.2, 0.95)
    private let roadLabelTileOutlineColor = SIMD4<Float>(0.0, 0.85, 1.0, 0.95)
    private let labelBoundsVisibleColor = SIMD4<Float>(0.2, 1.0, 0.35, 0.9)
    private let labelBoundsHiddenColor = SIMD4<Float>(1.0, 0.25, 0.2, 0.9)
    private let roadLabelBoundsVisibleColor = SIMD4<Float>(0.0, 0.85, 1.0, 0.9)
    private let roadLabelBoundsHiddenColor = SIMD4<Float>(1.0, 0.65, 0.1, 0.9)
    private let labelBoundsThicknessPx: Float = 1.5
    private static let tileWatermarkUVs = makeTileWatermarkUVs()

    init(metalDevice: MTLDevice,
         settings: ImmersiveMapSettings.DebugSettings) {
        self.settings = settings
        self.tileTextVertexBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                        slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                        options: [.storageModeShared],
                                                                        minimumCapacity: 512)
        self.lineVertexBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                    slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                    options: [.storageModeShared],
                                                                    minimumCapacity: 512)
        let axesVertices: [PolygonsPipeline.Vertex] = [
            PolygonsPipeline.Vertex(position: SIMD4<Float>(0.0, 0.0, 0.0, 1.0), color: SIMD4<Float>(1, 0, 0, 1)),
            PolygonsPipeline.Vertex(position: SIMD4<Float>(1.0, 0.0, 0.0, 1.0), color: SIMD4<Float>(1, 0, 0, 1)),

            PolygonsPipeline.Vertex(position: SIMD4<Float>(0.0, 0.0, 0.0, 1.0), color: SIMD4<Float>(0, 1, 0, 1)),
            PolygonsPipeline.Vertex(position: SIMD4<Float>(0.0, 1.0, 0.0, 1.0), color: SIMD4<Float>(0, 1, 0, 1)),

            PolygonsPipeline.Vertex(position: SIMD4<Float>(0.0, 0.0, 0.0, 1.0), color: SIMD4<Float>(0, 0, 1, 1)),
            PolygonsPipeline.Vertex(position: SIMD4<Float>(0.0, 0.0, 1.0, 1.0), color: SIMD4<Float>(0, 0, 1, 1)),
        ]
        axesVerticesCount = axesVertices.count
        axesVertexBuffer = metalDevice.makeBuffer(bytes: axesVertices,
                                                  length: axesVertices.count * MemoryLayout<PolygonsPipeline.Vertex>.stride,
                                                  options: [])!
    }

    convenience init(metalDevice: MTLDevice) {
        self.init(metalDevice: metalDevice, settings: ImmersiveMapSettings.default.debug)
    }

    func apply(settings: ImmersiveMapSettings.DebugSettings) {
        self.settings = settings
    }

    static func makeCoordinateTextLines(zoom: Double,
                                        latitude: Double,
                                        longitude: Double,
                                        locale: Locale = Locale(identifier: "en_US_POSIX")) -> (zoom: String, latLon: String) {
        let numberStyle = FloatingPointFormatStyle<Double>.number.locale(locale)
        let zoomLine = "z: \(zoom.formatted(numberStyle.precision(.fractionLength(2))))"
        let latText = latitude.formatted(numberStyle.precision(.fractionLength(3)))
        let lonText = longitude.formatted(numberStyle.precision(.fractionLength(3)))
        return (zoom: zoomLine, latLon: "lat: \(latText) lon: \(lonText)")
    }

    func drawAxes(renderEncoder: MTLRenderCommandEncoder,
                  polygonPipeline: PolygonsPipeline,
                  cameraUniform: CameraUniform) {
        polygonPipeline.setPipelineState(renderEncoder: renderEncoder)
        renderEncoder.setVertexBuffer(axesVertexBuffer, offset: 0, index: 0)
        var uniform = cameraUniform
        renderEncoder.setVertexBytes(&uniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: axesVerticesCount)
    }

    func drawTileOverlay(renderEncoder: MTLRenderCommandEncoder,
                         polygonPipeline: PolygonsPipeline,
                         textRenderer: TextRenderer,
                         frameContext: FrameContext,
                         placeTiles: [PlaceTile]) {
        guard placeTiles.isEmpty == false else { return }

        tileTextEntriesScratch.removeAll(keepingCapacity: true)
        tileProjectedTextVerticesScratch.removeAll(keepingCapacity: true)
        tileWatermarkProjectionInputsScratch.removeAll(keepingCapacity: true)
        lineVerticesScratch.removeAll(keepingCapacity: true)
        tileTextEntriesScratch.reserveCapacity(placeTiles.count * 10)
        tileProjectedTextVerticesScratch.reserveCapacity(placeTiles.count * 9 * 96)
        tileWatermarkProjectionInputsScratch.reserveCapacity(Self.tileWatermarkUVs.count * 3)
        lineVerticesScratch.reserveCapacity(placeTiles.count * 64)

        let labelScale = max(settings.diagnosticsScale * 0.5, 28.0)
        let labelLineAdvance = makeLineAdvance(textRenderer: textRenderer, scale: labelScale)
        let outlineSegments = Self.makeTileOverlaySegments(segmentCountPerEdge: frameContext.screenSpaceProjectionMode == .flat ? 1 : 8)

        for placeTile in placeTiles {
            appendTileOutlineVertices(into: &lineVerticesScratch,
                                      placeTile: placeTile,
                                      outlineSegments: outlineSegments,
                                      frameContext: frameContext,
                                      color: tileOutlineColor)
            appendTileTextEntries(into: &tileTextEntriesScratch,
                                  projectedVertices: &tileProjectedTextVerticesScratch,
                                  placeTile: placeTile,
                                  frameContext: frameContext,
                                  scale: labelScale,
                                  lineAdvance: labelLineAdvance,
                                  textRenderer: textRenderer)
        }

        if lineVerticesScratch.isEmpty == false {
            drawLineVertices(renderEncoder: renderEncoder,
                             polygonPipeline: polygonPipeline,
                             screenMatrix: frameContext.cameraMatrices.screen,
                             frameSlotIndex: frameContext.frameSlotIndex,
                             vertices: lineVerticesScratch)
        }
        if tileTextEntriesScratch.isEmpty == false {
            drawTextEntries(renderEncoder: renderEncoder,
                            textRenderer: textRenderer,
                            screenMatrix: frameContext.cameraMatrices.screen,
                            frameSlotIndex: frameContext.frameSlotIndex,
                            entries: tileTextEntriesScratch,
                            style: TextStyleUniform(textColor: tileLabelTextColor,
                                                    strokeColor: tileLabelStrokeColor,
                                                    strokeWidthPx: tileLabelStrokeWidthPx))
        }
        if tileProjectedTextVerticesScratch.isEmpty == false {
            drawTextEntries(renderEncoder: renderEncoder,
                            textRenderer: textRenderer,
                            screenMatrix: frameContext.cameraMatrices.screen,
                            frameSlotIndex: frameContext.frameSlotIndex,
                            entries: [],
                            projectedVertices: tileProjectedTextVerticesScratch,
                            style: Self.makeTileWatermarkTextStyle())
        }
    }

    func drawRoadLabelTileOverlay(renderEncoder: MTLRenderCommandEncoder,
                                  polygonPipeline: PolygonsPipeline,
                                  frameContext: FrameContext,
                                  placeTiles: [PlaceTile]) {
        guard placeTiles.isEmpty == false else { return }

        lineVerticesScratch.removeAll(keepingCapacity: true)
        lineVerticesScratch.reserveCapacity(placeTiles.count * 64)

        let outlineSegments = Self.makeTileOverlaySegments(segmentCountPerEdge: frameContext.screenSpaceProjectionMode == .flat ? 1 : 8)
        for placeTile in placeTiles {
            appendTileOutlineVertices(into: &lineVerticesScratch,
                                      placeTile: placeTile,
                                      outlineSegments: outlineSegments,
                                      frameContext: frameContext,
                                      color: roadLabelTileOutlineColor)
        }

        if lineVerticesScratch.isEmpty == false {
            drawLineVertices(renderEncoder: renderEncoder,
                             polygonPipeline: polygonPipeline,
                             screenMatrix: frameContext.cameraMatrices.screen,
                             frameSlotIndex: frameContext.frameSlotIndex,
                             vertices: lineVerticesScratch)
        }
    }

    /// Рамки всех лейблов кадра в экранных координатах: видимые и спрятанные
    /// (коллизией, горизонтом лейбла или фейдом). Базовые лейблы зелёные и
    /// красные, дорожные (по глифу на рамку) голубые и оранжевые: они
    /// участвуют в том же коллизионном решателе. Даёт визуальную оценку
    /// общего количества лейблов, участвующих в кадре.
    func drawLabelBoundsOverlay(renderEncoder: MTLRenderCommandEncoder,
                                polygonPipeline: PolygonsPipeline,
                                frameContext: FrameContext,
                                boxesState: BaseLabelDebugBoxesState) {
        guard boxesState.boxes.isEmpty == false || boxesState.roadBoxes.isEmpty == false else { return }

        lineVerticesScratch.removeAll(keepingCapacity: true)
        lineVerticesScratch.reserveCapacity((boxesState.boxes.count + boxesState.roadBoxes.count) * 24)

        appendLabelBoundsVertices(boxes: boxesState.boxes,
                                  visibleColor: labelBoundsVisibleColor,
                                  hiddenColor: labelBoundsHiddenColor)
        appendLabelBoundsVertices(boxes: boxesState.roadBoxes,
                                  visibleColor: roadLabelBoundsVisibleColor,
                                  hiddenColor: roadLabelBoundsHiddenColor)

        if lineVerticesScratch.isEmpty == false {
            drawLineVertices(renderEncoder: renderEncoder,
                             polygonPipeline: polygonPipeline,
                             screenMatrix: frameContext.cameraMatrices.screen,
                             frameSlotIndex: frameContext.frameSlotIndex,
                             vertices: lineVerticesScratch)
        }
    }

    private func appendLabelBoundsVertices(boxes: [BaseLabelDebugBox],
                                           visibleColor: SIMD4<Float>,
                                           hiddenColor: SIMD4<Float>) {
        for box in boxes {
            guard box.halfSize.x > 0, box.halfSize.y > 0 else { continue }
            let color = box.isVisible ? visibleColor : hiddenColor
            let minCorner = box.center - box.halfSize
            let maxCorner = box.center + box.halfSize
            let corners = [
                SIMD2<Float>(minCorner.x, minCorner.y),
                SIMD2<Float>(maxCorner.x, minCorner.y),
                SIMD2<Float>(maxCorner.x, maxCorner.y),
                SIMD2<Float>(minCorner.x, maxCorner.y)
            ]
            for index in 0..<4 {
                appendThickLineQuad(into: &lineVerticesScratch,
                                    start: corners[index],
                                    end: corners[(index + 1) % 4],
                                    thickness: labelBoundsThicknessPx,
                                    color: color)
            }
        }
    }

    private func drawTextEntries(renderEncoder: MTLRenderCommandEncoder,
                                 textRenderer: TextRenderer,
                                 screenMatrix: matrix_float4x4,
                                 frameSlotIndex: Int,
                                 entries: [TextEntry],
                                 projectedVertices: [TextVertex] = [],
                                 style: TextStyleUniform? = nil) {
        guard entries.isEmpty == false || projectedVertices.isEmpty == false else { return }
        textRenderer.collectMultiTextVertices(into: &textVerticesScratch, for: entries)
        textVerticesScratch.append(contentsOf: projectedVertices)
        guard textVerticesScratch.isEmpty == false else { return }

        var textStyle = style ?? TextStyleUniform(textColor: settings.textColor)
        var matrix = screenMatrix
        renderEncoder.setRenderPipelineState(textRenderer.pipelineState)
        setTileTextVertices(renderEncoder: renderEncoder,
                            vertices: textVerticesScratch,
                            frameSlotIndex: frameSlotIndex)
        renderEncoder.setVertexBytes(&matrix, length: MemoryLayout<matrix_float4x4>.stride, index: 1)
        renderEncoder.setFragmentTexture(textRenderer.texture, index: 0)
        renderEncoder.setFragmentBytes(&textStyle, length: MemoryLayout<TextStyleUniform>.stride, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: textVerticesScratch.count)
    }

    private func drawLineVertices(renderEncoder: MTLRenderCommandEncoder,
                                  polygonPipeline: PolygonsPipeline,
                                  screenMatrix: matrix_float4x4,
                                  frameSlotIndex: Int,
                                  vertices: [PolygonsPipeline.Vertex]) {
        guard vertices.isEmpty == false else { return }
        polygonPipeline.setPipelineState(renderEncoder: renderEncoder)
        setLineVertices(renderEncoder: renderEncoder,
                        vertices: vertices,
                        frameSlotIndex: frameSlotIndex)
        var screenUniform = CameraUniform(matrix: screenMatrix,
                                          eye: .zero,
                                          padding: 0.0)
        renderEncoder.setVertexBytes(&screenUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    static func makeOverlayDiagnosticsTextLines(cameraDebugLines: [String],
                                                diagnostics: FrameDiagnostics?,
                                                memorySnapshot: ProcessMemorySnapshot? = ProcessMemoryReader.current()) -> [String] {
        guard let diagnostics else {
            return cameraDebugLines
        }
        var lines: [String] = []
        appendSection(title: "Camera", body: cameraDebugLines, into: &lines)
        appendDiagnosticsSections(from: diagnostics,
                                  memorySnapshot: memorySnapshot,
                                  into: &lines)
        return lines
    }

    private static func appendDiagnosticsSections(from diagnostics: FrameDiagnostics,
                                                  memorySnapshot: ProcessMemorySnapshot?,
                                                  into lines: inout [String]) {
        let frameTimeText = String(format: "%.2f", diagnostics.frameTime)
        let fpsText = diagnostics.frameTime > 0
            ? String(format: "%.1f", 1000.0 / diagnostics.frameTime)
            : "--"
        let frameLine = "frame:\(diagnostics.frameIndex) dt:\(frameTimeText)ms fps:\(fpsText)"
        let memoryLine = memorySnapshot.map { snapshot in
            "memory ram:\(String(format: "%.1f", snapshot.physicalFootprintMegabytes))MB"
        }
        appendSection(title: "Frame",
                      body: [frameLine, memoryLine].compactMap(\.self),
                      into: &lines)

        let tileLine = "vis:\(diagnostics.counterValue(.visibleTiles)) " +
            "ready:\(diagnostics.counterValue(.readyTiles)) " +
            "req:\(diagnostics.counterValue(.requestedTiles)) " +
            "draw:\(diagnostics.counterValue(.renderedTiles))"
        appendSection(title: "Tiles", body: [tileLine], into: &lines)

        let labelLine = "base:\(diagnostics.counterValue(.baseLabelCount)) " +
            "bT:\(diagnostics.counterValue(.baseLabelFullTileCount))/" +
            "\(diagnostics.counterValue(.baseLabelReducedTileCount))/" +
            "\(diagnostics.counterValue(.baseLabelMinimalTileCount)) " +
            "roadG:\(diagnostics.counterValue(.roadLabelGlyphCount)) " +
            "roadI:\(diagnostics.counterValue(.roadLabelInstanceCount)) " +
            "roadCull:\(diagnostics.counterValue(.roadLabelNearCameraCulledPathCount))/" +
            "\(diagnostics.counterValue(.roadLabelNearCameraCulledAnchorCount))"
        appendSection(title: "Labels", body: [labelLine], into: &lines)

        let resourcesLine = "buffers:\(diagnostics.counterValue(.resourceBufferCount)) " +
            "textures:\(diagnostics.counterValue(.resourceTextureCount)) " +
            "pipelines:\(diagnostics.counterValue(.resourcePipelineCount))"
        appendSection(title: "Resources", body: [resourcesLine], into: &lines)

        let globeCullingMs = String(format: "%.2f", diagnostics.measurementValue(.globeCullingDurationMs))
        let globeCullingLine = "ms:\(globeCullingMs) " +
            "nodes:\(diagnostics.counterValue(.globeCullingVisitedNodes)) " +
            "frustum:\(diagnostics.counterValue(.globeCullingFrustumRejects)) " +
            "horizon:\(diagnostics.counterValue(.globeCullingHorizonRejects)) " +
            "leaf:\(diagnostics.counterValue(.globeCullingAcceptedLeafTiles)) " +
            "subtree:\(diagnostics.counterValue(.globeCullingAcceptedWholeSubtrees))"
        appendSection(title: "Globe culling", body: [globeCullingLine], into: &lines)

        let skipBody: String
        if diagnostics.skipReasons.isEmpty {
            skipBody = "none"
        } else {
            let reasons = diagnostics.skipReasons.map(\.rawValue).sorted().joined(separator: ",")
            skipBody = reasons
        }
        appendSection(title: "Skip", body: [skipBody], into: &lines)
    }

    private static func appendSection(title: String, body: [String], into lines: inout [String]) {
        guard body.isEmpty == false else { return }
        if lines.isEmpty == false {
            lines.append("")
        }
        lines.append("[\(title)]")
        lines.append(contentsOf: body)
    }

    private func makeLineAdvance(textRenderer: TextRenderer, scale: Float) -> Float {
        let atlasLineHeight = Float(textRenderer.atlasData.metrics.lineHeight)
        return max((atlasLineHeight * scale) + 4.0, scale + 4.0)
    }

    static func formatTileCoordinateString(_ tile: Tile) -> String {
        "tile = \(tile.x)/\(tile.y)/\(tile.z)"
    }

    static func makeTileWatermarkTextStyle() -> TextStyleUniform {
        TextStyleUniform(textColor: SIMD3<Float>(1.0, 0.95, 0.2),
                         strokeColor: SIMD3<Float>(0.0, 0.0, 0.0),
                         strokeWidthPx: 2.0)
    }

    static func makeTileWatermarkUVs(gridSize: Int = 3) -> [SIMD2<Float>] {
        let clampedGridSize = max(1, gridSize)
        let step = 1.0 / Float(clampedGridSize + 1)
        var uvs: [SIMD2<Float>] = []
        uvs.reserveCapacity(clampedGridSize * clampedGridSize)

        for row in 1...clampedGridSize {
            for column in 1...clampedGridSize {
                uvs.append(SIMD2<Float>(Float(column) * step,
                                        Float(row) * step))
            }
        }
        return uvs
    }

    static func makeTileTextEntries(anchor: SIMD2<Float>,
                                    lines: [String],
                                    scale: Float,
                                    lineAdvance: Float,
                                    padding: SIMD2<Float> = SIMD2<Float>(6.0, 6.0)) -> [TextEntry] {
        guard lines.isEmpty == false else { return [] }

        var entries: [TextEntry] = []
        entries.reserveCapacity(lines.count)
        let startY = anchor.y + (Float(lines.count - 1) * lineAdvance * 0.5)
        for (index, line) in lines.enumerated() {
            entries.append(TextEntry(text: line,
                                     position: SIMD2<Float>(anchor.x + padding.x,
                                                            startY - (Float(index) * lineAdvance) + padding.y),
                                     scale: scale))
        }
        return entries
    }

    static func makeTileWatermarkProjectionPointInputs(anchorUV: SIMD2<Float>,
                                                       metrics: TextMetrics,
                                                       tile: Tile,
                                                       maxWidthUV: Float,
                                                       maxHeightUV: Float,
                                                       paddingPx: SIMD2<Float> = .zero) -> [TilePointInput] {
        var inputs: [TilePointInput] = []
        inputs.reserveCapacity(3)
        appendTileWatermarkProjectionPointInputs(anchorUV: anchorUV,
                                                 metrics: metrics,
                                                 tile: tile,
                                                 maxWidthUV: maxWidthUV,
                                                 maxHeightUV: maxHeightUV,
                                                 paddingPx: paddingPx,
                                                 into: &inputs)
        return inputs
    }

    static func tileWatermarkUVScale(metrics: TextMetrics,
                                     maxWidthUV: Float,
                                     maxHeightUV: Float,
                                     paddingPx: SIMD2<Float>) -> Float? {
        guard metrics.vertices.isEmpty == false,
              metrics.size.width > 0,
              metrics.size.height > 0 else {
            return nil
        }

        let paddedWidth = Float(metrics.size.width) + paddingPx.x * 2.0
        let paddedHeight = Float(metrics.size.height) + paddingPx.y * 2.0
        return min(maxWidthUV / paddedWidth,
                   maxHeightUV / paddedHeight)
    }

    private static func appendTileWatermarkProjectionPointInputs(anchorUV: SIMD2<Float>,
                                                                 metrics: TextMetrics,
                                                                 tile: Tile,
                                                                 maxWidthUV: Float,
                                                                 maxHeightUV: Float,
                                                                 paddingPx: SIMD2<Float>,
                                                                 into inputs: inout [TilePointInput]) {
        guard let uvScale = tileWatermarkUVScale(metrics: metrics,
                                                 maxWidthUV: maxWidthUV,
                                                 maxHeightUV: maxHeightUV,
                                                 paddingPx: paddingPx) else {
            return
        }
        let tileVector = SIMD3<Int32>(Int32(tile.x), Int32(tile.y), Int32(tile.z))
        inputs.append(TilePointInput(uv: anchorUV,
                                     tile: tileVector,
                                     tileSlotIndex: 0))
        inputs.append(TilePointInput(uv: SIMD2<Float>(anchorUV.x + uvScale, anchorUV.y),
                                     tile: tileVector,
                                     tileSlotIndex: 0))
        inputs.append(TilePointInput(uv: SIMD2<Float>(anchorUV.x, anchorUV.y - uvScale),
                                     tile: tileVector,
                                     tileSlotIndex: 0))
    }

    /// Возле сингулярности проекции (clip.w -> 0+) аффинные оси водяного знака взрываются,
    /// и один глиф размазывается на весь экран. Якорь отбрасывается, если оси невалидны,
    /// экранный размер текста запределен или текст целиком вне вьюпорта.
    static func makeTileWatermarkScreenPlacement(center: SIMD2<Float>,
                                                 xUnitPoint: SIMD2<Float>,
                                                 yUnitPoint: SIMD2<Float>,
                                                 textSize: SIMD2<Float>,
                                                 viewportSize: SIMD2<Float>,
                                                 maxViewportSpanFactor: Float = 2.0) -> TileWatermarkScreenPlacement? {
        let xAxis = xUnitPoint - center
        let yAxis = yUnitPoint - center
        let halfSize = textSize * 0.5
        let halfExtentX = abs(xAxis.x) * halfSize.x + abs(yAxis.x) * halfSize.y
        let halfExtentY = abs(xAxis.y) * halfSize.x + abs(yAxis.y) * halfSize.y
        guard center.x.isFinite, center.y.isFinite,
              halfExtentX.isFinite, halfExtentY.isFinite else {
            return nil
        }

        let maxScreenSpan = maxViewportSpanFactor * max(viewportSize.x, viewportSize.y)
        guard max(halfExtentX, halfExtentY) * 2.0 <= maxScreenSpan else {
            return nil
        }
        guard center.x + halfExtentX >= 0.0,
              center.x - halfExtentX <= viewportSize.x,
              center.y + halfExtentY >= 0.0,
              center.y - halfExtentY <= viewportSize.y else {
            return nil
        }
        return TileWatermarkScreenPlacement(xAxis: xAxis, yAxis: yAxis)
    }

    static func makeTileOverlaySegments(segmentCountPerEdge: Int) -> [TileOverlayLineSegment] {
        let clampedSegments = max(1, segmentCountPerEdge)
        let step = 1.0 / Float(clampedSegments)
        var segments: [TileOverlayLineSegment] = []
        segments.reserveCapacity(clampedSegments * 4)

        for index in 0..<clampedSegments {
            let start = Float(index) * step
            let end = Float(index + 1) * step
            segments.append(TileOverlayLineSegment(start: SIMD2<Float>(start, 0.0),
                                                   end: SIMD2<Float>(end, 0.0)))
            segments.append(TileOverlayLineSegment(start: SIMD2<Float>(1.0, start),
                                                   end: SIMD2<Float>(1.0, end)))
            segments.append(TileOverlayLineSegment(start: SIMD2<Float>(1.0 - start, 1.0),
                                                   end: SIMD2<Float>(1.0 - end, 1.0)))
            segments.append(TileOverlayLineSegment(start: SIMD2<Float>(0.0, 1.0 - start),
                                                   end: SIMD2<Float>(0.0, 1.0 - end)))
        }
        return segments
    }

    private func setTileTextVertices(renderEncoder: MTLRenderCommandEncoder,
                                     vertices: [TextVertex],
                                     frameSlotIndex: Int) {
        let length = MemoryLayout<TextVertex>.stride * vertices.count
        if length <= 4096 {
            renderEncoder.setVertexBytes(vertices, length: length, index: 0)
            return
        }

        let buffer = tileTextVertexBufferStore.ensureCapacity(slot: frameSlotIndex,
                                                              count: vertices.count)
        vertices.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(buffer.contents(), baseAddress, rawBuffer.count)
        }
        renderEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
    }

    private func setLineVertices(renderEncoder: MTLRenderCommandEncoder,
                                 vertices: [PolygonsPipeline.Vertex],
                                 frameSlotIndex: Int) {
        let length = MemoryLayout<PolygonsPipeline.Vertex>.stride * vertices.count
        if length <= 4096 {
            renderEncoder.setVertexBytes(vertices, length: length, index: 0)
            return
        }

        let buffer = lineVertexBufferStore.ensureCapacity(slot: frameSlotIndex,
                                                          count: vertices.count)
        vertices.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(buffer.contents(), baseAddress, rawBuffer.count)
        }
        renderEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
    }

    private func appendTileOutlineVertices(into vertices: inout [PolygonsPipeline.Vertex],
                                           placeTile: PlaceTile,
                                           outlineSegments: [TileOverlayLineSegment],
                                           frameContext: FrameContext,
                                           color: SIMD4<Float>) {
        guard outlineSegments.isEmpty == false else { return }

        var pointInputs: [TilePointInput] = []
        pointInputs.reserveCapacity(outlineSegments.count * 2)
        for segment in outlineSegments {
            pointInputs.append(TilePointInput(uv: segment.start,
                                              tile: SIMD3<Int32>(Int32(placeTile.placeIn.x),
                                                                 Int32(placeTile.placeIn.y),
                                                                 Int32(placeTile.placeIn.z)),
                                              tileSlotIndex: 0))
            pointInputs.append(TilePointInput(uv: segment.end,
                                              tile: SIMD3<Int32>(Int32(placeTile.placeIn.x),
                                                                 Int32(placeTile.placeIn.y),
                                                                 Int32(placeTile.placeIn.z)),
                                              tileSlotIndex: 0))
        }

        let snapshot = TilePointToScreenPointSnapshot(pointInputs: pointInputs,
                                                      tileSlotVisibleTileIndices: [0])
        let projectedPoints = tilePointScreenProjector.project(snapshot: snapshot,
                                                               frameContext: frameContext,
                                                               tileOriginData: makeTileOriginData(for: placeTile,
                                                                                                  frameContext: frameContext))
        guard projectedPoints.count == pointInputs.count else { return }

        for segmentIndex in 0..<outlineSegments.count {
            let startPoint = projectedPoints[segmentIndex * 2]
            let endPoint = projectedPoints[(segmentIndex * 2) + 1]
            guard startPoint.visible != 0, endPoint.visible != 0 else {
                continue
            }
            appendThickLineQuad(into: &vertices,
                                start: startPoint.position,
                                end: endPoint.position,
                                thickness: tileOutlineThicknessPx,
                                color: color)
        }
    }

    private func appendTileTextEntries(into entries: inout [TextEntry],
                                       projectedVertices: inout [TextVertex],
                                       placeTile: PlaceTile,
                                       frameContext: FrameContext,
                                       scale: Float,
                                       lineAdvance: Float,
                                       textRenderer: TextRenderer) {
        let primaryText = Self.formatTileCoordinateString(placeTile.placeIn.tile)
        let primaryMetrics = textRenderer.collectLabelVertices(for: primaryText,
                                                               labelIndex: 0,
                                                               scale: scale)
        appendTileWatermarkVertices(into: &projectedVertices,
                                    metrics: primaryMetrics,
                                    placeTile: placeTile,
                                    frameContext: frameContext)

        let sourceTile = placeTile.metalTile.tile
        if placeTile.lodKind != .exact || sourceTile != placeTile.placeIn.tile {
            guard let sourceAnchorPoint = makeTileSourceLabelAnchorPoint(placeTile: placeTile,
                                                                         frameContext: frameContext) else {
                return
            }
            let sourceAnchor = sourceAnchorPoint + SIMD2<Float>(tileLabelInsetPx.x, -tileLabelInsetPx.y)
            entries.append(contentsOf: Self.makeTileTextEntries(anchor: sourceAnchor,
                                                                lines: ["src \(Self.formatTileCoordinateString(sourceTile))"],
                                                                scale: max(scale * 0.72, 20.0),
                                                                lineAdvance: lineAdvance,
                                                                padding: .zero))
        }
    }

    private func makeTileOriginData(for placeTile: PlaceTile,
                                    frameContext: FrameContext) -> [FlatTileOriginData] {
        guard frameContext.screenSpaceProjectionMode == .flat else {
            return []
        }

        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: placeTile.placeIn.x,
                                                                y: placeTile.placeIn.y,
                                                                z: placeTile.placeIn.z,
                                                                loop: placeTile.placeIn.loop,
                                                                flatRenderPan: frameContext.flatRenderState.pan,
                                                                renderMapSize: frameContext.flatRenderState.renderMapSize)
        return [FlatTileOriginData(panRelativeOrigin: SIMD2<Float>(originAndSize.x, originAndSize.y),
                                   size: originAndSize.z)]
    }

    private func appendTileWatermarkVertices(into vertices: inout [TextVertex],
                                             metrics: TextMetrics,
                                             placeTile: PlaceTile,
                                             frameContext: FrameContext) {
        guard metrics.vertices.count >= 3,
              let uvScale = Self.tileWatermarkUVScale(metrics: metrics,
                                                      maxWidthUV: tileWatermarkMaxWidthUV,
                                                      maxHeightUV: tileWatermarkMaxHeightUV,
                                                      paddingPx: tileWatermarkPaddingPx) else { return }

        let tileOriginData = makeTileOriginData(for: placeTile, frameContext: frameContext)

        tileWatermarkProjectionInputsScratch.removeAll(keepingCapacity: true)
        for anchorUV in Self.tileWatermarkUVs {
            Self.appendTileWatermarkProjectionPointInputs(anchorUV: anchorUV,
                                                          metrics: metrics,
                                                          tile: placeTile.placeIn.tile,
                                                          maxWidthUV: tileWatermarkMaxWidthUV,
                                                          maxHeightUV: tileWatermarkMaxHeightUV,
                                                          paddingPx: tileWatermarkPaddingPx,
                                                          into: &tileWatermarkProjectionInputsScratch)
        }
        let basisSnapshot = TilePointToScreenPointSnapshot(pointInputs: tileWatermarkProjectionInputsScratch,
                                                           tileSlotVisibleTileIndices: [0])
        let basisPoints = tilePointScreenProjector.project(snapshot: basisSnapshot,
                                                           frameContext: frameContext,
                                                           tileOriginData: tileOriginData)
        guard basisPoints.count == tileWatermarkProjectionInputsScratch.count else { return }

        let projectedPointCountPerAnchor = 3
        let textSize = SIMD2<Float>(Float(metrics.size.width), Float(metrics.size.height))
        let textCenter = textSize * 0.5
        let viewportSize = SIMD2<Float>(Float(frameContext.drawSize.width),
                                        Float(frameContext.drawSize.height))
        var acceptedAnchorUVs: [SIMD2<Float>] = []
        acceptedAnchorUVs.reserveCapacity(Self.tileWatermarkUVs.count)
        for anchorIndex in Self.tileWatermarkUVs.indices {
            let anchorOffset = anchorIndex * projectedPointCountPerAnchor
            let centerPoint = basisPoints[anchorOffset]
            let xUnitPoint = basisPoints[anchorOffset + 1]
            let yUnitPoint = basisPoints[anchorOffset + 2]
            guard centerPoint.visible != 0,
                  xUnitPoint.visible != 0,
                  yUnitPoint.visible != 0,
                  Self.makeTileWatermarkScreenPlacement(center: centerPoint.position,
                                                        xUnitPoint: xUnitPoint.position,
                                                        yUnitPoint: yUnitPoint.position,
                                                        textSize: textSize,
                                                        viewportSize: viewportSize) != nil else {
                continue
            }
            acceptedAnchorUVs.append(Self.tileWatermarkUVs[anchorIndex])
        }
        guard acceptedAnchorUVs.isEmpty == false else { return }

        // Каждая вершина глифа проецируется точно: аффинная экстраполяция от якоря
        // при наклоне камеры «поднимала» текст из плоскости карты на камеру.
        tileWatermarkVertexInputsScratch.removeAll(keepingCapacity: true)
        tileWatermarkVertexInputsScratch.reserveCapacity(acceptedAnchorUVs.count * metrics.vertices.count)
        let tileVector = SIMD3<Int32>(Int32(placeTile.placeIn.x),
                                      Int32(placeTile.placeIn.y),
                                      Int32(placeTile.placeIn.z))
        for anchorUV in acceptedAnchorUVs {
            for vertex in metrics.vertices {
                let centered = vertex.position - textCenter
                let uv = SIMD2<Float>(anchorUV.x + centered.x * uvScale,
                                      anchorUV.y - centered.y * uvScale)
                tileWatermarkVertexInputsScratch.append(TilePointInput(uv: uv,
                                                                       tile: tileVector,
                                                                       tileSlotIndex: 0))
            }
        }
        let vertexSnapshot = TilePointToScreenPointSnapshot(pointInputs: tileWatermarkVertexInputsScratch,
                                                            tileSlotVisibleTileIndices: [0])
        let vertexPoints = tilePointScreenProjector.project(snapshot: vertexSnapshot,
                                                            frameContext: frameContext,
                                                            tileOriginData: tileOriginData)
        guard vertexPoints.count == tileWatermarkVertexInputsScratch.count else { return }

        let verticesPerAnchor = metrics.vertices.count
        for acceptedIndex in acceptedAnchorUVs.indices {
            let anchorBase = acceptedIndex * verticesPerAnchor
            var triangleStart = 0
            while triangleStart + 2 < verticesPerAnchor {
                let p0 = vertexPoints[anchorBase + triangleStart]
                let p1 = vertexPoints[anchorBase + triangleStart + 1]
                let p2 = vertexPoints[anchorBase + triangleStart + 2]
                if p0.visible != 0, p1.visible != 0, p2.visible != 0 {
                    for offset in 0..<3 {
                        let point = vertexPoints[anchorBase + triangleStart + offset]
                        vertices.append(TextVertex(position: SIMD4<Float>(point.position.x,
                                                                          point.position.y,
                                                                          0.0,
                                                                          1.0),
                                                   uv: metrics.vertices[triangleStart + offset].uv))
                    }
                }
                triangleStart += 3
            }
        }
    }

    private func makeTileSourceLabelAnchorPoint(placeTile: PlaceTile,
                                                frameContext: FrameContext) -> SIMD2<Float>? {
        let candidateUVs: [SIMD2<Float>] = [
            SIMD2<Float>(0.55, 0.82),
            SIMD2<Float>(0.55, 0.68),
            SIMD2<Float>(0.5, 0.5)
        ]
        let pointInputs = candidateUVs.map {
            TilePointInput(uv: $0,
                           tile: SIMD3<Int32>(Int32(placeTile.placeIn.x),
                                              Int32(placeTile.placeIn.y),
                                              Int32(placeTile.placeIn.z)),
                           tileSlotIndex: 0)
        }
        let snapshot = TilePointToScreenPointSnapshot(pointInputs: pointInputs,
                                                      tileSlotVisibleTileIndices: [0])
        let points = tilePointScreenProjector.project(snapshot: snapshot,
                                                      frameContext: frameContext,
                                                      tileOriginData: makeTileOriginData(for: placeTile,
                                                                                         frameContext: frameContext))
        return points.first(where: { $0.visible != 0 })?.position
    }

    private func appendThickLineQuad(into vertices: inout [PolygonsPipeline.Vertex],
                                     start: SIMD2<Float>,
                                     end: SIMD2<Float>,
                                     thickness: Float,
                                     color: SIMD4<Float>) {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0.001 else { return }

        let direction = delta / length
        let normal = SIMD2<Float>(-direction.y, direction.x) * (thickness * 0.5)

        let a = start + normal
        let b = end + normal
        let c = end - normal
        let d = start - normal

        vertices.append(PolygonsPipeline.Vertex(position: SIMD4<Float>(a.x, a.y, 0.0, 1.0), color: color))
        vertices.append(PolygonsPipeline.Vertex(position: SIMD4<Float>(b.x, b.y, 0.0, 1.0), color: color))
        vertices.append(PolygonsPipeline.Vertex(position: SIMD4<Float>(c.x, c.y, 0.0, 1.0), color: color))

        vertices.append(PolygonsPipeline.Vertex(position: SIMD4<Float>(a.x, a.y, 0.0, 1.0), color: color))
        vertices.append(PolygonsPipeline.Vertex(position: SIMD4<Float>(c.x, c.y, 0.0, 1.0), color: color))
        vertices.append(PolygonsPipeline.Vertex(position: SIMD4<Float>(d.x, d.y, 0.0, 1.0), color: color))
    }
}
