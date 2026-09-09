// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

final class TileTextLabelsBuilder {
    struct BuiltBaseLabel {
        let placementInput: TextLabelPlacementInput
        let style: LabelTextStyle
        let textVertices: [LabelVertex]
        let iconVertices: [LabelVertex]
    }

    private let textRenderer: TextRenderer
    private let poiAtlasLayout: PoiSpriteAtlasLayout

    init(textRenderer: TextRenderer) {
        self.textRenderer = textRenderer
        self.poiAtlasLayout = PoiSpriteAtlasLayout()
    }

    /// A label wraps at the base width to at most this many lines.
    private static let baseLabelWrapLineCount = 3
    /// A label whose text does not fit the base lines re-wraps wider and
    /// taller instead of dumping its tail onto one long last line: the box
    /// grows by `extendedLabelWrapWidthFactor` and may run to this many
    /// lines. A long name then reads as a compact paragraph, not as a
    /// three-line stack with a sentence trailing off the third.
    private static let extendedLabelWrapLineCount = 6
    private static let extendedLabelWrapWidthFactor: Float = 1.5
    /// Label box width in ems at the base wrap.
    private static let baseLabelWrapWidthEms: Float = 10.0

    /// Wraps a label at the base box; when the text does not fit the base
    /// lines (the wrapper then runs the remainder onto its last line, so the
    /// laid-out width exceeds the box) the label is wrapped again at the
    /// extended box. Two passes cost a second layout only for the long names,
    /// which are rare.
    static func wrappedLabelMetrics(for text: String,
                                    labelIndex: simd_int1,
                                    textScale: Float,
                                    weight: LabelFontWeight,
                                    textRenderer: TextRenderer) -> TextMetrics {
        let baseWidth = textScale * baseLabelWrapWidthEms
        let baseWrap = LabelWrapOptions(maxWidth: baseWidth,
                                        maxLines: baseLabelWrapLineCount,
                                        alignment: .left)
        let baseMetrics = textRenderer.collectLabelVertices(for: text,
                                                            labelIndex: labelIndex,
                                                            scale: textScale,
                                                            wrap: baseWrap,
                                                            weight: weight)
        // A small tolerance: a line that measures a hair over the box is the
        // wrapper's own rounding, not an overflow worth a second pass.
        guard baseMetrics.size.width > baseWidth * 1.02 else {
            return baseMetrics
        }
        let extendedWrap = LabelWrapOptions(maxWidth: baseWidth * extendedLabelWrapWidthFactor,
                                            maxLines: extendedLabelWrapLineCount,
                                            alignment: .left)
        return textRenderer.collectLabelVertices(for: text,
                                                 labelIndex: labelIndex,
                                                 scale: textScale,
                                                 wrap: extendedWrap,
                                                 weight: weight)
    }
    /// How large a POI label draws next to the plain text labels around it.
    ///
    /// A POI is a pin plus its name, and the pair is laid out as one block, so
    /// one factor scales the type, the icon disc and the gap between them
    /// together. It used to be 1.4, which made the disc alone forty points
    /// across: the POIs read as buttons dropped onto the map rather than as
    /// marks on it, and a long museum name became a paragraph over the
    /// buildings. At 1.05 the disc is thirty points and the name is a shade
    /// under twelve, a little smaller than a city's.
    private static let poiCombinedLabelScale: Float = 1.05

    func build(textLabels: [TileMvtParser.TextLabel], tile: Tile) -> PreparedTileCPU.TextLabelSet {
        let tileIndices = SIMD3<Int32>(Int32(tile.x), Int32(tile.y), Int32(tile.z))
        var builtLabels: [BuiltBaseLabel] = []
        builtLabels.reserveCapacity(textLabels.count)

        let sortedLabels = textLabels.enumerated().sorted { lhs, rhs in
            if lhs.element.collisionPriority != rhs.element.collisionPriority {
                return lhs.element.collisionPriority < rhs.element.collisionPriority
            }
            if lhs.element.sortKey != rhs.element.sortKey {
                return lhs.element.sortKey < rhs.element.sortKey
            }
            return lhs.offset < rhs.offset
        }

        for (sortedIndex, item) in sortedLabels.enumerated() {
            let label = item.element
            let pos = label.position
            let uvX = Double(pos.x) / 4096.0
            let uvY = Double(pos.y) / 4096.0
            let uv = SIMD2<Float>(Float(uvX), Float(uvY))

            let style = label.textStyle
            let weight = style.weight
            let labelIndex = simd_int1(sortedIndex)
            let contentScale = label.poiIcon == nil ? 1.0 : Self.poiCombinedLabelScale
            // Geometry is baked in layout points, which is what keeps a prepared
            // tile independent of the display it was built on; the shaders scale
            // it by the frame's pixels-per-point.
            let textScale = style.sizePoints * contentScale
            let textMetrics = Self.wrappedLabelMetrics(for: label.text,
                                                       labelIndex: labelIndex,
                                                       textScale: textScale,
                                                       weight: weight,
                                                       textRenderer: textRenderer)
            let geometry = makeCombinedLabelGeometry(textMetrics: textMetrics,
                                                     poiIcon: label.poiIcon,
                                                     textStyle: style,
                                                     labelIndex: labelIndex,
                                                     contentScale: contentScale)

            let placementInput = TextLabelPlacementInput(
                pointInput: TilePointInput(uv: uv,
                                           tile: tileIndices,
                                           tileSlotIndex: 0),
                placementMeta: LabelPlacementMeta(key: label.key,
                                                  sortKey: label.sortKey,
                                                  collisionPriority: label.collisionPriority,
                                                  labelSizePoints: geometry.size,
                                                  minCameraZoom: label.minCameraZoom)
            )
            builtLabels.append(BuiltBaseLabel(placementInput: placementInput,
                                             style: style,
                                             textVertices: geometry.textVertices,
                                             iconVertices: geometry.iconVertices))
        }

        return Self.makeTextLabels(from: builtLabels)
    }

    /// One set of every label the tile carries, in the parser's collision
    /// priority order, with compact label indices: no per-tile budget and no
    /// distance tier, the frame's collision pass alone decides what shows.
    static func makeTextLabels(from builtLabels: [BuiltBaseLabel]) -> PreparedTileCPU.TextLabelSet {
        var verticesByStyle: [LabelRunStyleIdentity: [LabelVertex]] = [:]
        var iconVerticesByStyle: [LabelRunStyleIdentity: [LabelVertex]] = [:]
        var styleByIdentity: [LabelRunStyleIdentity: LabelTextStyle] = [:]
        var placementInputs: [TextLabelPlacementInput] = []
        placementInputs.reserveCapacity(builtLabels.count)

        for (compactIndex, builtLabel) in builtLabels.enumerated() {
            let labelIndex = simd_int1(compactIndex)
            let identity = LabelRunStyleIdentity(builtLabel.style)
            styleByIdentity[identity] = builtLabel.style
            placementInputs.append(builtLabel.placementInput)
            verticesByStyle[identity, default: []].append(contentsOf: remappedVertices(builtLabel.textVertices,
                                                                                        labelIndex: labelIndex))
            if builtLabel.iconVertices.isEmpty == false {
                iconVerticesByStyle[identity, default: []].append(contentsOf: remappedVertices(builtLabel.iconVertices,
                                                                                                labelIndex: labelIndex))
            }
        }

        var glyphRuns: [PreparedTileCPU.TextGlyphRun] = []
        var poiIconRuns: [PreparedTileCPU.PoiIconRun] = []
        let sortedIdentities = styleByIdentity.keys.sorted(by: LabelRunStyleIdentity.orderedBefore)
        for identity in sortedIdentities {
            guard let style = styleByIdentity[identity] else { continue }
            if let vertices = verticesByStyle[identity], vertices.isEmpty == false {
                glyphRuns.append(PreparedTileCPU.TextGlyphRun(style: style,
                                                              localGlyphVertices: vertices))
            }
            if let iconVertices = iconVerticesByStyle[identity], iconVertices.isEmpty == false {
                poiIconRuns.append(PreparedTileCPU.PoiIconRun(style: style,
                                                              localIconVertices: iconVertices))
            }
        }

        return PreparedTileCPU.TextLabelSet(placementInputs: placementInputs,
                                            glyphRuns: glyphRuns,
                                            poiIconRuns: poiIconRuns)
    }

    /// Identity of a homogeneous glyph/icon run: everything the label drawing code
    /// applies at encoding time - the atlas texture (via `weight`) and the uniform fill/stroke colors.
    /// `sizePoints` is deliberately excluded: it is already baked into the vertex geometry and is not
    /// re-applied at draw time, so labels differing only in size stay
    /// in the same run.
    ///
    /// Grouping by this identity (rather than by `style.key` alone) keeps each run
    /// self-consistent even when the provider reuses one `key` for several
    /// stylings - e.g. OpenMapTiles/OSM put bold cities and thin villages under
    /// `key = 70`. Mixing weights in a run with a single bound texture made glyphs
    /// built against a different atlas sample from the wrong region = garbage instead of letters.
    private struct LabelRunStyleIdentity: Hashable {
        let key: Int
        let weight: LabelFontWeight
        let fillColor: SIMD3<Float>
        let strokeColor: SIMD3<Float>
        /// Halo width in device pixels is resolved at draw time from `haloEm`
        /// and the em size, so two labels that share an em ratio but not a size
        /// no longer share a run.
        let haloWidthPoints: Float

        init(_ style: LabelTextStyle) {
            self.key = style.key
            self.weight = style.weight
            self.fillColor = style.fillColor
            self.strokeColor = style.strokeColor
            self.haloWidthPoints = style.haloEm * style.sizePoints
        }

        /// Deterministic draw order: first by `key` (matches the previous
        /// `styleByKey.keys.sorted()` when keys are unique), then by the remaining fields
        /// so that equal keys break into a stable sequence.
        static func orderedBefore(_ lhs: LabelRunStyleIdentity, _ rhs: LabelRunStyleIdentity) -> Bool {
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            if lhs.weight.rawValue != rhs.weight.rawValue { return lhs.weight.rawValue < rhs.weight.rawValue }
            if lhs.haloWidthPoints != rhs.haloWidthPoints { return lhs.haloWidthPoints < rhs.haloWidthPoints }
            for index in 0..<3 where lhs.fillColor[index] != rhs.fillColor[index] {
                return lhs.fillColor[index] < rhs.fillColor[index]
            }
            for index in 0..<3 where lhs.strokeColor[index] != rhs.strokeColor[index] {
                return lhs.strokeColor[index] < rhs.strokeColor[index]
            }
            return false
        }
    }

    private static func remappedVertices(_ vertices: [LabelVertex], labelIndex: simd_int1) -> [LabelVertex] {
        vertices.map { vertex in
            var updated = vertex
            updated.labelIndex = labelIndex
            return updated
        }
    }

    private struct CombinedLabelGeometry {
        let textVertices: [LabelVertex]
        let size: SIMD2<Float>
        let iconVertices: [LabelVertex]
    }

    private func makeCombinedLabelGeometry(textMetrics: TextMetrics,
                                           poiIcon: PoiSpriteIcon?,
                                           textStyle: LabelTextStyle,
                                           labelIndex: simd_int1,
                                           contentScale: Float) -> CombinedLabelGeometry {
        guard let poiIcon,
              let region = poiAtlasLayout.region(for: poiIcon) else {
            let size = SIMD2<Float>(textMetrics.size.width, textMetrics.size.height)
            return CombinedLabelGeometry(textVertices: textMetrics.vertices,
                                         size: size,
                                         iconVertices: [])
        }

        let iconSize = poiIconSize(for: textStyle, contentScale: contentScale)
        let iconGap = poiIconGap(for: textStyle, contentScale: contentScale)
        let combinedWidth = iconSize + iconGap + textMetrics.size.width
        let combinedHeight = max(iconSize, textMetrics.size.height)
        let textYOffset = max(0.0, (combinedHeight - textMetrics.size.height) * 0.5)
        let iconYOffset = max(0.0, (combinedHeight - iconSize) * 0.5)

        var shiftedTextVertices = textMetrics.vertices
        if iconSize > 0 {
            for index in shiftedTextVertices.indices {
                shiftedTextVertices[index].position.x += iconSize + iconGap
                shiftedTextVertices[index].position.y += textYOffset
            }
        }

        let uvRect = region.uvRect
        return CombinedLabelGeometry(textVertices: shiftedTextVertices,
                                     size: SIMD2<Float>(combinedWidth, combinedHeight),
                                     iconVertices: Self.makeIconQuad(iconSize: iconSize,
                                                                     iconYOffset: iconYOffset,
                                                                     labelIndex: labelIndex,
                                                                     uvRect: uvRect))
    }

    private static func makeIconQuad(iconSize: Float,
                                     iconYOffset: Float,
                                     labelIndex: simd_int1,
                                     uvRect: SIMD4<Float>) -> [LabelVertex] {
        [
            LabelVertex(position: SIMD2<Float>(0.0, iconYOffset),
                        uv: SIMD2<Float>(uvRect.z, uvRect.w),
                        labelIndex: labelIndex,
                        spriteUV: SIMD2<Float>(0.0, 0.0)),
            LabelVertex(position: SIMD2<Float>(iconSize, iconYOffset),
                        uv: SIMD2<Float>(uvRect.x, uvRect.w),
                        labelIndex: labelIndex,
                        spriteUV: SIMD2<Float>(1.0, 0.0)),
            LabelVertex(position: SIMD2<Float>(0.0, iconYOffset + iconSize),
                        uv: SIMD2<Float>(uvRect.z, uvRect.y),
                        labelIndex: labelIndex,
                        spriteUV: SIMD2<Float>(0.0, 1.0)),
            LabelVertex(position: SIMD2<Float>(iconSize, iconYOffset),
                        uv: SIMD2<Float>(uvRect.x, uvRect.w),
                        labelIndex: labelIndex,
                        spriteUV: SIMD2<Float>(1.0, 0.0)),
            LabelVertex(position: SIMD2<Float>(iconSize, iconYOffset + iconSize),
                        uv: SIMD2<Float>(uvRect.x, uvRect.y),
                        labelIndex: labelIndex,
                        spriteUV: SIMD2<Float>(1.0, 1.0)),
            LabelVertex(position: SIMD2<Float>(0.0, iconYOffset + iconSize),
                        uv: SIMD2<Float>(uvRect.z, uvRect.y),
                        labelIndex: labelIndex,
                        spriteUV: SIMD2<Float>(0.0, 1.0))
        ]
    }

    /// Icon side in layout points: proportional to the text it sits next to,
    /// over a narrow band of sizes so a POI pin stays a recognizable target
    /// rather than growing with every step of the type scale.
    private func poiIconSize(for textStyle: LabelTextStyle, contentScale: Float) -> Float {
        min(max(textStyle.sizePoints, 9.0), 12.0) * 2.6 * contentScale
    }

    private func poiIconGap(for textStyle: LabelTextStyle, contentScale: Float) -> Float {
        max(3.0, textStyle.sizePoints * 0.2) * contentScale
    }
}
