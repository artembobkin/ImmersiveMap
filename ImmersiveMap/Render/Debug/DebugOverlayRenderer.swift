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

/// One run of text to be laid into the tile plane at `anchorUV`, scaled down until
/// it fits a box of `maxWidthUV` by `maxHeightUV` in tile UV. Metrics are passed in
/// rather than a string so a caller repeating the same text at many anchors lays it
/// out once.
struct TileProjectedTextPlacement {
    let anchorUV: SIMD2<Float>
    let metrics: TextMetrics
    let maxWidthUV: Float
    let maxHeightUV: Float
    let paddingPx: SIMD2<Float>
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
    private let tileGridLineThicknessPx: Float = 1.5
    /// Below this, in drawable pixels, a cell has no room for its four-line stamp, so
    /// the cell keeps its lines and loses its text. Also what keeps the per-glyph
    /// projection cheap when the centre tile is small on screen: on the globe, where
    /// the projection costs transcendentals per point, cells fall under it quickly.
    private let tileGridMinimumCellScreenPixels: Float = 48.0
    private let tileGridCellMaxWidthFraction: Float = 0.92
    private static let tileGridCellLineHeightFractions: [Float] = [0.15, 0.26, 0.15, 0.15]
    private static let tileGridCellExtraLineHeightFraction: Float = 0.12
    private static let tileGridCellLineGapFraction: Float = 0.04
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

    /// Divides the tile under the camera centre into `density x density` cells and
    /// stamps each cell with the tile it belongs to, its cell code and its tile-local
    /// bounds. Only that one tile: the grid exists so a screenshot of a region names
    /// the slice of tile geometry to go read, and repeating it over every visible tile
    /// would bury the map it is drawn over.
    func drawTileGridOverlay(renderEncoder: MTLRenderCommandEncoder,
                             polygonPipeline: PolygonsPipeline,
                             textRenderer: TextRenderer,
                             frameContext: FrameContext,
                             placeTiles: [PlaceTile],
                             density: Int) {
        guard let centerPlaceTile = resolveCenterPlaceTile(placeTiles: placeTiles,
                                                           frameContext: frameContext) else {
            return
        }

        let clampedDensity = DebugTileGridDensity.clamp(density)

        lineVerticesScratch.removeAll(keepingCapacity: true)
        appendTileGridLineVertices(into: &lineVerticesScratch,
                                   placeTile: centerPlaceTile,
                                   density: clampedDensity,
                                   frameContext: frameContext)
        if lineVerticesScratch.isEmpty == false {
            drawLineVertices(renderEncoder: renderEncoder,
                             polygonPipeline: polygonPipeline,
                             screenMatrix: frameContext.cameraMatrices.screen,
                             frameSlotIndex: frameContext.frameSlotIndex,
                             vertices: lineVerticesScratch)
        }

        tileProjectedTextVerticesScratch.removeAll(keepingCapacity: true)
        appendTileGridCellTextVertices(into: &tileProjectedTextVerticesScratch,
                                       placeTile: centerPlaceTile,
                                       density: clampedDensity,
                                       frameContext: frameContext,
                                       textRenderer: textRenderer)
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

    /// Frames of all labels in the frame in screen coordinates: visible and
    /// hidden (by collision, label horizon or fade). Base labels are green and
    /// red, road labels (one glyph per frame) cyan and orange: they take part
    /// in the same collision solver. Gives a visual estimate of the total
    /// number of labels participating in the frame.
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
        let hasKnownFrameDelta = diagnostics.frameDeltaTime.isFinite && diagnostics.frameDeltaTime > 0
        let frameTimeText = hasKnownFrameDelta
            ? "\(String(format: "%.2f", diagnostics.frameDeltaTime * 1000.0))ms"
            : "--"
        let fpsText = hasKnownFrameDelta
            ? String(format: "%.1f", 1.0 / diagnostics.frameDeltaTime)
            : "--"
        var frameLine = "frame:\(diagnostics.frameIndex) dt:\(frameTimeText) fps:\(fpsText)"
        let gpuFrameMs = diagnostics.measurementValue(.gpuFrameDurationMs)
        if gpuFrameMs > 0 {
            frameLine += " gpu:\(String(format: "%.2f", gpuFrameMs))ms"
        }
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

    /// Near the projection singularity (clip.w -> 0+) the watermark's affine axes blow up
    /// and a single glyph smears across the whole screen. The anchor is discarded if the
    /// axes are invalid, the on-screen text size is extreme, or the text is entirely outside the viewport.
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

    private func resolveCenterPlaceTile(placeTiles: [PlaceTile],
                                        frameContext: FrameContext) -> PlaceTile? {
        let candidates = DebugTileGridCenterTile.candidates(placeTiles: placeTiles,
                                                            centerWorldMercator: frameContext.mapCameraState.centerWorldMercator)
        guard candidates.count > 1 else {
            return candidates.first
        }

        // Wrapped copies of one tile all contain the centre; only their placement on
        // screen tells them apart, and each copy has its own flat origin.
        var projectedCenters: [ScreenPointOutput] = []
        projectedCenters.reserveCapacity(candidates.count)
        for candidate in candidates {
            let input = TilePointInput(uv: SIMD2<Float>(0.5, 0.5),
                                       tile: SIMD3<Int32>(Int32(candidate.placeIn.x),
                                                          Int32(candidate.placeIn.y),
                                                          Int32(candidate.placeIn.z)),
                                       tileSlotIndex: 0)
            let snapshot = TilePointToScreenPointSnapshot(pointInputs: [input],
                                                          tileSlotVisibleTileIndices: [0])
            let points = tilePointScreenProjector.project(snapshot: snapshot,
                                                          frameContext: frameContext,
                                                          tileOriginData: makeTileOriginData(for: candidate,
                                                                                             frameContext: frameContext))
            projectedCenters.append(points.first ?? ScreenPointOutput(position: .zero,
                                                                      depth: 0.0,
                                                                      visible: 0))
        }
        return DebugTileGridCenterTile.nearestToViewportCenter(candidates: candidates,
                                                               projectedCenters: projectedCenters,
                                                               viewportSize: SIMD2<Float>(Float(frameContext.drawSize.width),
                                                                                          Float(frameContext.drawSize.height)))
    }

    private func appendTileGridLineVertices(into vertices: inout [PolygonsPipeline.Vertex],
                                            placeTile: PlaceTile,
                                            density: Int,
                                            frameContext: FrameContext) {
        let segments = DebugTileGridMath.makeGridSegments(density: density,
                                                          segmentCountPerEdge: frameContext.screenSpaceProjectionMode == .flat ? 1 : 8)
        guard segments.isEmpty == false else { return }

        let tileVector = SIMD3<Int32>(Int32(placeTile.placeIn.x),
                                      Int32(placeTile.placeIn.y),
                                      Int32(placeTile.placeIn.z))
        var pointInputs: [TilePointInput] = []
        pointInputs.reserveCapacity(segments.count * 2)
        for segment in segments {
            pointInputs.append(TilePointInput(uv: segment.start, tile: tileVector, tileSlotIndex: 0))
            pointInputs.append(TilePointInput(uv: segment.end, tile: tileVector, tileSlotIndex: 0))
        }

        let snapshot = TilePointToScreenPointSnapshot(pointInputs: pointInputs,
                                                      tileSlotVisibleTileIndices: [0])
        let projectedPoints = tilePointScreenProjector.project(snapshot: snapshot,
                                                               frameContext: frameContext,
                                                               tileOriginData: makeTileOriginData(for: placeTile,
                                                                                                  frameContext: frameContext))
        guard projectedPoints.count == pointInputs.count else { return }

        vertices.reserveCapacity(vertices.count + segments.count * 6)
        for segmentIndex in segments.indices {
            let startPoint = projectedPoints[segmentIndex * 2]
            let endPoint = projectedPoints[(segmentIndex * 2) + 1]
            guard startPoint.visible != 0, endPoint.visible != 0 else {
                continue
            }
            appendThickLineQuad(into: &vertices,
                                start: startPoint.position,
                                end: endPoint.position,
                                thickness: segments[segmentIndex].isBorder ? tileOutlineThicknessPx : tileGridLineThicknessPx,
                                color: tileOutlineColor)
        }
    }

    private func appendTileGridCellTextVertices(into vertices: inout [TextVertex],
                                                placeTile: PlaceTile,
                                                density: Int,
                                                frameContext: FrameContext,
                                                textRenderer: TextRenderer) {
        let tileVector = SIMD3<Int32>(Int32(placeTile.placeIn.x),
                                      Int32(placeTile.placeIn.y),
                                      Int32(placeTile.placeIn.z))
        let cornerCount = 4
        var cornerInputs: [TilePointInput] = []
        cornerInputs.reserveCapacity(density * density * cornerCount)
        for row in 0..<density {
            for column in 0..<density {
                let rect = DebugTileGridMath.cellUVRect(column: column, row: row, density: density)
                cornerInputs.append(TilePointInput(uv: SIMD2<Float>(rect.minU, rect.minV), tile: tileVector, tileSlotIndex: 0))
                cornerInputs.append(TilePointInput(uv: SIMD2<Float>(rect.maxU, rect.minV), tile: tileVector, tileSlotIndex: 0))
                cornerInputs.append(TilePointInput(uv: SIMD2<Float>(rect.maxU, rect.maxV), tile: tileVector, tileSlotIndex: 0))
                cornerInputs.append(TilePointInput(uv: SIMD2<Float>(rect.minU, rect.maxV), tile: tileVector, tileSlotIndex: 0))
            }
        }

        let cornerSnapshot = TilePointToScreenPointSnapshot(pointInputs: cornerInputs,
                                                            tileSlotVisibleTileIndices: [0])
        let cornerPoints = tilePointScreenProjector.project(snapshot: cornerSnapshot,
                                                            frameContext: frameContext,
                                                            tileOriginData: makeTileOriginData(for: placeTile,
                                                                                               frameContext: frameContext))
        guard cornerPoints.count == cornerInputs.count else { return }

        let scale = max(settings.diagnosticsScale * 0.5, 28.0)
        let cellSpanUV = 1.0 / Float(density)
        var placements: [TileProjectedTextPlacement] = []
        placements.reserveCapacity(density * density * Self.tileGridCellLineHeightFractions.count)
        for row in 0..<density {
            for column in 0..<density {
                let cellIndex = row * density + column
                guard Self.isCellLargeEnoughForText(cornerPoints: cornerPoints,
                                                    cellIndex: cellIndex,
                                                    minimumScreenSize: tileGridMinimumCellScreenPixels) else {
                    continue
                }

                appendTileGridCellPlacements(into: &placements,
                                             lines: DebugTileGridMath.cellLabelLines(tile: placeTile.placeIn.tile,
                                                                                     column: column,
                                                                                     row: row,
                                                                                     density: density,
                                                                                     sourceTile: placeTile.metalTile.tile),
                                             rect: DebugTileGridMath.cellUVRect(column: column,
                                                                                row: row,
                                                                                density: density),
                                             cellSpanUV: cellSpanUV,
                                             scale: scale,
                                             textRenderer: textRenderer)
            }
        }

        appendProjectedTileTexts(into: &vertices,
                                 placements: placements,
                                 placeTile: placeTile,
                                 frameContext: frameContext)
    }

    /// The cell's screen bounding box, measured only when all four corners project in
    /// front of the camera: a cell straddling the near plane has no meaningful size and
    /// no useful place to put its stamp.
    static func isCellLargeEnoughForText(cornerPoints: [ScreenPointOutput],
                                         cellIndex: Int,
                                         minimumScreenSize: Float) -> Bool {
        let base = cellIndex * 4
        guard base >= 0, base + 3 < cornerPoints.count else { return false }

        var minCorner = SIMD2<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxCorner = SIMD2<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for offset in 0..<4 {
            let point = cornerPoints[base + offset]
            guard point.visible != 0,
                  point.position.x.isFinite,
                  point.position.y.isFinite else {
                return false
            }
            minCorner = simd_min(minCorner, point.position)
            maxCorner = simd_max(maxCorner, point.position)
        }
        let size = maxCorner - minCorner
        return min(size.x, size.y) >= minimumScreenSize
    }

    /// Height of every stamped line as a fraction of the cell, the code line taller
    /// than the rest. A substituted cell stamps one line more than the usual four.
    static func cellLineHeightFractions(lineCount: Int) -> [Float] {
        guard lineCount > tileGridCellLineHeightFractions.count else {
            return Array(tileGridCellLineHeightFractions.prefix(max(0, lineCount)))
        }
        return tileGridCellLineHeightFractions
            + Array(repeating: tileGridCellExtraLineHeightFraction,
                    count: lineCount - tileGridCellLineHeightFractions.count)
    }

    private func appendTileGridCellPlacements(into placements: inout [TileProjectedTextPlacement],
                                              lines: [String],
                                              rect: (minU: Float, minV: Float, maxU: Float, maxV: Float),
                                              cellSpanUV: Float,
                                              scale: Float,
                                              textRenderer: TextRenderer) {
        let heightFractions = Self.cellLineHeightFractions(lineCount: lines.count)
        guard lines.isEmpty == false, heightFractions.count == lines.count else { return }

        let gapUV = Self.tileGridCellLineGapFraction * cellSpanUV
        let totalHeightUV = heightFractions.reduce(0.0) { $0 + $1 * cellSpanUV }
            + gapUV * Float(lines.count - 1)
        let centerU = (rect.minU + rect.maxU) * 0.5
        let centerV = (rect.minV + rect.maxV) * 0.5
        let maxWidthUV = tileGridCellMaxWidthFraction * cellSpanUV
        // `uv.y` grows southward, so the stack runs from the first line down.
        var lineTopV = centerV - totalHeightUV * 0.5
        for index in lines.indices {
            let lineHeightUV = heightFractions[index] * cellSpanUV
            let metrics = textRenderer.collectLabelVertices(for: lines[index],
                                                            labelIndex: 0,
                                                            scale: scale)
            placements.append(TileProjectedTextPlacement(anchorUV: SIMD2<Float>(centerU,
                                                                                lineTopV + lineHeightUV * 0.5),
                                                         metrics: metrics,
                                                         maxWidthUV: maxWidthUV,
                                                         maxHeightUV: lineHeightUV,
                                                         paddingPx: .zero))
            lineTopV += lineHeightUV + gapUV
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
        let placements = Self.tileWatermarkUVs.map { anchorUV in
            TileProjectedTextPlacement(anchorUV: anchorUV,
                                       metrics: metrics,
                                       maxWidthUV: tileWatermarkMaxWidthUV,
                                       maxHeightUV: tileWatermarkMaxHeightUV,
                                       paddingPx: tileWatermarkPaddingPx)
        }
        appendProjectedTileTexts(into: &vertices,
                                 placements: placements,
                                 placeTile: placeTile,
                                 frameContext: frameContext)
    }

    /// Lays a batch of text runs into the tile plane and emits their screen-space
    /// glyph triangles. Two projector passes for the whole batch: one for the anchor
    /// bases, which decides which runs survive the projection at all, then one for
    /// the glyph vertices of the survivors.
    private func appendProjectedTileTexts(into vertices: inout [TextVertex],
                                          placements: [TileProjectedTextPlacement],
                                          placeTile: PlaceTile,
                                          frameContext: FrameContext) {
        guard placements.isEmpty == false else { return }

        let tileOriginData = makeTileOriginData(for: placeTile, frameContext: frameContext)
        let tileVector = SIMD3<Int32>(Int32(placeTile.placeIn.x),
                                      Int32(placeTile.placeIn.y),
                                      Int32(placeTile.placeIn.z))

        var scaledPlacements: [(placement: TileProjectedTextPlacement, uvScale: Float)] = []
        scaledPlacements.reserveCapacity(placements.count)
        tileWatermarkProjectionInputsScratch.removeAll(keepingCapacity: true)
        tileWatermarkProjectionInputsScratch.reserveCapacity(placements.count * 3)
        for placement in placements {
            guard placement.metrics.vertices.count >= 3,
                  let uvScale = Self.tileWatermarkUVScale(metrics: placement.metrics,
                                                          maxWidthUV: placement.maxWidthUV,
                                                          maxHeightUV: placement.maxHeightUV,
                                                          paddingPx: placement.paddingPx) else {
                continue
            }

            scaledPlacements.append((placement: placement, uvScale: uvScale))
            Self.appendTileWatermarkProjectionPointInputs(anchorUV: placement.anchorUV,
                                                          metrics: placement.metrics,
                                                          tile: placeTile.placeIn.tile,
                                                          maxWidthUV: placement.maxWidthUV,
                                                          maxHeightUV: placement.maxHeightUV,
                                                          paddingPx: placement.paddingPx,
                                                          into: &tileWatermarkProjectionInputsScratch)
        }
        guard scaledPlacements.isEmpty == false else { return }

        let basisSnapshot = TilePointToScreenPointSnapshot(pointInputs: tileWatermarkProjectionInputsScratch,
                                                           tileSlotVisibleTileIndices: [0])
        let basisPoints = tilePointScreenProjector.project(snapshot: basisSnapshot,
                                                           frameContext: frameContext,
                                                           tileOriginData: tileOriginData)
        guard basisPoints.count == tileWatermarkProjectionInputsScratch.count else { return }

        let projectedPointCountPerAnchor = 3
        let viewportSize = SIMD2<Float>(Float(frameContext.drawSize.width),
                                        Float(frameContext.drawSize.height))
        var accepted: [(placement: TileProjectedTextPlacement, uvScale: Float)] = []
        accepted.reserveCapacity(scaledPlacements.count)
        for index in scaledPlacements.indices {
            let anchorOffset = index * projectedPointCountPerAnchor
            let centerPoint = basisPoints[anchorOffset]
            let xUnitPoint = basisPoints[anchorOffset + 1]
            let yUnitPoint = basisPoints[anchorOffset + 2]
            let metrics = scaledPlacements[index].placement.metrics
            let textSize = SIMD2<Float>(Float(metrics.size.width), Float(metrics.size.height))
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
            accepted.append(scaledPlacements[index])
        }
        guard accepted.isEmpty == false else { return }

        // Each glyph vertex is projected exactly: affine extrapolation from the anchor
        // used to "lift" the text out of the map plane toward the camera when tilted.
        tileWatermarkVertexInputsScratch.removeAll(keepingCapacity: true)
        tileWatermarkVertexInputsScratch.reserveCapacity(accepted.reduce(0) { $0 + $1.placement.metrics.vertices.count })
        for entry in accepted {
            let metrics = entry.placement.metrics
            let textCenter = SIMD2<Float>(Float(metrics.size.width), Float(metrics.size.height)) * 0.5
            for vertex in metrics.vertices {
                let centered = vertex.position - textCenter
                let uv = SIMD2<Float>(entry.placement.anchorUV.x + centered.x * entry.uvScale,
                                      entry.placement.anchorUV.y - centered.y * entry.uvScale)
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

        var placementBase = 0
        for entry in accepted {
            let metricsVertices = entry.placement.metrics.vertices
            var triangleStart = 0
            while triangleStart + 2 < metricsVertices.count {
                let p0 = vertexPoints[placementBase + triangleStart]
                let p1 = vertexPoints[placementBase + triangleStart + 1]
                let p2 = vertexPoints[placementBase + triangleStart + 2]
                if p0.visible != 0, p1.visible != 0, p2.visible != 0 {
                    for offset in 0..<3 {
                        let point = vertexPoints[placementBase + triangleStart + offset]
                        vertices.append(TextVertex(position: SIMD4<Float>(point.position.x,
                                                                          point.position.y,
                                                                          0.0,
                                                                          1.0),
                                                   uv: metricsVertices[triangleStart + offset].uv))
                    }
                }
                triangleStart += 3
            }
            placementBase += metricsVertices.count
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
