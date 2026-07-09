// Copyright (c) 2025-2026 Artem Bobkin.
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

    private static let baseLabelWrapLineCount = 3
    private static let poiCombinedLabelScale: Float = 1.4

    func build(textLabels: [TileMvtParser.TextLabel], tile: Tile) -> PreparedTileCPU.TextLabels {
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
            let textScale = style.sizePx * contentScale
            let wrap = LabelWrapOptions(maxWidthPx: textScale * 10.0,
                                        maxLines: Self.baseLabelWrapLineCount,
                                        alignment: .left)
            let textMetrics = textRenderer.collectLabelVertices(for: label.text,
                                                                labelIndex: labelIndex,
                                                                scale: textScale,
                                                                wrap: wrap,
                                                                weight: weight)
            let (vertices, size, iconVertices) = makeCombinedLabelGeometry(textMetrics: textMetrics,
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
                                                  labelSizePx: size)
            )
            builtLabels.append(BuiltBaseLabel(placementInput: placementInput,
                                             style: style,
                                             textVertices: vertices,
                                             iconVertices: iconVertices))
        }

        return Self.makeTextLabels(from: builtLabels)
    }

    static func makeTextLabels(from builtLabels: [BuiltBaseLabel]) -> PreparedTileCPU.TextLabels {
        return PreparedTileCPU.TextLabels(
            full: makeTextLabelSet(from: builtLabels, tier: .full),
            reduced: makeTextLabelSet(from: builtLabels, tier: .reduced),
            minimal: makeTextLabelSet(from: builtLabels, tier: .minimal)
        )
    }

    private static func makeTextLabelSet(from builtLabels: [BuiltBaseLabel],
                                         tier: BaseLabelDetailTier) -> PreparedTileCPU.TextLabelSet {
        let retainedCount = BaseLabelDetailTier.retainedLabelCount(labelCount: builtLabels.count, tier: tier)
        let retainedLabels = builtLabels.prefix(retainedCount)

        var verticesByStyle: [LabelRunStyleIdentity: [LabelVertex]] = [:]
        var iconVerticesByStyle: [LabelRunStyleIdentity: [LabelVertex]] = [:]
        var styleByIdentity: [LabelRunStyleIdentity: LabelTextStyle] = [:]
        var placementInputs: [TextLabelPlacementInput] = []
        placementInputs.reserveCapacity(retainedCount)

        for (compactIndex, builtLabel) in retainedLabels.enumerated() {
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

    /// Идентичность гомогенного glyph/icon-run: всё, что применяет код отрисовки лейблов
    /// на этапе энкодинга - атлас-текстура (через `weight`) и uniform-цвета fill/stroke.
    /// `sizePx` намеренно исключён: он уже запечён в геометрию вершин и на отрисовке
    /// повторно не применяется, поэтому лейблы, отличающиеся только размером, остаются
    /// в одном run.
    ///
    /// Группировка по этой идентичности (а не только по `style.key`) держит каждый run
    /// самосогласованным, даже когда провайдер переиспользует один `key` для нескольких
    /// оформлений - например, OpenMapTiles/OSM кладут bold-города и thin-посёлки под
    /// `key = 70`. Смешивание весов в run с одной привязанной текстурой заставляло глифы,
    /// построенные по другому атласу, сэмплиться из неверной области = мусор вместо букв.
    private struct LabelRunStyleIdentity: Hashable {
        let key: Int
        let weight: LabelFontWeight
        let fillColor: SIMD3<Float>
        let strokeColor: SIMD3<Float>
        let strokeWidthPx: Float

        init(_ style: LabelTextStyle) {
            self.key = style.key
            self.weight = style.weight
            self.fillColor = style.fillColor
            self.strokeColor = style.strokeColor
            self.strokeWidthPx = style.strokeWidthPx
        }

        /// Детерминированный порядок отрисовки: сначала по `key` (совпадает с прежним
        /// `styleByKey.keys.sorted()`, когда ключи уникальны), затем по остальным полям,
        /// чтобы совпавшие ключи разбивались в стабильную последовательность.
        static func orderedBefore(_ lhs: LabelRunStyleIdentity, _ rhs: LabelRunStyleIdentity) -> Bool {
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            if lhs.weight.rawValue != rhs.weight.rawValue { return lhs.weight.rawValue < rhs.weight.rawValue }
            if lhs.strokeWidthPx != rhs.strokeWidthPx { return lhs.strokeWidthPx < rhs.strokeWidthPx }
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

    private func makeCombinedLabelGeometry(textMetrics: TextMetrics,
                                           poiIcon: PoiSpriteIcon?,
                                           textStyle: LabelTextStyle,
                                           labelIndex: simd_int1,
                                           contentScale: Float) -> ([LabelVertex], SIMD2<Float>, [LabelVertex]) {
        guard let poiIcon,
              let region = poiAtlasLayout.region(for: poiIcon) else {
            let size = SIMD2<Float>(textMetrics.size.width, textMetrics.size.height)
            return (textMetrics.vertices, size, [])
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
        let iconVertices = [
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

        return (shiftedTextVertices,
                SIMD2<Float>(combinedWidth, combinedHeight),
                iconVertices)
    }

    private func poiIconSize(for textStyle: LabelTextStyle, contentScale: Float) -> Float {
        min(max(textStyle.sizePx, 18.0), 24.0) * 2.6 * contentScale
    }

    private func poiIconGap(for textStyle: LabelTextStyle, contentScale: Float) -> Float {
        max(6.0, floor(textStyle.sizePx * 0.2)) * contentScale
    }
}
