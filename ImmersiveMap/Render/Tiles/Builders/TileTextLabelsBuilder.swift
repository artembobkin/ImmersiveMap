// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

final class TileTextLabelsBuilder {
    struct BuiltBaseLabel {
        let placementInput: TextLabelPlacementInput
        let style: LabelTextStyle
        let textVertices: [LabelVertex]
        let iconVertices: [LabelVertex]
        /// Категория для тировой политики (см. `tierRepresentation`).
        let detailCategory: VectorTileLabelDetailCategory
        /// Икон-only представление для деградации в среднем тире: иконка в
        /// начале координат и её квадратный бокс. Пусто у лейблов без иконки.
        let iconOnlyVertices: [LabelVertex]
        let iconOnlySizePx: SIMD2<Float>

        init(placementInput: TextLabelPlacementInput,
             style: LabelTextStyle,
             textVertices: [LabelVertex],
             iconVertices: [LabelVertex],
             detailCategory: VectorTileLabelDetailCategory = .anchor,
             iconOnlyVertices: [LabelVertex] = [],
             iconOnlySizePx: SIMD2<Float> = .zero) {
            self.placementInput = placementInput
            self.style = style
            self.textVertices = textVertices
            self.iconVertices = iconVertices
            self.detailCategory = detailCategory
            self.iconOnlyVertices = iconOnlyVertices
            self.iconOnlySizePx = iconOnlySizePx
        }
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
                                                  labelSizePx: geometry.size,
                                                  minCameraZoom: label.minCameraZoom)
            )
            builtLabels.append(BuiltBaseLabel(placementInput: placementInput,
                                             style: style,
                                             textVertices: geometry.textVertices,
                                             iconVertices: geometry.iconVertices,
                                             detailCategory: label.detailCategory,
                                             iconOnlyVertices: geometry.iconOnlyVertices,
                                             iconOnlySizePx: geometry.iconOnlySize))
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

    /// Представление лейбла в тире детализации.
    private enum TierRepresentation {
        case full
        case iconOnly
        case dropped
    }

    /// POI с классовым зумом появления не глубже этого порога считается
    /// «якорным» (больница, вокзал, парк): в среднем тире он сохраняет текст.
    private static let majorPoiMaximumMinCameraZoom: Float = 14.5

    /// Тировая политика детализации:
    /// full - всё как есть; reduced - якорные подписи и крупные POI целиком,
    /// остальные иконочные POI деградируют до иконки без текста (маленький
    /// коллизионный бокс), безыконная мелочь и номера домов выпадают;
    /// minimal - только горстка самых важных якорных подписей, даль без POI.
    private static func tierRepresentation(for builtLabel: BuiltBaseLabel,
                                           tier: BaseLabelDetailTier) -> TierRepresentation {
        switch tier {
        case .full:
            return .full
        case .reduced:
            switch builtLabel.detailCategory {
            case .anchor:
                return .full
            case .housenumber:
                return .dropped
            case .poi:
                if builtLabel.placementInput.placementMeta.minCameraZoom <= majorPoiMaximumMinCameraZoom {
                    return .full
                }
                return builtLabel.iconOnlyVertices.isEmpty ? .dropped : .iconOnly
            }
        case .minimal:
            return builtLabel.detailCategory == .anchor ? .full : .dropped
        }
    }

    private static func makeTextLabelSet(from builtLabels: [BuiltBaseLabel],
                                         tier: BaseLabelDetailTier) -> PreparedTileCPU.TextLabelSet {
        // Абсолютные бюджеты тайла: плотный тайл отдаёт не больше бюджета,
        // разреженный - всё своё. Лейблы уже отсортированы по приоритету
        // коллизий, поэтому бюджет забирают самые важные (внутри POI порядок
        // совпадает с локальным рангом - расход равномерен по тайлу).
        var anchorBudget = BaseLabelDetailTier.anchorLabelBudget(tier: tier)
        var poiBudget = BaseLabelDetailTier.poiLabelBudget(tier: tier)
        var retainedLabels: [(label: BuiltBaseLabel, representation: TierRepresentation)] = []
        retainedLabels.reserveCapacity(builtLabels.count)
        for builtLabel in builtLabels {
            let representation = tierRepresentation(for: builtLabel, tier: tier)
            guard representation != .dropped else {
                continue
            }
            switch builtLabel.detailCategory {
            case .anchor:
                guard Self.consumeBudget(&anchorBudget) else { continue }
            case .poi:
                guard Self.consumeBudget(&poiBudget) else { continue }
            case .housenumber:
                break
            }
            retainedLabels.append((builtLabel, representation))
        }

        var verticesByStyle: [LabelRunStyleIdentity: [LabelVertex]] = [:]
        var iconVerticesByStyle: [LabelRunStyleIdentity: [LabelVertex]] = [:]
        var styleByIdentity: [LabelRunStyleIdentity: LabelTextStyle] = [:]
        var placementInputs: [TextLabelPlacementInput] = []
        placementInputs.reserveCapacity(retainedLabels.count)

        for (compactIndex, retained) in retainedLabels.enumerated() {
            let builtLabel = retained.label
            let labelIndex = simd_int1(compactIndex)
            let identity = LabelRunStyleIdentity(builtLabel.style)
            styleByIdentity[identity] = builtLabel.style

            switch retained.representation {
            case .full:
                placementInputs.append(builtLabel.placementInput)
                verticesByStyle[identity, default: []].append(contentsOf: remappedVertices(builtLabel.textVertices,
                                                                                            labelIndex: labelIndex))
                if builtLabel.iconVertices.isEmpty == false {
                    iconVerticesByStyle[identity, default: []].append(contentsOf: remappedVertices(builtLabel.iconVertices,
                                                                                                    labelIndex: labelIndex))
                }
            case .iconOnly:
                placementInputs.append(iconOnlyPlacementInput(for: builtLabel))
                iconVerticesByStyle[identity, default: []].append(contentsOf: remappedVertices(builtLabel.iconOnlyVertices,
                                                                                                labelIndex: labelIndex))
            case .dropped:
                continue
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

    /// Расход абсолютного бюджета: `nil` - без ограничения, 0 - исчерпан.
    private static func consumeBudget(_ budget: inout Int?) -> Bool {
        guard let remaining = budget else {
            return true
        }
        guard remaining > 0 else {
            return false
        }
        budget = remaining - 1
        return true
    }

    /// Плейсмент икон-only представления: тот же анкер и приоритеты, но
    /// коллизионный бокс равен квадрату иконки, а не связке иконка+текст.
    private static func iconOnlyPlacementInput(for builtLabel: BuiltBaseLabel) -> TextLabelPlacementInput {
        let meta = builtLabel.placementInput.placementMeta
        return TextLabelPlacementInput(
            pointInput: builtLabel.placementInput.pointInput,
            placementMeta: LabelPlacementMeta(key: meta.key,
                                              sortKey: meta.sortKey,
                                              collisionPriority: meta.collisionPriority,
                                              labelSizePx: builtLabel.iconOnlySizePx,
                                              minCameraZoom: meta.minCameraZoom)
        )
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

    private struct CombinedLabelGeometry {
        let textVertices: [LabelVertex]
        let size: SIMD2<Float>
        let iconVertices: [LabelVertex]
        let iconOnlyVertices: [LabelVertex]
        let iconOnlySize: SIMD2<Float>
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
                                         iconVertices: [],
                                         iconOnlyVertices: [],
                                         iconOnlySize: .zero)
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
                                                                     uvRect: uvRect),
                                     iconOnlyVertices: Self.makeIconQuad(iconSize: iconSize,
                                                                         iconYOffset: 0.0,
                                                                         labelIndex: labelIndex,
                                                                         uvRect: uvRect),
                                     iconOnlySize: SIMD2<Float>(iconSize, iconSize))
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

    private func poiIconSize(for textStyle: LabelTextStyle, contentScale: Float) -> Float {
        min(max(textStyle.sizePx, 18.0), 24.0) * 2.6 * contentScale
    }

    private func poiIconGap(for textStyle: LabelTextStyle, contentScale: Float) -> Float {
        max(6.0, floor(textStyle.sizePx * 0.2)) * contentScale
    }
}
