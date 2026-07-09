// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import MetalKit
import Foundation

struct TextSize {
    let width: simd_float1
    let height: simd_float1
}

struct TextMetrics {
    let size: TextSize
    let vertices: [LabelVertex]
}

enum LabelTextAlignment {
    case left
    case center
    case right
}

struct LabelWrapOptions {
    let maxWidthPx: Float
    let maxLines: Int
    let alignment: LabelTextAlignment

    init(maxWidthPx: Float,
         maxLines: Int,
         alignment: LabelTextAlignment = .left) {
        self.maxWidthPx = maxWidthPx
        self.maxLines = maxLines
        self.alignment = alignment
    }
}

struct AtlasData: Codable {
    let atlas: AtlasInfo
    let metrics: Metrics
    let glyphs: [Glyph]
}

struct AtlasInfo: Codable {
    let type: String
    let distanceRange: CGFloat
    let distanceRangeMiddle: CGFloat
    let size: CGFloat
    let width: Int
    let height: Int
    let yOrigin: String
}

struct Metrics: Codable {
    let emSize: CGFloat
    let lineHeight: CGFloat
    let ascender: CGFloat
    let descender: CGFloat
    let underlineY: CGFloat
    let underlineThickness: CGFloat
}

struct Glyph: Codable {
    let unicode: UInt32
    let advance: CGFloat
    var planeBounds: Bounds?
    var atlasBounds: Bounds?
    
    enum CodingKeys: String, CodingKey {
        case unicode, advance, planeBounds = "planeBounds", atlasBounds = "atlasBounds"
    }
}

struct Bounds: Codable {
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat
    let top: CGFloat
}

struct TextVertex {
    var position: SIMD4<Float> // x, y, z=0, w=1
    var uv: SIMD2<Float>
}

struct TextStyleUniform {
    var textColor: SIMD3<Float>
    var _padding0: Float = 0.0
    var strokeColor: SIMD3<Float>
    var strokeWidthPx: Float

    init(textColor: SIMD3<Float>,
         strokeColor: SIMD3<Float> = SIMD3<Float>(1.0, 1.0, 1.0),
         strokeWidthPx: Float = 2.0) {
        self.textColor = textColor
        self.strokeColor = strokeColor
        self.strokeWidthPx = strokeWidthPx
    }
}

struct LabelVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var labelIndex: simd_int1
    var spriteUV: SIMD2<Float>

    init(position: SIMD2<Float>,
         uv: SIMD2<Float>,
         labelIndex: simd_int1,
         spriteUV: SIMD2<Float> = .zero) {
        self.position = position
        self.uv = uv
        self.labelIndex = labelIndex
        self.spriteUV = spriteUV
    }
}

struct TextEntry {
    let text: String
    let position: SIMD2<Float>
    let scale: Float
    
    init(text: String, position: SIMD2<Float>, scale: Float = 1.0) {
        self.text = text
        self.position = position
        self.scale = scale
    }
}

class TextRenderer {
    static let preparedTileTextRevisionValue: UInt32 = 6

    private struct LabelLineLayout {
        let vertices: [LabelVertex]
        let minX: Float
        let minY: Float
        let maxX: Float
        let maxY: Float

        var width: Float {
            max(0.0, maxX - minX)
        }

        var height: Float {
            max(0.0, maxY - minY)
        }
    }

    private enum LabelWrapSegment {
        case text(String)
        case forcedBreak
    }

    private var device: MTLDevice!
    var texture: MTLTexture!
    var thinTexture: MTLTexture!
    private var commandQueue: MTLCommandQueue!
    private var bundle: Bundle!
    var atlasData: AtlasData!
    var thinAtlasData: AtlasData!
    var pipelineState: MTLRenderPipelineState!
    var labelPipelineState: MTLRenderPipelineState!
    var roadLabelPipelineState: MTLRenderPipelineState!
    var poiIconPipelineState: MTLRenderPipelineState!
    private var library: MTLLibrary
    private let sampleCount: Int
    private let boldAtlasName = "atlas"
    private let thinAtlasName = "atlas_thin"
    private var boldGlyphLookup: [UInt32: Glyph] = [:]
    private var thinGlyphLookup: [UInt32: Glyph] = [:]
    
    init(device: MTLDevice,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        self.device = device
        self.library = library
        self.sampleCount = sampleCount
        self.commandQueue = device.makeCommandQueue()!
        self.bundle = .module
        
        loadAtlasTexture()
        loadAtlasJSON()
        buildGlyphLookupTables()
        createPipelines()
    }

    var preparedTileTextRevision: UInt32 {
        Self.preparedTileTextRevisionValue
    }

    var glyphCoverage: VectorTileLabelGlyphCoverage {
        VectorTileLabelGlyphCoverage(atlasData: atlasData, thinAtlasData: thinAtlasData)
    }
    
    func collectMultiTextVertices(for entries: [TextEntry]) -> [TextVertex] {
        var allVertices: [TextVertex] = []
        collectMultiTextVertices(into: &allVertices, for: entries)
        return allVertices
    }

    func collectMultiTextVertices(into vertices: inout [TextVertex], for entries: [TextEntry]) {
        vertices.removeAll(keepingCapacity: true)
        vertices.reserveCapacity(Self.estimatedVertexCapacity(for: entries))

        for entry in entries {
            collectTextVertices(into: &vertices,
                                for: entry.text,
                                at: entry.position,
                                scale: entry.scale)
        }
    }
    
    func collectLabelVertices(for text: String,
                              labelIndex: simd_int1,
                              scale: Float,
                              wrap: LabelWrapOptions? = nil,
                              normalizeY: Bool = true,
                              weight: LabelFontWeight = .bold) -> TextMetrics {
        if let wrap,
           wrap.maxLines > 1,
           wrap.maxWidthPx > 0 {
            let wrapped = collectWrappedLabelVertices(for: text,
                                                      labelIndex: labelIndex,
                                                      scale: scale,
                                                      wrap: wrap,
                                                      normalizeY: normalizeY,
                                                      weight: weight)
            if wrapped.vertices.isEmpty == false {
                return wrapped
            }
        }

        return collectSingleLineLabelVertices(for: text,
                                              labelIndex: labelIndex,
                                              scale: scale,
                                              normalizeY: normalizeY,
                                              weight: weight)
    }

    private func collectSingleLineLabelVertices(for text: String,
                                                labelIndex: simd_int1,
                                                scale: Float,
                                                normalizeY: Bool,
                                                weight: LabelFontWeight) -> TextMetrics {
        guard let layout = makeLineLayout(for: text,
                                          labelIndex: labelIndex,
                                          scale: scale,
                                          baselineY: 0.0,
                                          weight: weight) else {
            return TextMetrics(size: TextSize(width: 0.0, height: 0.0), vertices: [])
        }

        return normalizedTextMetrics(vertices: layout.vertices,
                                     minX: layout.minX,
                                     minY: layout.minY,
                                     maxX: layout.maxX,
                                     maxY: layout.maxY,
                                     normalizeY: normalizeY)
    }

    func collectTextVertices(for text: String, at position: SIMD2<Float>, scale: Float = 1.0) -> [TextVertex] {
        var vertices: [TextVertex] = []
        collectTextVertices(into: &vertices, for: text, at: position, scale: scale)
        return vertices
    }
    
    private func loadAtlasTexture() {
        texture = loadAtlasTexture(named: boldAtlasName) ?? makeFallbackTexture()
        thinTexture = loadAtlasTexture(named: thinAtlasName) ?? texture
    }
    
    private func loadAtlasJSON() {
        atlasData = loadAtlasData(named: boldAtlasName) ?? makeFallbackAtlasData()
        thinAtlasData = loadAtlasData(named: thinAtlasName) ?? atlasData
    }

    private func buildGlyphLookupTables() {
        boldGlyphLookup = Self.makeGlyphLookupTable(from: atlasData.glyphs)
        thinGlyphLookup = Self.makeGlyphLookupTable(from: thinAtlasData.glyphs)
    }

    private func makeFallbackTexture() -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = 1
        descriptor.height = 1
        descriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: descriptor)!
    }

    private func makeFallbackAtlasData() -> AtlasData {
        return AtlasData(
            atlas: AtlasInfo(type: "fallback",
                             distanceRange: 0,
                             distanceRangeMiddle: 0,
                             size: 1,
                             width: 1,
                             height: 1,
                             yOrigin: "bottom"),
            metrics: Metrics(emSize: 1,
                             lineHeight: 1,
                             ascender: 0,
                             descender: 0,
                             underlineY: 0,
                             underlineThickness: 0),
            glyphs: []
        )
    }

    private func loadAtlasTexture(named name: String) -> MTLTexture? {
        guard let url = bundle.url(forResource: name, withExtension: "png") else {
            #if DEBUG
            print("Could not find atlas texture in bundle: \(name).png")
            #endif
            return nil
        }
        let textureLoader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false
        ]
        do {
            let texture = try textureLoader.newTexture(URL: url, options: options)
            return texture
        } catch {
            #if DEBUG
            print("Failed to load atlas texture \(name).png: \(error)")
            #endif
            return nil
        }
    }

    private func loadAtlasData(named name: String) -> AtlasData? {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            #if DEBUG
            print("Could not find atlas JSON in bundle: \(name).json")
            #endif
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let atlas = try JSONDecoder().decode(AtlasData.self, from: data)
            return atlas
        } catch {
            #if DEBUG
            print("Failed to decode atlas JSON \(name).json: \(error)")
            #endif
            return nil
        }
    }

    private func atlasData(for weight: LabelFontWeight) -> AtlasData {
        switch weight {
        case .bold:
            return atlasData
        case .thin:
            return thinAtlasData
        }
    }

    private func glyphLookup(for weight: LabelFontWeight) -> [UInt32: Glyph] {
        switch weight {
        case .bold:
            return boldGlyphLookup
        case .thin:
            return thinGlyphLookup
        }
    }

    private func collectWrappedLabelVertices(for text: String,
                                             labelIndex: simd_int1,
                                             scale: Float,
                                             wrap: LabelWrapOptions,
                                             normalizeY: Bool,
                                             weight: LabelFontWeight) -> TextMetrics {
        let lines = wrappedLines(for: text,
                                 scale: scale,
                                 weight: weight,
                                 wrap: wrap)
        guard lines.isEmpty == false else {
            return TextMetrics(size: TextSize(width: 0.0, height: 0.0), vertices: [])
        }

        let lineAdvance = max(Float(atlasData(for: weight).metrics.lineHeight) * scale, scale)
        var lineLayouts: [LabelLineLayout] = []
        lineLayouts.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            guard let layout = makeLineLayout(for: line,
                                              labelIndex: labelIndex,
                                              scale: scale,
                                              baselineY: -Float(index) * lineAdvance,
                                              weight: weight) else {
                continue
            }
            lineLayouts.append(layout)
        }

        guard lineLayouts.isEmpty == false else {
            return TextMetrics(size: TextSize(width: 0.0, height: 0.0), vertices: [])
        }

        let totalWidth = lineLayouts.map(\.width).max() ?? 0.0
        let totalVertexCount = lineLayouts.reduce(0) { $0 + $1.vertices.count }
        var vertices: [LabelVertex] = []
        vertices.reserveCapacity(totalVertexCount)
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude

        for layout in lineLayouts {
            let lineWidth = layout.width
            let alignedOriginX: Float
            switch wrap.alignment {
            case .left:
                alignedOriginX = 0.0
            case .center:
                alignedOriginX = (totalWidth - lineWidth) * 0.5
            case .right:
                alignedOriginX = totalWidth - lineWidth
            }
            let offsetX = alignedOriginX - layout.minX

            for vertex in layout.vertices {
                let shiftedPosition = SIMD2<Float>(vertex.position.x + offsetX,
                                                   vertex.position.y)
                vertices.append(LabelVertex(position: shiftedPosition,
                                            uv: vertex.uv,
                                            labelIndex: vertex.labelIndex))
            }

            let shiftedMinX = layout.minX + offsetX
            let shiftedMaxX = layout.maxX + offsetX
            minX = min(minX, shiftedMinX)
            minY = min(minY, layout.minY)
            maxX = max(maxX, shiftedMaxX)
            maxY = max(maxY, layout.maxY)
        }

        return normalizedTextMetrics(vertices: vertices,
                                     minX: minX,
                                     minY: minY,
                                     maxX: maxX,
                                     maxY: maxY,
                                     normalizeY: normalizeY)
    }

    private func makeLineLayout(for text: String,
                                labelIndex: simd_int1,
                                scale: Float,
                                baselineY: Float,
                                weight: LabelFontWeight) -> LabelLineLayout? {
        var vertices: [LabelVertex] = []
        var currentX: Float = 0.0
        let atlasData = atlasData(for: weight)
        let glyphLookup = glyphLookup(for: weight)
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        vertices.reserveCapacity(text.unicodeScalars.count * 6)

        for char in text.unicodeScalars {
            if char == "\n" {
                continue
            }
            guard let glyph = glyphLookup[char.value] else {
                currentX += Float(atlasData.metrics.emSize) * scale * 0.25
                continue
            }

            guard let atlasBounds = glyph.atlasBounds else {
                currentX += Float(glyph.advance) * scale
                continue
            }

            let planeLeft = Float(glyph.planeBounds?.left ?? 0)
            let planeBottom = Float(glyph.planeBounds?.bottom ?? 0)
            let planeRight = Float(glyph.planeBounds?.right ?? CGFloat(planeLeft))
            let planeTop = Float(glyph.planeBounds?.top ?? CGFloat(planeBottom))

            let glyphWidth = planeRight - planeLeft
            let glyphHeight = planeTop - planeBottom

            let left = currentX + planeLeft * scale
            let bottom = baselineY + planeBottom * scale
            let right = left + glyphWidth * scale
            let top = bottom + glyphHeight * scale

            let atlasLeft = Float(atlasBounds.left) / Float(atlasData.atlas.width)
            let atlasBottom = 1.0 - Float(atlasBounds.bottom) / Float(atlasData.atlas.height)
            let atlasRight = Float(atlasBounds.right) / Float(atlasData.atlas.width)
            let atlasTop = 1.0 - Float(atlasBounds.top) / Float(atlasData.atlas.height)

            let quadVertices = [
                LabelVertex(position: SIMD2<Float>(left, bottom), uv: SIMD2<Float>(atlasLeft, atlasBottom), labelIndex: labelIndex),
                LabelVertex(position: SIMD2<Float>(right, bottom), uv: SIMD2<Float>(atlasRight, atlasBottom), labelIndex: labelIndex),
                LabelVertex(position: SIMD2<Float>(left, top), uv: SIMD2<Float>(atlasLeft, atlasTop), labelIndex: labelIndex),
                LabelVertex(position: SIMD2<Float>(right, bottom), uv: SIMD2<Float>(atlasRight, atlasBottom), labelIndex: labelIndex),
                LabelVertex(position: SIMD2<Float>(right, top), uv: SIMD2<Float>(atlasRight, atlasTop), labelIndex: labelIndex),
                LabelVertex(position: SIMD2<Float>(left, top), uv: SIMD2<Float>(atlasLeft, atlasTop), labelIndex: labelIndex)
            ]

            vertices.append(contentsOf: quadVertices)
            currentX += Float(glyph.advance) * scale
            minX = min(minX, left)
            minY = min(minY, bottom)
            maxX = max(maxX, right)
            maxY = max(maxY, top)
        }

        guard vertices.isEmpty == false,
              minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else {
            return nil
        }

        return LabelLineLayout(vertices: vertices,
                               minX: minX,
                               minY: minY,
                               maxX: maxX,
                               maxY: maxY)
    }

    private func normalizedTextMetrics(vertices: [LabelVertex],
                                       minX: Float,
                                       minY: Float,
                                       maxX: Float,
                                       maxY: Float,
                                       normalizeY: Bool) -> TextMetrics {
        guard vertices.isEmpty == false,
              minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else {
            return TextMetrics(size: TextSize(width: 0.0, height: 0.0), vertices: [])
        }

        let width = max(0.0, maxX - minX)
        let height = max(0.0, maxY - minY)
        let shiftX = minX
        let shiftY = normalizeY ? minY : 0.0
        var shiftedVertices = vertices
        if shiftX != 0.0 || shiftY != 0.0 {
            for index in shiftedVertices.indices {
                shiftedVertices[index].position.x -= shiftX
                shiftedVertices[index].position.y -= shiftY
            }
        }

        return TextMetrics(size: TextSize(width: width, height: height), vertices: shiftedVertices)
    }

    private func wrappedLines(for text: String,
                              scale: Float,
                              weight: LabelFontWeight,
                              wrap: LabelWrapOptions) -> [String] {
        let maxLines = max(1, wrap.maxLines)
        let segments = makeWrapSegments(from: text)
        guard segments.isEmpty == false else {
            return text.isEmpty ? [] : [text]
        }

        var lines: [String] = []
        lines.reserveCapacity(maxLines)
        var currentLine = ""
        var needsCollapsedBreakSeparator = false

        for segment in segments {
            switch segment {
            case .forcedBreak:
                if lines.count >= maxLines - 1 {
                    needsCollapsedBreakSeparator = currentLine.isEmpty == false
                    continue
                }
                let normalized = trimTrailingWhitespace(in: currentLine)
                if normalized.isEmpty == false {
                    lines.append(normalized)
                }
                currentLine = ""
                needsCollapsedBreakSeparator = false

            case .text(let rawSegment):
                var segmentText = currentLine.isEmpty ? trimLeadingWhitespace(in: rawSegment) : rawSegment
                if segmentText.isEmpty {
                    continue
                }

                if lines.count >= maxLines - 1 {
                    if needsCollapsedBreakSeparator,
                       currentLine.isEmpty == false,
                       currentLine.hasSuffix("-") == false,
                       startsWithWhitespace(segmentText) == false {
                        currentLine.append(" ")
                    }
                    if currentLine.isEmpty {
                        segmentText = trimLeadingWhitespace(in: segmentText)
                    }
                    currentLine.append(segmentText)
                    needsCollapsedBreakSeparator = false
                    continue
                }

                if currentLine.isEmpty {
                    currentLine = segmentText
                    continue
                }

                let candidate = currentLine + segmentText
                if measureTextWidth(for: candidate, scale: scale, weight: weight) <= wrap.maxWidthPx {
                    currentLine = candidate
                } else {
                    let normalized = trimTrailingWhitespace(in: currentLine)
                    if normalized.isEmpty == false {
                        lines.append(normalized)
                    }
                    currentLine = trimLeadingWhitespace(in: segmentText)
                }
            }
        }

        let normalized = trimTrailingWhitespace(in: currentLine)
        if normalized.isEmpty == false {
            lines.append(normalized)
        }

        if lines.isEmpty, text.isEmpty == false {
            return [trimTrailingWhitespace(in: trimLeadingWhitespace(in: text))]
        }

        return Array(lines.prefix(maxLines))
    }

    private func measureTextWidth(for text: String,
                                  scale: Float,
                                  weight: LabelFontWeight) -> Float {
        guard let bounds = measureTextBounds(for: text,
                                             scale: scale,
                                             weight: weight) else {
            return 0.0
        }
        return max(0.0, bounds.maxX - bounds.minX)
    }

    private func measureTextBounds(for text: String,
                                   scale: Float,
                                   weight: LabelFontWeight) -> (minX: Float, maxX: Float)? {
        var currentX: Float = 0.0
        let atlasData = atlasData(for: weight)
        let glyphLookup = glyphLookup(for: weight)
        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude

        for char in text.unicodeScalars {
            if char == "\n" {
                continue
            }
            guard let glyph = glyphLookup[char.value] else {
                currentX += Float(atlasData.metrics.emSize) * scale * 0.25
                continue
            }

            guard glyph.atlasBounds != nil else {
                currentX += Float(glyph.advance) * scale
                continue
            }

            let planeLeft = Float(glyph.planeBounds?.left ?? 0)
            let planeRight = Float(glyph.planeBounds?.right ?? CGFloat(planeLeft))
            let left = currentX + planeLeft * scale
            let right = currentX + planeRight * scale

            minX = min(minX, left)
            maxX = max(maxX, right)
            currentX += Float(glyph.advance) * scale
        }

        guard minX.isFinite, maxX.isFinite else {
            return nil
        }

        return (minX, maxX)
    }

    private func makeWrapSegments(from text: String) -> [LabelWrapSegment] {
        var segments: [LabelWrapSegment] = []
        segments.reserveCapacity(text.count)
        var current = ""

        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if current.isEmpty == false {
                    segments.append(.text(current))
                    current.removeAll(keepingCapacity: true)
                }
                segments.append(.forcedBreak)
                continue
            }

            current.unicodeScalars.append(scalar)
            if CharacterSet.whitespaces.contains(scalar) || scalar == "-" {
                segments.append(.text(current))
                current.removeAll(keepingCapacity: true)
            }
        }

        if current.isEmpty == false {
            segments.append(.text(current))
        }

        return segments
    }

    private func trimLeadingWhitespace(in text: String) -> String {
        let scalars = text.unicodeScalars.drop(while: { CharacterSet.whitespacesAndNewlines.contains($0) })
        return String(String.UnicodeScalarView(scalars))
    }

    private func trimTrailingWhitespace(in text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var end = scalars.count
        while end > 0 && CharacterSet.whitespacesAndNewlines.contains(scalars[end - 1]) {
            end -= 1
        }
        return String(String.UnicodeScalarView(scalars[..<end]))
    }

    private func startsWithWhitespace(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func collectTextVertices(into vertices: inout [TextVertex],
                                     for text: String,
                                     at position: SIMD2<Float>,
                                     scale: Float) {
        var currentX: Float = position.x
        let y = position.y  // Baseline at position.y
        let glyphLookup = boldGlyphLookup
        vertices.reserveCapacity(vertices.count + (text.unicodeScalars.count * 6))

        for char in text.unicodeScalars {
            guard let glyph = glyphLookup[char.value] else {
                currentX += Float(atlasData.metrics.emSize) * scale * 0.25
                continue
            }

            guard let atlasBounds = glyph.atlasBounds else {
                currentX += Float(glyph.advance) * scale
                continue
            }

            let planeLeft = Float(glyph.planeBounds?.left ?? 0)
            let planeBottom = Float(glyph.planeBounds?.bottom ?? 0)
            let planeRight = Float(glyph.planeBounds?.right ?? CGFloat(planeLeft))
            let planeTop = Float(glyph.planeBounds?.top ?? CGFloat(planeBottom))

            let glyphWidth = planeRight - planeLeft
            let glyphHeight = planeTop - planeBottom

            let left = currentX + planeLeft * scale
            let bottom = y + planeBottom * scale
            let right = left + glyphWidth * scale
            let top = bottom + glyphHeight * scale

            let atlasLeft = Float(atlasBounds.left) / Float(atlasData.atlas.width)
            let atlasBottom = 1.0 - Float(atlasBounds.bottom) / Float(atlasData.atlas.height)
            let atlasRight = Float(atlasBounds.right) / Float(atlasData.atlas.width)
            let atlasTop = 1.0 - Float(atlasBounds.top) / Float(atlasData.atlas.height)

            vertices.append(TextVertex(position: SIMD4<Float>(left, bottom, 0, 1),
                                       uv: SIMD2<Float>(atlasLeft, atlasBottom)))
            vertices.append(TextVertex(position: SIMD4<Float>(right, bottom, 0, 1),
                                       uv: SIMD2<Float>(atlasRight, atlasBottom)))
            vertices.append(TextVertex(position: SIMD4<Float>(left, top, 0, 1),
                                       uv: SIMD2<Float>(atlasLeft, atlasTop)))
            vertices.append(TextVertex(position: SIMD4<Float>(right, bottom, 0, 1),
                                       uv: SIMD2<Float>(atlasRight, atlasBottom)))
            vertices.append(TextVertex(position: SIMD4<Float>(right, top, 0, 1),
                                       uv: SIMD2<Float>(atlasRight, atlasTop)))
            vertices.append(TextVertex(position: SIMD4<Float>(left, top, 0, 1),
                                       uv: SIMD2<Float>(atlasLeft, atlasTop)))
            currentX += Float(glyph.advance) * scale
        }
    }

    static func estimatedVertexCapacity(for entries: [TextEntry]) -> Int {
        entries.reduce(into: 0) { partialResult, entry in
            partialResult += entry.text.unicodeScalars.count * 6
        }
    }

    static func makeGlyphLookupTable(from glyphs: [Glyph]) -> [UInt32: Glyph] {
        var lookup: [UInt32: Glyph] = [:]
        lookup.reserveCapacity(glyphs.count)
        for glyph in glyphs {
            lookup[glyph.unicode] = glyph
        }
        return lookup
    }
    
    private func createPipelines() {
        guard let textVertexFn = library.makeFunction(name: "textVertex"),
              let labelVertexFn = library.makeFunction(name: "labelTextVertex"),
              let roadLabelVertexFn = library.makeFunction(name: "roadLabelTextVertex"),
              let poiIconVertexFn = library.makeFunction(name: "poiSpriteVertex"),
              let poiIconFragmentFn = library.makeFunction(name: "poiSpriteFragment"),
              let fragmentFn = library.makeFunction(name: "textFragment"),
              let roadFragmentFn = library.makeFunction(name: "roadTextFragment") else { fatalError("Functions not found") }
        
        let textVertexDescriptor = MTLVertexDescriptor()
        textVertexDescriptor.attributes[0].format = .float4
        textVertexDescriptor.attributes[0].offset = 0
        textVertexDescriptor.attributes[0].bufferIndex = 0
        textVertexDescriptor.attributes[1].format = .float2
        textVertexDescriptor.attributes[1].offset = MemoryLayout<SIMD4<Float>>.stride
        textVertexDescriptor.attributes[1].bufferIndex = 0
        textVertexDescriptor.layouts[0].stride = MemoryLayout<TextVertex>.stride
        
        let labelVertexDescriptor = MTLVertexDescriptor()
        labelVertexDescriptor.attributes[0].format = .float2
        labelVertexDescriptor.attributes[0].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.position) ?? 0
        labelVertexDescriptor.attributes[0].bufferIndex = 0
        labelVertexDescriptor.attributes[1].format = .float2
        labelVertexDescriptor.attributes[1].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.uv) ?? 0
        labelVertexDescriptor.attributes[1].bufferIndex = 0
        labelVertexDescriptor.attributes[2].format = .int
        labelVertexDescriptor.attributes[2].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.labelIndex) ?? 0
        labelVertexDescriptor.attributes[2].bufferIndex = 0
        labelVertexDescriptor.attributes[3].format = .float2
        labelVertexDescriptor.attributes[3].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.spriteUV) ?? 0
        labelVertexDescriptor.attributes[3].bufferIndex = 0
        labelVertexDescriptor.layouts[0].stride = MemoryLayout<LabelVertex>.stride
        
        do {
            pipelineState = try makePipelineState(vertexFunction: textVertexFn,
                                                  vertexDescriptor: textVertexDescriptor,
                                                  fragmentFunction: fragmentFn)
            labelPipelineState = try makePipelineState(vertexFunction: labelVertexFn,
                                                       vertexDescriptor: labelVertexDescriptor,
                                                       fragmentFunction: fragmentFn)
            roadLabelPipelineState = try makePipelineState(vertexFunction: roadLabelVertexFn,
                                                           vertexDescriptor: labelVertexDescriptor,
                                                           fragmentFunction: roadFragmentFn)
            poiIconPipelineState = try makePipelineState(vertexFunction: poiIconVertexFn,
                                                         vertexDescriptor: labelVertexDescriptor,
                                                         fragmentFunction: poiIconFragmentFn)
        } catch {
            fatalError("Pipeline creation failed: \(error)")
        }
    }
    
    private func makePipelineState(vertexFunction: MTLFunction,
                                   vertexDescriptor: MTLVertexDescriptor,
                                   fragmentFunction: MTLFunction) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
